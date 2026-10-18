// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {NoerraCreationToken} from "./NoerraAgents.sol";
import {NoerraLockedCreation} from "./NoerraLaunchpad.sol";
import {NoerraQuoter} from "./NoerraQuoter.sol";
import {NoerraUsdcFeeHook, AGENT_LAUNCH_FEE_DECAY_BLOCKS} from "./NoerraUsdcFeeHook.sol";

/// @notice Fixed launch output limits with automatic ten-block expiry, and every agent token's decaying anti-snipe
/// launch fee: 25% in its launch block, minus 230 bps per block, the standard 2% from launch block + 10 on. Any
/// wallet, router or contract may buy from the launch block; each buy pays the fee in force and, for the ten
/// protection blocks, is capped at 20M tokens (the token also caps each wallet at 20M).
/// The protected quoter always reverts its simulated swap; it cannot settle claims.
contract NoerraLaunchProtectionHook is NoerraUsdcFeeHook {
    using PoolIdLibrary for PoolKey;
    address public immutable factory;
    address public immutable quoter;
    /// @dev Equals NoerraCreationToken.LAUNCH_PROTECTION_BLOCKS; registration requires that exact window.
    uint256 public constant LAUNCH_PROTECTION_BLOCKS = 10;
    uint256 public constant LAUNCH_FEE_DECAY_BLOCKS = AGENT_LAUNCH_FEE_DECAY_BLOCKS;
    struct Protection { address locker; address token; uint256 endBlock; }
    mapping(PoolId => Protection) public protections;

    constructor(IPoolManager manager_, address factory_, address quoter_) NoerraUsdcFeeHook(manager_, false) {
        require(address(manager_).code.length > 0 && factory_ != address(0)
            && quoter_.code.length > 0 && address(NoerraQuoter(quoter_).poolManager()) == address(manager_), "Hook pins");
        factory = factory_; quoter = quoter_;
    }

    function register(address token, address locker, address dollar) external {
        require(msg.sender == factory, "Source factory only");
        NoerraCreationToken creation = NoerraCreationToken(token);
        NoerraLockedCreation pool = NoerraLockedCreation(locker);
        require(creation.launchFactory() == factory && creation.launchPoolManager() == address(manager)
            && creation.protectionInitialized() && creation.protectionStartBlock() == block.number
            && creation.protectionEndBlock() == block.number + LAUNCH_PROTECTION_BLOCKS && pool.factory() == factory
            && address(pool.manager()) == address(manager) && address(pool.dollar()) == dollar
            && address(pool.launchProtectionHook()) == address(this), "Canonical hook registration");
        bool first = token < dollar;
        PoolKey memory key = PoolKey(Currency.wrap(first ? token : dollar), Currency.wrap(first ? dollar : token),
            pool.FEE(), 60, IHooks(address(this)));
        PoolId id = key.toId();
        require(protections[id].locker == address(0), "Launch protection fixed");
        protections[id] = Protection(locker, token, creation.protectionEndBlock());
        _register(key, locker, dollar);
    }

    /// @notice The block the pool launched in, which starts its fee schedule (0 when not registered). Registration
    /// pins endBlock to exactly launch block + LAUNCH_PROTECTION_BLOCKS, so no separate slot is stored.
    function launchBlock(PoolId id) public view returns (uint256) {
        uint256 end = protections[id].endBlock;
        return end == 0 ? 0 : end - LAUNCH_PROTECTION_BLOCKS;
    }
    function _launchBlock(PoolId id) internal view override returns (uint256) {return launchBlock(id);}
    function _launchFeeDecayBlocks() internal pure override returns (uint256) {return LAUNCH_FEE_DECAY_BLOCKS;}

    function _protect(address, PoolId id, PoolKey calldata key, BalanceDelta delta) internal view override {
        Protection memory protection = protections[id];
        require(protection.locker != address(0), "Canonical launch pool");
        if (block.number < protection.endBlock) {
            int128 output = Currency.unwrap(key.currency0) == protection.token ? delta.amount0() : delta.amount1();
            if (output > 0) require(uint128(output) <= 20_000_000 ether, "Launch max buy");
        }
    }
}
