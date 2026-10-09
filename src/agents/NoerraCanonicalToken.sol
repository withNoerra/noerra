// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev OP Stack StandardBridge's published interface, including its ERC165 identifier.
interface INoerraOptimismMintableERC20 is IERC165 {
    function remoteToken() external view returns (address);
    function bridge() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface INoerraStandardBridge {
    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external;
}

/// @notice Base representation of the Ethereum token, minted/burned only by the pinned canonical bridge.
/// @dev No local creator mint, admin, upgrade or second genesis supply exists.
contract NoerraBridgedToken is ERC20, INoerraOptimismMintableERC20 {
    address public immutable remoteToken;
    address public immutable bridge;

    constructor(address bridge_, address source_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        require(bridge_ != address(0) && source_ != address(0), "Bridge identity");
        bridge = bridge_;
        remoteToken = source_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(INoerraOptimismMintableERC20).interfaceId;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == bridge, "Canonical bridge only");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == bridge, "Canonical bridge only");
        _burn(from, amount);
    }
}

/// @notice Optional legacy bridge escrow for tokens voluntarily delivered to its canonical Base destination.
/// New canonical Ethereum launches preallocate no tokens here.
/// @dev Initiated is not delivered. The bridge and Base finality remain external trust dependencies.
contract NoerraTokenBridgeReserve is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    INoerraStandardBridge public immutable bridge;
    address public immutable remoteToken;
    address public immutable destination;
    uint32 public immutable minGasLimit;
    bool public initiated;
    uint256 public constant ALLOCATION = 500_000_000 ether;
    event BridgeInitiated(
        address indexed token, address indexed remoteToken, address indexed destination, uint256 amount
    );

    constructor(IERC20 token_, INoerraStandardBridge bridge_, address remote_, address destination_, uint32 gas_) {
        require(
            address(token_).code.length > 0 && address(bridge_).code.length > 0 && remote_ != address(0)
                && destination_ != address(0),
            "Bridge pins"
        );
        require(gas_ >= 100_000 && gas_ <= 5_000_000, "Message gas bounds");
        token = token_;
        bridge = bridge_;
        remoteToken = remote_;
        destination = destination_;
        minGasLimit = gas_;
    }

    function bridgeTokens() external nonReentrant {
        require(!initiated && token.balanceOf(address(this)) >= ALLOCATION, "Pending allocation");
        initiated = true;
        token.forceApprove(address(bridge), ALLOCATION);
        bridge.bridgeERC20To(address(token), remoteToken, destination, ALLOCATION, minGasLimit, "");
        token.forceApprove(address(bridge), 0);
        emit BridgeInitiated(address(token), remoteToken, destination, ALLOCATION);
    }
}
