// SPDX-License-Identifier: BUSL-1.1
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
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {NOERRA_ACCESS_WINDOW_BLOCKS} from "../personal/NoerraRevenueCoin.sol";

/// @dev The single source of the standard trade fee (2%, USDC side, buys and sells). The hook, the
/// creation markets and the NOERRA market all pin this value; change it here only.
uint256 constant NOERRA_TRADE_FEE_BPS = 200;
/// @dev Anti-snipe launch fee: 25% in the launch block, falling linearly to the standard fee, then the standard fee
/// forever. NOERRA decays over 25 blocks ((2500 - 200) / 25 = 92 bps per block, standard from launch block + 25);
/// every agent token decays over 10 blocks ((2500 - 200) / 10 = 230 bps per block, standard from launch block + 10).
/// Fixed in code: no setter, exemption or extension.
uint256 constant NOERRA_LAUNCH_FEE_START_BPS = 2500;
uint256 constant NOERRA_LAUNCH_FEE_DECAY_BLOCKS = 25;
uint256 constant AGENT_LAUNCH_FEE_DECAY_BLOCKS = 10;

/// @notice The trade fee in force at `blockNumber` for a market launched at `launchBlock` (0: not launched) whose
/// launch fee decays over `decayBlocks` blocks.
function noerraLaunchFeeBps(uint256 launchBlock, uint256 blockNumber, uint256 decayBlocks) pure returns (uint256) {
    if (launchBlock == 0 || blockNumber < launchBlock) return NOERRA_TRADE_FEE_BPS;
    uint256 elapsed = blockNumber - launchBlock;
    if (elapsed >= decayBlocks) return NOERRA_TRADE_FEE_BPS;
    return NOERRA_LAUNCH_FEE_START_BPS - (NOERRA_LAUNCH_FEE_START_BPS - NOERRA_TRADE_FEE_BPS) * elapsed / decayBlocks;
}

interface INoerraCashFeeLocker {
    function manager() external view returns (IPoolManager);
    function dollar() external view returns (IERC20);
    function token() external view returns (IERC20);
    function feeHook() external view returns (address);
    function FEE() external view returns (uint24);
}
interface INoerraProtectedToken {
    function protectionStartBlock() external view returns(uint256);
    function protectionEndBlock() external view returns(uint256);
}
interface INoerraNoerMarket { function launchAccess(address wallet) external view returns(bool); }

/// @notice One fee, in USDC, on gross USDC consideration. The LP fee is zero. The rate follows the swapped pool's
/// launch schedule (noerraLaunchFeeBps): 25% at its launch block, the standard 2% once its decay blocks have passed.
/// Claims are minted before settlement; an authenticated locker may collect only its pool's fees.
abstract contract NoerraUsdcFeeHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    IPoolManager public immutable manager;
    uint256 public constant FEE_BPS = NOERRA_TRADE_FEE_BPS;
    uint256 public constant LAUNCH_FEE_START_BPS = NOERRA_LAUNCH_FEE_START_BPS;
    struct FeePool {address locker; address dollar;}
    mapping(PoolId => FeePool) public feePools;
    mapping(PoolId => uint256) public accruedFees;
    event SwapFee(PoolId indexed poolId, uint256 grossDollars, uint256 feeDollars);
    event FeesWithdrawn(PoolId indexed poolId, address indexed locker, uint256 dollars);

    /// @dev `lockerLiquidity`: the hook also gates beforeAddLiquidity (only the registered locker may add liquidity).
    constructor(IPoolManager manager_, bool lockerLiquidity) {
        require(address(manager_).code.length > 0, "Fee manager");
        Hooks.Permissions memory p;
        p.beforeInitialize = true; p.beforeAddLiquidity = lockerLiquidity; p.beforeSwap = true; p.afterSwap = true;
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
    function _pool(PoolKey calldata key) private view returns (FeePool memory p, PoolId id) {
        require(msg.sender == address(manager), "Manager only");
        id = key.toId(); p = feePools[id]; require(p.locker != address(0) && key.fee == 0, "Registered cash pool");
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
    /// @dev The pool's launch block (0 when it has none); fixed when the pool is registered or launched.
    function _launchBlock(PoolId id) internal view virtual returns (uint256);
    /// @dev The hook's LAUNCH_FEE_DECAY_BLOCKS.
    function _launchFeeDecayBlocks() internal pure virtual returns (uint256);
    /// @notice The fee rate a swap in this pool pays in the current block; quotes simulate the same rate.
    function poolFeeBps(PoolId id) public view returns (uint256) {
        return noerraLaunchFeeBps(_launchBlock(id), block.number, _launchFeeDecayBlocks());
    }
    function _fee(uint256 rate, uint256 dollars, bool net) private pure returns (uint256) {
        return Math.mulDiv(dollars, rate, net ? 10000 - rate : 10000, Math.Rounding.Ceil);
    }
    function _mint(PoolId id, address dollar, uint256 gross, uint256 fee) private {
        require(fee > 0 && fee <= uint256(uint128(type(int128).max)), "Fee bounds");
        accruedFees[id] += fee;
        // Physical USDC may not have settled yet. ERC6909 claims offset the returned hook delta.
        manager.mint(address(this), Currency.wrap(dollar).toId(), fee);
        emit SwapFee(id, gross, fee);
    }
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external returns (bytes4, BeforeSwapDelta, uint24) {
        (FeePool memory p, PoolId id) = _pool(key);
        if (!_specifiedDollar(key, params, p.dollar)) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0,0), 0);
        uint256 specified = _amount(params.amountSpecified);
        uint256 fee = _fee(poolFeeBps(id), specified, params.amountSpecified > 0);
        uint256 gross = params.amountSpecified < 0 ? specified : specified + fee;
        require(gross <= uint256(uint128(type(int128).max)) && (params.amountSpecified > 0 || fee < specified), "Fee gross bounds");
        _mint(id, p.dollar, gross, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)),0), 0);
    }
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external returns (bytes4, int128) {
        (FeePool memory p, PoolId id) = _pool(key);
        _protect(sender, id, key, delta);
        int128 cashDelta = Currency.unwrap(key.currency0) == p.dollar ? delta.amount0() : delta.amount1();
        uint256 dollars = _amount(int256(cashDelta));
        if (_specifiedDollar(key, params, p.dollar)) {
            _requireFullFill(id, params, dollars);
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 fee = _fee(poolFeeBps(id), dollars, cashDelta < 0);
        uint256 gross = cashDelta < 0 ? dollars + fee : dollars;
        require(gross <= uint256(uint128(type(int128).max)) && (cashDelta < 0 || fee < dollars), "Fee gross bounds");
        _mint(id, p.dollar, gross, fee);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }
    /// @dev Same block, same rate as beforeSwap: a fee computed from a requested specified amount must never
    /// overcharge a partial fill.
    function _requireFullFill(PoolId id, SwapParams calldata params, uint256 dollars) private view {
        uint256 specified = _amount(params.amountSpecified);
        uint256 specifiedFee = _fee(poolFeeBps(id), specified, params.amountSpecified > 0);
        require(dollars == (params.amountSpecified < 0 ? specified - specifiedFee : specified + specifiedFee), "Full USDC fill required");
    }
    function _protect(address, PoolId, PoolKey calldata, BalanceDelta) internal view virtual {}
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
    /// @dev Retained getter: the launch-block rate, equal to LAUNCH_FEE_START_BPS.
    uint256 public constant LAUNCH_FEE_BPS = NOERRA_LAUNCH_FEE_START_BPS;
    uint256 public constant LAUNCH_FEE_DECAY_BLOCKS = NOERRA_LAUNCH_FEE_DECAY_BLOCKS;
    /// @notice Blocks from the launch block in which a buy requires the market's launchAccess.
    uint256 public constant ACCESS_WINDOW_BLOCKS = NOERRA_ACCESS_WINDOW_BLOCKS;
    address public immutable dollar;
    address public immutable token;
    address public immutable registrationAuthority;
    address public locker;
    constructor(IPoolManager manager_, address dollar_, address token_, address authority_) NoerraUsdcFeeHook(manager_, true) {
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
    /// @notice Only the locker (the NOERRA market, which seeds the permanent full position
    /// once) may add liquidity. The LP fee is zero, so a narrow position added just above spot around a permissionless burn() and
    /// removed after it would otherwise capture part of every NOERRA burn (zero-fee JIT sandwich). Removal is not gated: the
    /// market never removes and nobody else can hold a position. Hook address flags 0x28cc (BEFORE_ADD_LIQUIDITY added).
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view returns (bytes4) {
        require(msg.sender == address(manager) && sender == locker && sender != address(0), "NOERRA locker liquidity only");
        return IHooks.beforeAddLiquidity.selector;
    }
    /// @notice NOERRA's decaying launch fee: 25% in its launch block, down 92 bps per block to the standard FEE_BPS
    /// from launch block + 25, then FEE_BPS forever. Every buyer pays it. The launch block
    /// is the token's one-shot protectionStartBlock; there is no setter, exemption wallet, or way to extend the schedule.
    function feeBps() public view returns(uint256) {
        return noerraLaunchFeeBps(_launchBlock(PoolId.wrap(0)), block.number, LAUNCH_FEE_DECAY_BLOCKS);
    }
    /// @dev One registered pool, so its launch block is the token's.
    function _launchBlock(PoolId) internal view override returns (uint256) {
        return INoerraProtectedToken(token).protectionStartBlock();
    }
    function _launchFeeDecayBlocks() internal pure override returns (uint256) {return LAUNCH_FEE_DECAY_BLOCKS;}
    /// @notice While the token's protection window is open, any buy (any router) is capped at 20M NOERRA; in the
    /// first ACCESS_WINDOW_BLOCKS blocks the transaction signer must have the market's launchAccess.
    /// @dev tx.origin is deliberate: launchAccess is an allowlist of signers, not an authorization over value. It lets
    /// a listed wallet buy through any router, and no contract or other signer can present a listed origin.
    function _protect(address, PoolId, PoolKey calldata key, BalanceDelta delta) internal view override {
        if(block.number < INoerraProtectedToken(token).protectionEndBlock()) {
            int128 output = Currency.unwrap(key.currency0) == token ? delta.amount0() : delta.amount1();
            if(output > 0) {
                if(block.number < INoerraProtectedToken(token).protectionStartBlock() + ACCESS_WINDOW_BLOCKS)
                    require(INoerraNoerMarket(locker).launchAccess(tx.origin), "Launch access window");
                require(uint128(output) <= 20_000_000 ether, "Launch max buy");
            }
        }
    }
}
