// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Kept in its own source so its creation bytes (and the registry token builder's pinned
///      hash of them) do not move when the account or registry source changes.
/// @notice An optional creation token. Fixed supply; no tax, upgrade or hidden mint authority.
contract NoerraCreationToken is ERC20 {
    address public immutable launchFactory;
    address public launchPoolManager;
    uint256 public protectionStartBlock;
    uint256 public protectionEndBlock;
    uint256 public constant MAX_LAUNCH_HOLDING = 20_000_000 ether;
    uint256 public constant LAUNCH_PROTECTION_BLOCKS = 10;
    bool public protectionInitialized;
    mapping(address => bool) public launchExempt;

    constructor(string memory name_, string memory symbol_, address account) ERC20(name_, symbol_) {
        require(bytes(name_).length > 0 && bytes(name_).length <= 48, "Name");
        require(bytes(symbol_).length > 0 && bytes(symbol_).length <= 12, "Symbol");
        launchFactory = account;
        _mint(account, 1_000_000_000 ether);
    }

    /// @notice Canonical Ethereum launch protection. Legacy token creation is unchanged.
    /// Only the original factory can initialize once, before distributing supply.
    function initializeLaunchProtection(address poolManager, address locker, address reserve, address bridge)
        external
    {
        require(msg.sender == launchFactory && msg.sender.code.length > 0 && block.chainid == 1, "Launch factory only");
        require(!protectionInitialized && balanceOf(launchFactory) == totalSupply(), "Launch protection fixed");
        require(poolManager.code.length > 0 && locker.code.length > 0 && reserve.code.length > 0
            && bridge.code.length > 0, "Launch protection pins");
        protectionInitialized = true;
        launchPoolManager = poolManager;
        protectionStartBlock = block.number;
        protectionEndBlock = block.number + LAUNCH_PROTECTION_BLOCKS;
        launchExempt[launchFactory] = true;
        launchExempt[poolManager] = true;
        launchExempt[locker] = true;
        launchExempt[reserve] = true;
        launchExempt[bridge] = true;
    }

    function launchProtectionActive() public view returns (bool) {
        return protectionInitialized && block.number < protectionEndBlock;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (launchProtectionActive() && from != address(0) && to != address(0) && !launchExempt[to]) {
            if (from == launchPoolManager) require(value <= MAX_LAUNCH_HOLDING, "Launch max buy");
            require(balanceOf(to) + (from == to ? 0 : value) <= MAX_LAUNCH_HOLDING, "Launch max wallet");
        }
        super._update(from, to, value);
    }
}
