// SPDX-License-Identifier: MIT
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
import {NoerraUsdcFeeHook} from "./NoerraUsdcFeeHook.sol";

/// @notice Fixed launch routing and output limits, with automatic ten-block expiry.
/// The protected quoter always reverts its simulated swap; it cannot settle claims.
contract NoerraLaunchProtectionHook is NoerraUsdcFeeHook {
    using PoolIdLibrary for PoolKey;
    address public immutable factory;
    address public immutable quoter;
    struct Protection { address locker; address token; uint256 endBlock; }
    mapping(PoolId => Protection) public protections;

    constructor(IPoolManager manager_, address factory_, address quoter_) NoerraUsdcFeeHook(manager_) {
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
            && creation.protectionEndBlock() == block.number + 10 && pool.factory() == factory
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

    function _protect(address sender, PoolKey calldata key, BalanceDelta delta) internal view override {
        Protection memory protection = protections[key.toId()];
        require(protection.locker != address(0), "Canonical launch pool");
        if (block.number < protection.endBlock) {
            int128 output = Currency.unwrap(key.currency0) == protection.token ? delta.amount0() : delta.amount1();
            if (output > 0) {
                require(sender == protection.locker || sender == quoter, "Launch buy route");
                require(uint128(output) <= 20_000_000 ether, "Launch max buy");
            }
        }
    }
}
