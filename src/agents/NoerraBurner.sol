// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

interface INoerraBurnHook {
    function feeBps() external view returns (uint256);
    function FEE_BPS() external view returns (uint256);
    function locker() external view returns (address);
    function token() external view returns (address);
}
interface INoerraBurnMarket {
    function dollar() external view returns (address);
    function token() external view returns (address);
    function manager() external view returns (IPoolManager);
    function feeHook() external view returns (INoerraBurnHook);
    function protectionQuoter() external view returns (address);
    function lockedLiquidity() external view returns (uint128);
    function poolKey() external view returns (PoolKey memory);
    function trade(bool buy, uint256 amountIn, uint256 minimumOut, uint256 deadline) external returns (uint256);
    function ethUsdFeed() external view returns (address);
    function oracleMaximumAge() external view returns (uint32);
}
interface INoerraBurnToken {
    function burn(uint256 value) external;
    function protectionEndBlock() external view returns (uint256);
    function launchMarket() external view returns (address);
}

/// @notice One per deployment. Holds the 5% NOERRA-burn row of every agent token's fees and the creators' launch
/// burns, and turns them into NOERRA bought on NOERRA's canonical market and burned (totalSupply decreases).
/// @dev NOERRA's identity is pinned at deployment: the reviewed NOERRA token address (it may be deployed later), the
/// PoolManager and USDC. The market is the token's own one-shot `launchMarket`, which only the token's launch
/// authority (the reviewed atomic launch factory in production) can set, so no key can redirect the burn through a
/// later registry or vault enrollment. Before NOERRA launches the burner only accumulates USDC; it has no other outflow.
/// Protections on every buy:
/// (1) refuse during NOERRA's launch-protection window (25% fee, capped buys);
/// (2) the output is the on-chain quote of the exact amount, and that quote must be within 1% of the spot-price
///     output after the 2% fee (max 1% price impact); burn() halves its chunk until it fits, so any balance burns;
/// (3) manipulation guard: the pool has no oracle, so spot observations are kept per block in 8 slots (observe(),
///     every burn, every deferred launch burn). A buy needs one observation from an EARLIER block, at most 30 minutes
///     old, with spot within 1% of it. A poisoned observation cannot block a later honest one, and a same-block
///     observation never counts. Moving the price for the burner must persist across blocks; each manipulating round
///     trip pays the 2% hook fee twice.
/// Ramp and caller refund: the first burn() spends at most
/// MINIMUM_BURN_USDC and each later one at most twice the previous chunk, so a pre-launch backlog never meets the pool in one
/// trade; NOERRA's hook lets only the market add liquidity (no JIT position around a permissionless burn). burn() pays its caller
/// min(0.2% of the chunk, 2 x REFUND_GAS (470,000) gas at the block base fee, valued with the NOERRA market's ETH/USD feed) so anyone burns
/// every block once that covers gas; a missing or stale feed pays nothing (the burn still runs). burnLaunch() pays none.
/// One-time fallback: if NOERRA never binds a live market at the pinned
/// address (for example a redone launch at another address), the USDC would otherwise wait here forever. UNBOUND_GRACE (365 days)
/// after the burner first held MINIMUM_BURN_USDC (startGrace(), anyone), and only while NOERRA has never bound here, anyone may
/// abandon the burner once; from then on it never burns and every USDC it holds or later receives goes to the fixed protocol
/// treasury. The first observe()/burn()/startGrace() that sees NOERRA's live market latches `bound`, and abandonment also needs
/// the market to be absent at that moment, so the treasury can never take the burn of a working NOERRA; it can never be undone.
contract NoerraBurner is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    IERC20 public immutable dollar;
    address public immutable noerraToken;
    IPoolManager public immutable poolManager;
    address public immutable launchFactory;
    /// @notice The only other destination: the protocol treasury, after a one-time abandonment (see above).
    address public immutable treasury;
    uint256 public immutable deployedAt;
    uint256 public constant UNBOUND_GRACE = 365 days;
    /// @notice When the burner first held MINIMUM_BURN_USDC (startGrace()); the abandonment grace runs from here. 0 = not yet.
    uint256 public fundedAt;
    /// @notice Latched the first time NOERRA's live market was seen (observe, burn, startGrace); then never abandonable.
    bool public bound;
    /// @notice burn()'s caller refund: at most REFUND_BPS of the chunk and 2 x REFUND_GAS gas at the base fee.
    uint256 public constant REFUND_BPS = 20;
    /// @dev Measured steady burn gas x ~1.1 (mainnet fork: the lane's pre-sized burn(maxIn) used
    ///      389,762-424,880 gas, x 1.1 = 467,368; permissionless burn() 377,189-484,022), down from 500,000.
    uint256 public constant REFUND_GAS = 470_000;
    uint256 public totalRefundedUSDC;
    uint256 public constant MINIMUM_BURN_USDC = 20e6;
    uint256 public constant MINIMUM_CHUNK_USDC = 1e6;
    uint256 public constant MAX_PRICE_IMPACT_BPS = 100;
    uint256 public constant MAX_DEVIATION_BPS = 100;
    uint256 public constant MAX_OBSERVATION_AGE = 30 minutes;
    uint256 public constant OBSERVATION_SLOTS = 8;
    struct Observation { uint160 sqrtPriceX96; uint48 blockNumber; uint48 timestamp; }
    Observation[8] public observations;
    /// @notice The last chunk burn() spent; the next call starts at twice this (bounded by its cap and balance).
    uint256 public lastChunkUSDC;
    uint256 public totalBurnedUSDC;
    uint256 public totalBurnedNoerra;
    /// @notice Set once, permanently, when NOERRA never bound within UNBOUND_GRACE.
    bool public abandoned;
    uint256 public totalSweptUSDC;
    event Abandoned(address indexed caller, uint256 at);
    event GraceStarted(uint256 at, uint256 balance);
    event BurnRefund(address indexed caller, uint256 amount);
    event SweptToTreasury(address indexed caller, address indexed treasury, uint256 amount);
    event Observed(uint160 sqrtPriceX96, uint256 blockNumber);
    event Burned(address indexed caller, uint256 usdcIn, uint256 noerraBurned, bool launch);
    event LaunchBurnDeferred(uint256 amount);

    constructor(IERC20 dollar_, address noerraToken_, IPoolManager manager_, address launchFactory_, address treasury_) {
        require(address(dollar_).code.length > 0 && address(manager_).code.length > 0 && noerraToken_ != address(0)
            && noerraToken_ != address(dollar_) && launchFactory_ != address(0) && treasury_ != address(0)
            && treasury_ != noerraToken_ && treasury_ != address(dollar_), "Burner pins");
        dollar = dollar_; noerraToken = noerraToken_; poolManager = manager_; launchFactory = launchFactory_;
        treasury = treasury_; deployedAt = block.timestamp;
    }

    /// @notice NOERRA's canonical market (the pinned token's launch market), or zero before it launches.
    function market() public view returns (INoerraBurnMarket m) {
        if (abandoned || noerraToken.code.length == 0) return m;
        m = INoerraBurnMarket(INoerraBurnToken(noerraToken).launchMarket());
        if (address(m).code.length == 0 || m.token() != noerraToken || m.dollar() != address(dollar)
            || address(m.manager()) != address(poolManager) || m.feeHook().locker() != address(m)
            || m.feeHook().token() != noerraToken || m.lockedLiquidity() == 0) return INoerraBurnMarket(address(0));
    }

    /// @notice Whether the one-time fallback may run now: the grace since first funding has passed and NOERRA never bound.
    function abandonable() public view returns (bool) {
        return !abandoned && !bound && fundedAt != 0 && block.timestamp >= fundedAt + UNBOUND_GRACE
            && address(market()) == address(0);
    }

    /// @notice Anyone may call once: starts the abandonment grace when the burner first holds MINIMUM_BURN_USDC. A NOERRA
    /// already live latches `bound` instead (no grace ever runs).
    function startGrace() external {
        uint256 balance = dollar.balanceOf(address(this));
        require(fundedAt == 0 && !abandoned && !bound && balance >= MINIMUM_BURN_USDC, "Grace started or unfunded");
        if (address(market()) != address(0)) { bound = true; return; }
        fundedAt = block.timestamp;
        emit GraceStarted(block.timestamp, balance);
    }

    /// @notice Anyone may call. Abandons the burner once if NOERRA never bound (abandonable()), then sends every USDC the
    /// abandoned burner holds to the treasury. Later calls sweep later arrivals.
    function releaseUnbound() external nonReentrant returns (uint256 amount) {
        if (!abandoned) {
            require(abandonable(), "NOERRA bound or grace running");
            abandoned = true;
            emit Abandoned(msg.sender, block.timestamp);
        }
        amount = dollar.balanceOf(address(this));
        if (amount > 0) {
            totalSweptUSDC += amount;
            dollar.safeTransfer(treasury, amount);
        }
        emit SweptToTreasury(msg.sender, treasury, amount);
    }

    /// @notice True once NOERRA trades at its standard fee (its launch-protection window has ended).
    function ready() public view returns (bool) {
        INoerraBurnMarket m = market();
        if (address(m) == address(0)) return false;
        uint256 end = INoerraBurnToken(noerraToken).protectionEndBlock();
        return end != 0 && block.number >= end && m.feeHook().feeBps() == m.feeHook().FEE_BPS();
    }

    function _spot(INoerraBurnMarket m) private view returns (PoolKey memory key, uint160 sqrtPriceX96) {
        key = m.poolKey();
        require(address(key.hooks) == address(m.feeHook()), "NOERRA pool");
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        require(sqrtPriceX96 > 0, "NOERRA pool");
    }

    /// @notice Record the spot price for a later block's burn. Anyone may call it.
    function observe() public {
        INoerraBurnMarket m = market();
        require(address(m) != address(0) && ready(), "NOERRA not ready");
        (, uint160 price) = _spot(m);
        if (!bound) bound = true;
        _record(price);
    }

    function _record(uint160 price) private {
        observations[block.number % OBSERVATION_SLOTS] = Observation(price, uint48(block.number), uint48(block.timestamp));
        emit Observed(price, block.number);
    }

    function _near(uint160 price, uint160 observed) private pure returns (bool) {
        uint256 ratio = Math.mulDiv(Math.mulDiv(1e18, price, observed), price, observed);
        return ratio <= 1e18 + 1e14 * MAX_DEVIATION_BPS && ratio + 1e14 * MAX_DEVIATION_BPS >= 1e18;
    }

    /// @notice Whether spot is confirmed by an observation from an earlier block, at most 30 minutes old.
    function confirmed(uint160 price) public view returns (bool) {
        for (uint256 i; i < OBSERVATION_SLOTS; ++i) {
            Observation memory o = observations[i];
            if (o.sqrtPriceX96 != 0 && o.blockNumber < block.number && block.timestamp <= uint256(o.timestamp) + MAX_OBSERVATION_AGE
                && _near(price, o.sqrtPriceX96)) return true;
        }
        return false;
    }

    /// @notice Exact-input quote of `amount` USDC and the spot-price output after the hook fee.
    function quote(uint256 amount) public returns (uint256 quoted, uint256 ideal) {
        INoerraBurnMarket m = market();
        require(address(m) != address(0) && amount > 0 && amount <= type(uint128).max, "NOERRA not ready");
        (PoolKey memory key, uint160 price) = _spot(m);
        bool dollarFirst = Currency.unwrap(key.currency0) == address(dollar);
        uint256 net = amount - Math.mulDiv(amount, m.feeHook().feeBps(), 10000, Math.Rounding.Ceil);
        // price = currency1 per currency0 = sqrtPrice^2 / 2^192.
        ideal = dollarFirst ? Math.mulDiv(Math.mulDiv(net, price, 1 << 96), price, 1 << 96)
            : Math.mulDiv(Math.mulDiv(net, 1 << 96, price), 1 << 96, price);
        (quoted,) = IV4Quoter(m.protectionQuoter()).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(key, dollarFirst, uint128(amount), ""));
    }

    function _impactOk(uint256 quoted, uint256 ideal) private pure returns (bool) {
        return quoted > 0 && quoted * 10000 >= ideal * (10000 - MAX_PRICE_IMPACT_BPS);
    }

    function _buyAndBurn(INoerraBurnMarket m, uint256 amount, uint256 minimumOut, bool launch) private returns (uint256 burned) {
        IERC20 noer = IERC20(noerraToken);
        uint256 beforeToken = noer.balanceOf(address(this));
        dollar.forceApprove(address(m), amount);
        m.trade(true, amount, minimumOut, block.timestamp);
        dollar.forceApprove(address(m), 0);
        burned = noer.balanceOf(address(this)) - beforeToken;
        require(burned >= minimumOut, "Burn output");
        INoerraBurnToken(noerraToken).burn(burned);
        totalBurnedUSDC += amount; totalBurnedNoerra += burned;
        (, uint160 price) = _spot(m);
        _record(price);
        emit Burned(msg.sender, amount, burned, launch);
    }

    function burn() external returns (uint256 usdcIn, uint256 noerraBurned) { return burn(type(uint256).max); }

    /// @notice Anyone may burn once the burner holds at least 20 USDC. Spends at most `maxIn` (and at most twice the
    /// previous chunk), halving until the quote fits the 1% impact bound; the rest burns in later blocks.
    function burn(uint256 maxIn) public nonReentrant returns (uint256 usdcIn, uint256 noerraBurned) {
        uint256 balance = dollar.balanceOf(address(this));
        require(balance >= MINIMUM_BURN_USDC, "Minimum burn");
        INoerraBurnMarket m = market();
        require(address(m) != address(0) && ready(), "NOERRA not ready");
        if (!bound) bound = true;
        (, uint160 price) = _spot(m);
        require(confirmed(price), "Fresh earlier observation");
        // The ramp starts at MINIMUM_BURN_USDC (also before any burn) and at most doubles per burn.
        uint256 chunk = Math.min(Math.min(balance, maxIn), Math.max(lastChunkUSDC * 2, MINIMUM_BURN_USDC));
        require(chunk >= MINIMUM_CHUNK_USDC, "Burn chunk");
        uint256 gasValue = gasRefundCap(m);
        uint256 refund;
        uint256 quoted;
        bool halved;
        while (true) {
            uint256 ideal;
            refund = Math.min(chunk * REFUND_BPS / 10000, gasValue);
            usdcIn = chunk - refund;
            (quoted, ideal) = quote(usdcIn);
            if (_impactOk(quoted, ideal)) break;
            require(chunk / 2 >= MINIMUM_CHUNK_USDC, "Price impact");
            chunk /= 2; halved = true;
        }
        // Only an impact-limited chunk lowers the memory; a caller's small cap cannot slow later burns.
        lastChunkUSDC = halved ? chunk : Math.max(lastChunkUSDC, chunk);
        noerraBurned = _buyAndBurn(m, usdcIn, quoted, false);
        if (refund != 0) {
            totalRefundedUSDC += refund;
            dollar.safeTransfer(msg.sender, refund);
            emit BurnRefund(msg.sender, refund);
        }
    }

    /// @notice USDC value of 2 x REFUND_GAS gas at the current base fee, priced with the NOERRA market's ETH/USD feed (8
    /// decimals; the feed NOERRA's launch valuation uses, within the market's maximum age). Any feed failure answers 0.
    function gasRefundCap(INoerraBurnMarket m) public view returns (uint256) {
        uint256 gasWei = 2 * REFUND_GAS * block.basefee;
        if (gasWei == 0) return 0;
        (bool ok, bytes memory data) = address(m).staticcall(abi.encodeCall(INoerraBurnMarket.ethUsdFeed, ()));
        if (!ok || data.length != 32) return 0;
        address feed = abi.decode(data, (address));
        (ok, data) = address(m).staticcall(abi.encodeCall(INoerraBurnMarket.oracleMaximumAge, ()));
        if (!ok || data.length != 32 || feed.code.length == 0) return 0;
        uint256 maximumAge = abi.decode(data, (uint256));
        (ok, data) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!ok || data.length != 160) return 0;
        (, int256 answer,, uint256 updated,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || answer > 1_000_000e8 || updated == 0 || updated > block.timestamp
            || block.timestamp - updated > maximumAge) return 0;
        // wei x (USD per ETH x 1e8) / 1e18 / 1e8 x 1e6 USDC units
        return Math.mulDiv(gasWei, uint256(answer), 1e20);
    }

    /// @notice The launch factory burns exactly a creator's launch payment. It keeps the USDC here (returns 0) when no
    /// earlier-block observation confirms spot (recording one for the next launch), and reverts (the factory then
    /// keeps the USDC here too) while NOERRA is not ready or when the quote exceeds the impact bound.
    function burnLaunch(uint256 amount) external nonReentrant returns (uint256 noerraBurned) {
        require(msg.sender == launchFactory, "Launch factory only");
        require(amount > 0 && dollar.balanceOf(address(this)) >= amount, "Launch burn funding");
        INoerraBurnMarket m = market();
        require(address(m) != address(0) && ready(), "NOERRA not ready");
        (, uint160 price) = _spot(m);
        if (!confirmed(price)) { _record(price); emit LaunchBurnDeferred(amount); return 0; }
        (uint256 quoted, uint256 ideal) = quote(amount);
        require(_impactOk(quoted, ideal), "Price impact");
        noerraBurned = _buyAndBurn(m, amount, quoted, true);
    }
}
