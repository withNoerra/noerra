// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

interface INoerraCashFeeLocker {
    function manager() external view returns (IPoolManager);
    function dollar() external view returns (IERC20);
    function token() external view returns (IERC20);
    function feeHook() external view returns (address);
    function FEE() external view returns (uint24);
}
interface INoerraProtectedToken { function protectionEndBlock() external view returns(uint256); }
interface INoerraProtectedMarket { function protectionQuoter() external view returns(address); }

/// @notice One fee, in USDC, on gross USDC consideration. The LP fee is zero.
/// Claims are minted before settlement; an authenticated locker may collect only its pool's fees.
abstract contract NoerraUsdcFeeHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    IPoolManager public immutable manager;
    uint256 public constant FEE_BPS = 175;
    struct FeePool {address locker; address dollar;}
    mapping(PoolId => FeePool) public feePools;
    mapping(PoolId => uint256) public accruedFees;
    event SwapFee(PoolId indexed poolId, uint256 grossDollars, uint256 feeDollars);
    event FeesWithdrawn(PoolId indexed poolId, address indexed locker, uint256 dollars);

    constructor(IPoolManager manager_) {
        require(address(manager_).code.length > 0, "Fee manager");
        Hooks.Permissions memory p;
        p.beforeInitialize = true; p.beforeSwap = true; p.afterSwap = true;
        p.beforeSwapReturnDelta = true; p.afterSwapReturnDelta = true;
        Hooks.validateHookPermissions(IHooks(address(this)), p);
        manager = manager_;
    }
    function _register(PoolKey memory key, address locker, address dollar) internal {
        require(locker != address(0) && dollar != address(0) && key.fee == 0
            && key.tickSpacing == 60 && address(key.hooks) == address(this)
            && (Currency.unwrap(key.currency0) == dollar || Currency.unwrap(key.currency1) == dollar), "Cash fee pool");
        PoolId id = key.toId(); require(feePools[id].locker == address(0), "Fee pool fixed");
        feePools[id] = FeePool(locker, dollar);
    }
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        require(msg.sender == address(manager) && sender != address(0)
            && sender == feePools[key.toId()].locker, "Canonical pool initialization");
        return IHooks.beforeInitialize.selector;
    }
    function _pool(PoolKey calldata key) private view returns (FeePool memory p) {
        require(msg.sender == address(manager), "Manager only");
        p = feePools[key.toId()]; require(p.locker != address(0) && key.fee == 0, "Registered cash pool");
    }
    function _specifiedDollar(PoolKey calldata key, SwapParams calldata params, address dollar) private pure returns (bool) {
        bool specified0 = (params.amountSpecified < 0) == params.zeroForOne;
        return Currency.unwrap(specified0 ? key.currency0 : key.currency1) == dollar;
    }
    function _amount(int256 amount) private pure returns (uint256) {
        require(amount != type(int256).min, "Swap amount bounds");
        uint256 result = uint256(amount < 0 ? -amount : amount);
        require(result > 0 && result <= uint256(uint128(type(int128).max)), "Swap amount bounds"); return result;
    }
    function feeBps() public view virtual returns(uint256) {return FEE_BPS;}
    function _fee(uint256 dollars, bool net) private view returns (uint256) {
        uint256 rate=feeBps();
        return Math.mulDiv(dollars, rate, net ? 10000 - rate : 10000, Math.Rounding.Ceil);
    }
    function _mint(PoolKey calldata key, address dollar, uint256 gross, uint256 fee) private {
        require(fee > 0 && fee <= uint256(uint128(type(int128).max)), "Fee bounds");
        PoolId id = key.toId(); accruedFees[id] += fee;
        // Physical USDC may not have settled yet. ERC6909 claims offset the returned hook delta.
        manager.mint(address(this), Currency.wrap(dollar).toId(), fee);
        emit SwapFee(id, gross, fee);
    }
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external returns (bytes4, BeforeSwapDelta, uint24) {
        FeePool memory p = _pool(key);
        if (!_specifiedDollar(key, params, p.dollar)) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0,0), 0);
        uint256 specified = _amount(params.amountSpecified); uint256 fee = _fee(specified, params.amountSpecified > 0);
        uint256 gross = params.amountSpecified < 0 ? specified : specified + fee;
        require(gross <= uint256(uint128(type(int128).max)) && (params.amountSpecified > 0 || fee < specified), "Fee gross bounds");
        _mint(key, p.dollar, gross, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)),0), 0);
    }
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external returns (bytes4, int128) {
        FeePool memory p = _pool(key);
        _protect(sender, key, delta);
        int128 cashDelta = Currency.unwrap(key.currency0) == p.dollar ? delta.amount0() : delta.amount1();
        uint256 dollars = _amount(int256(cashDelta));
        if (_specifiedDollar(key, params, p.dollar)) {
            uint256 specified = _amount(params.amountSpecified); uint256 specifiedFee = _fee(specified, params.amountSpecified > 0);
            // A fee computed from a requested specified amount must never overcharge a partial fill.
            require(dollars == (params.amountSpecified < 0 ? specified - specifiedFee : specified + specifiedFee), "Full USDC fill required");
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 fee = _fee(dollars, cashDelta < 0);
        uint256 gross = cashDelta < 0 ? dollars + fee : dollars;
        require(gross <= uint256(uint128(type(int128).max)) && (cashDelta < 0 || fee < dollars), "Fee gross bounds");
        _mint(key, p.dollar, gross, fee);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }
    function _protect(address, PoolKey calldata, BalanceDelta) internal view virtual {}
    function withdrawFees(PoolKey calldata key) external returns (uint256 amount) {
        PoolId id = key.toId(); FeePool memory p = feePools[id];
        require(p.locker != address(0) && msg.sender == p.locker, "Fee locker only");
        amount = accruedFees[id]; accruedFees[id] = 0;
        if (amount > 0) {
            Currency currency = Currency.wrap(p.dollar);
            manager.burn(address(this), currency.toId(), amount); manager.take(currency, p.locker, amount);
        }
        emit FeesWithdrawn(id, p.locker, amount);
    }
}

/// @notice Separate hook keeps canonical NOERRA trades taxable: a self-hook router is skipped by v4.
contract NoerraNoerFeeHook is NoerraUsdcFeeHook {
    uint256 public constant LAUNCH_FEE_BPS = 2500;
    address public immutable dollar;
    address public immutable token;
    address public immutable registrationAuthority;
    address public locker;
    constructor(IPoolManager manager_, address dollar_, address token_, address authority_) NoerraUsdcFeeHook(manager_) {
        require(dollar_.code.length > 0 && token_.code.length > 0 && dollar_ != token_ && authority_ != address(0), "NOERRA hook pins");
        dollar = dollar_; token = token_; registrationAuthority = authority_;
    }
    function register(address locker_) external {
        require(msg.sender == registrationAuthority && locker == address(0), "One NOERRA fee locker");
        INoerraCashFeeLocker m = INoerraCashFeeLocker(locker_);
        require(address(m.manager()) == address(manager) && address(m.dollar()) == dollar && address(m.token()) == token
            && m.feeHook() == address(this) && m.FEE() == 0, "NOERRA hook wiring");
        locker = locker_; bool first = token < dollar;
        _register(PoolKey(Currency.wrap(first ? token : dollar), Currency.wrap(first ? dollar : token),0,60,IHooks(address(this))),locker_,dollar);
    }
    /// @notice NOERRA alone pays 25% for launch blocks 0–9, then 1.75% forever.
    /// There is no setter, exemption wallet, or way to extend the launch window.
    function feeBps() public view override returns(uint256) {
        uint256 end=INoerraProtectedToken(token).protectionEndBlock();
        return end!=0 && block.number<end ? LAUNCH_FEE_BPS : FEE_BPS;
    }
    function _protect(address sender, PoolKey calldata key, BalanceDelta delta) internal view override {
        if(block.number < INoerraProtectedToken(token).protectionEndBlock()) {
            int128 output = Currency.unwrap(key.currency0) == token ? delta.amount0() : delta.amount1();
            if(output > 0) {
                require(sender == locker || sender == INoerraProtectedMarket(locker).protectionQuoter(), "Launch buy route");
                require(uint128(output) <= 20_000_000 ether, "Launch max buy");
            }
        }
    }
}
