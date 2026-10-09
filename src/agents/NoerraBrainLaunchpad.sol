// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {NoerraAgentRegistry} from "./NoerraAgents.sol";
import {NoerraAgentMirrorRegistry, INoerraCrossDomainMessenger} from "./NoerraAgentMirror.sol";
import {NoerraDiem} from "./NoerraDiem.sol";
import {NoerraDiemCreation, NoerraDiemCreationDeployer, NoerraDiemBackingReader} from "./NoerraDiemLaunchpad.sol";
import {NoerraBackers} from "./NoerraLaunchpad.sol";
import {NoerraBridgedToken} from "./NoerraCanonicalToken.sol";

/// @notice Base-only brain market for an authenticated Ethereum creation token.
/// Delivery order is irrelevant: authority, launch metadata, and bridged supply must all arrive before finalize.
/// @dev Initial price is the constructor's explicit quote notional, not contributed nDIEM or running compute.
contract NoerraBrainLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentMirrorRegistry public immutable registry;
    NoerraDiem public immutable wrapper;
    IPoolManager public immutable manager;
    NoerraDiemCreationDeployer public immutable creationDeployer;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    INoerraCrossDomainMessenger public immutable messenger;
    address public immutable sourceLaunchpad;
    address public immutable standardBridge;
    uint256 public immutable initialValuation;
    uint256 public constant sourceChainId = 1;
    mapping(bytes32 => address) public sourceTokens;
    mapping(bytes32 => NoerraBridgedToken) public tokens;
    mapping(bytes32 => NoerraDiemCreation) public launches;
    bytes32[] public agentIds;
    event BrainRegistered(bytes32 indexed agentId, address indexed sourceToken, address token);
    event TokenLaunched(bytes32 indexed agentId, address indexed token, address locker, address backers);

    struct SourcePins {
        address messenger;
        address launchpad;
        address standardBridge;
        uint256 initialValuation;
    }

    constructor(
        NoerraAgentMirrorRegistry registry_,
        NoerraDiem wrapper_,
        IPoolManager manager_,
        NoerraDiemCreationDeployer builder_,
        address protocol_,
        address noer_,
        SourcePins memory pins
    ) {
        require(
            address(wrapper_.registry()) == address(registry_) && address(manager_).code.length > 0, "Provider registry"
        );
        require(
            address(builder_.wrapper()) == address(wrapper_) && address(builder_.manager()) == address(manager_),
            "Provider builder"
        );
        require(
            pins.messenger == address(registry_.messenger()) && pins.launchpad != address(0)
                && pins.standardBridge.code.length > 0,
            "Canonical source pins"
        );
        require(
            protocol_ != address(0) && noer_ != address(0) && pins.initialValuation >= 1e14
                && pins.initialValuation <= 100_000 ether,
            "Explicit brain pricing"
        );
        registry = registry_;
        wrapper = wrapper_;
        manager = manager_;
        creationDeployer = builder_;
        protocolTreasury = protocol_;
        noerTreasury = noer_;
        messenger = INoerraCrossDomainMessenger(pins.messenger);
        sourceLaunchpad = pins.launchpad;
        standardBridge = pins.standardBridge;
        initialValuation = pins.initialValuation;
    }

    function count() external view returns (uint256) {
        return agentIds.length;
    }

    function receiveLaunch(bytes32 id, address source, string calldata name, string calldata symbol) external {
        require(
            msg.sender == address(messenger) && messenger.xDomainMessageSender() == sourceLaunchpad,
            "Canonical source launch only"
        );
        require(id != bytes32(0) && source != address(0) && sourceTokens[id] == address(0), "One source token");
        require(
            bytes(name).length > 0 && bytes(name).length <= 48 && bytes(symbol).length > 0
                && bytes(symbol).length <= 12,
            "Token metadata"
        );
        sourceTokens[id] = source;
        tokens[id] = new NoerraBridgedToken{salt: id}(standardBridge, source, name, symbol);
        emit BrainRegistered(id, source, address(tokens[id]));
    }

    function finalize(bytes32 id) external nonReentrant returns (NoerraDiemCreation locker) {
        require(registry.accounts(id) != address(0), "Authority pending");
        IERC20 token = IERC20(address(tokens[id]));
        require(
            address(token) != address(0) && token.balanceOf(address(this)) >= 500_000_000 ether,
            "Canonical tokens pending"
        );
        require(address(launches[id]) == address(0), "One brain market");
        require(
            address(NoerraDiemBackingReader(address(wrapper.backingReader())).factory()) == address(this),
            "Reader not bound"
        );
        locker = creationDeployer.deploy(id);
        NoerraBackers backers = new NoerraBackers(token, IERC20(address(wrapper)), address(locker));
        launches[id] = locker;
        agentIds.push(id);
        token.safeTransfer(address(locker), 500_000_000 ether);
        (uint160 price, int24 lower, int24 upper) = _terms(address(token));
        locker.initializeSleeping(token, backers, 500_000_000 ether, price, lower, upper);
        emit TokenLaunched(id, address(token), address(locker), address(backers));
    }

    function _terms(address token) private view returns (uint160 price, int24 lower, int24 upper) {
        bool first = token < address(wrapper);
        uint256 supply = 500_000_000 ether;
        uint160 raw =
            uint160(
            Math.sqrt(Math.mulDiv(first ? initialValuation : supply, 1 << 192, first ? supply : initialValuation))
        );
        int24 tick = TickMath.getTickAtSqrtPrice(raw);
        int24 boundary = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) boundary -= 60;
        require(boundary > -887220 && boundary < 887220, "Initial price bounds");
        lower = first ? boundary : int24(-887220);
        upper = first ? int24(887220) : boundary;
        price = TickMath.getSqrtPriceAtTick(boundary);
    }
}
