// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IVeniceDiem} from "./NoerraDiem.sol";
import {NoerraAgentMirror, NoerraAgentMirrorRegistry} from "./NoerraAgentMirror.sol";

/// @dev Circle CCTP V2 MessageTransmitterV2 (Base). The reserve is the fixed destinationCaller of its escrow's burns.
interface IEarnedDiemMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @dev Circle CCTP V2 TokenMessengerV2 (Base). Used only to return surplus USDC to the agent's Ethereum account.
interface IEarnedDiemReturnMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @dev Uniswap SwapRouter02 IV3SwapRouter exact-output tuple; path is reversed (DIEM first, USDC last).
interface IEarnedDiemSwapRouter {
    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

/// @dev Uniswap QuoterV2. Not a view function (it simulates and reverts internally) but callable on chain.
interface IEarnedDiemQuoterV2 {
    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        returns (uint256 amountIn, uint160[] memory sqrtPriceX96AfterList, uint32[] memory ticksCrossed, uint256 gas);
}

/// @dev Uniswap V3 pool oracle surface used for the manipulation guard.
interface IEarnedDiemPool {
    function slot0()
        external
        view
        returns (uint160, int24 tick, uint16, uint16 observationCardinality, uint16 observationCardinalityNext, uint8, bool);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @dev Shared, immutable configuration the deterministic factory hands to each reserve it deploys.
interface IEarnedDiemReserveConfiguration {
    struct Infrastructure {
        IERC20 dollar;
        IVeniceDiem diem;
        NoerraAgentMirrorRegistry mirrors;
        IEarnedDiemMessageTransmitterV2 transmitter;
        IEarnedDiemReturnMessengerV2 tokenMessenger;
        IEarnedDiemSwapRouter router;
        IEarnedDiemQuoterV2 quoter;
        address sourceDollar;
        address sourceTokenMessenger;
        address platform;
        /// @dev Reviewed signature-verification forwarders (e.g. a deployed ERC-6492 validator, Multicall3) that never
        /// act on a result; zero when unused. Asset and infrastructure contracts can never be listed.
        address[2] signatureVerifiers;
    }

    struct Route {
        address hopToken;
        uint24 diemFee;
        uint24 hopFee;
        address diemPool;
        address hopPool;
    }

    struct Bounds {
        uint256 slippageBps;
        uint32 twapWindow;
        uint32 longWindow;
        uint24 maxTickDeviation;
        uint24 maxLongTickDeviation;
        uint256 maxReturnFee;
        uint256 minimumReturnUSDC;
    }

    struct Pins {
        bytes32 dollar;
        bytes32 diem;
        bytes32 transmitter;
        bytes32 tokenMessenger;
        bytes32 router;
        bytes32 quoter;
    }

    function infrastructure() external view returns (Infrastructure memory);
    function route() external view returns (Route memory);
    function bounds() external view returns (Bounds memory);
    function pins() external view returns (Pins memory);
}

/// @notice One agent's brain fund on Base: USDC arriving from its Ethereum escrow (20% of its fees) or any deposit is
/// bought into DIEM on a pinned Uniswap path and staked at Venice for the agent's inference, up to 10 DIEM staked.
/// @dev Deployed by NoerraEarnedDiemReserveFactory at a CREATE2 address keyed only by agentId, so the Ethereum escrow
/// can bridge to it before it exists. Every step is permissionless: the agent's own computer cranks it, and anyone may.
/// There is no owner, creator control, pause, target, daily cap or fixed price cap. Each buy is bounded by a live
/// on-chain quote of the exact amount (slippage bound), a 1% price impact limit against the pools' 30-minute
/// time-weighted price, and a one-sided oracle guard (spot not above its 30-minute average, that average not above the
/// 4-hour one). The platform alone may withdraw staked DIEM, unconditionally, 7 days after it asks, to its fixed address.
/// Venice wallet sign-in works through ERC-1271 for the current signer, but never for a token, router or bridge caller.
contract NoerraEarnedDiemReserve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CAP = 10 ether;
    uint256 public constant MAX_IMPACT_BPS = 100;
    uint256 public constant PLATFORM_WITHDRAWAL_DELAY = 7 days;
    uint32 public constant SOURCE_DOMAIN = 0;
    uint32 public constant BASE_DOMAIN = 6;
    uint32 public constant STANDARD_FINALITY = 2000;
    /// @dev Uniswap Permit2 (same address on every chain); it validates contract signatures through ERC-1271.
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant Q96 = 2 ** 96;
    /// @notice With no buy for this long (keeper offline, or no mirrored signer), anyone may buy, under every guard.
    uint256 public constant KEEPER_LIVENESS = 7 days;
    /// @notice With no buy for this long since funds arrived, anyone may return all of the reserve's USDC to the agent.
    uint256 public constant IDLE_EXIT = 30 days;
    /// @notice Below the cap the reserve keeps this multiple (percent) of the remaining capacity's time-weighted cost.
    uint256 public constant KEEP_PERCENT = 125;
    /// @notice A return may carry a CCTP fee up to this share of its amount (basis points) when above maxReturnFee.
    uint256 public constant PROPORTIONAL_FEE_BPS = 10;
    bytes32 public constant BUY_TYPEHASH =
        keccak256("BrainFundBuy(uint256 diemOut,uint256 maxUsdcIn,uint256 deadline,uint256 nonce)");

    address public immutable factory;
    bytes32 public immutable agentId;
    IERC20 public immutable dollar;
    IVeniceDiem public immutable diem;
    NoerraAgentMirrorRegistry public immutable mirrors;
    IEarnedDiemMessageTransmitterV2 public immutable transmitter;
    IEarnedDiemReturnMessengerV2 public immutable tokenMessenger;
    IEarnedDiemSwapRouter public immutable router;
    IEarnedDiemQuoterV2 public immutable quoter;
    address public immutable sourceDollar;
    address public immutable sourceTokenMessenger;
    address public immutable platform;
    address public immutable hopToken;
    uint24 public immutable diemFee;
    uint24 public immutable hopFee;
    address public immutable diemPool;
    address public immutable hopPool;
    uint256 public immutable slippageBps;
    uint32 public immutable twapWindow;
    uint32 public immutable longWindow;
    uint24 public immutable maxTickDeviation;
    uint24 public immutable maxLongTickDeviation;
    bool public immutable diemIsToken0;
    bool public immutable hopIsToken0;
    address public immutable verifierA;
    address public immutable verifierB;
    uint256 public immutable maxReturnFee;
    uint256 public immutable minimumReturnUSDC;
    bytes32 private immutable dollarCodeHash;
    bytes32 private immutable diemCodeHash;
    bytes32 private immutable transmitterCodeHash;
    bytes32 private immutable tokenMessengerCodeHash;
    bytes32 private immutable routerCodeHash;
    bytes32 private immutable quoterCodeHash;

    struct PlatformWithdrawal {
        bytes32 operation;
        uint256 amount;
        uint64 requestedAt;
        uint64 availableAt;
    }

    /// @notice At most one platform withdrawal is pending; its operation id is single use forever.
    PlatformWithdrawal public pendingWithdrawal;
    mapping(bytes32 => bool) public operations;
    uint256 public totalReceivedUSDC;
    uint256 public totalSpentUSDC;
    uint256 public totalAcquiredDiem;
    uint256 public totalDepositedDiem;
    uint256 public totalReturnedUSDC;
    uint256 public totalWithdrawnDiem;
    /// @notice Single-use counter bound into every keeper buy authorization.
    uint256 public buyNonce;
    uint256 public lastAcquireAt;
    /// @notice When unspent bridged funds first arrived since the last buy (0 when none): newly bridged USDC stays
    /// keeper-only for KEEPER_LIVENESS, however long the reserve was idle before (F-6). Only the first arrival sets it.
    uint256 public pendingSince;

    event BridgeReceived(
        bytes32 indexed nonce, address indexed depositor, uint256 grossUSDC, uint256 fee, uint256 netUSDC
    );
    event Acquired(uint256 diemAmount, uint256 usdcSpent, uint256 quotedUSDC, uint256 twapUSDC, uint256 staked);
    event DepositStaked(uint256 diemAmount, uint256 staked);
    event ExcessReturned(address indexed sourceAccount, uint256 amount, uint256 maxFee);
    event PlatformWithdrawalRequested(bytes32 indexed operation, uint256 amount, uint256 availableAt, uint256 veniceEnd);
    event PlatformWithdrawalCompleted(bytes32 indexed operation, address indexed platform, uint256 amount);

    constructor(bytes32 agentId_) {
        require(agentId_ != bytes32(0), "Agent identity");
        IEarnedDiemReserveConfiguration source = IEarnedDiemReserveConfiguration(msg.sender);
        IEarnedDiemReserveConfiguration.Infrastructure memory i = source.infrastructure();
        IEarnedDiemReserveConfiguration.Route memory r = source.route();
        IEarnedDiemReserveConfiguration.Bounds memory b = source.bounds();
        IEarnedDiemReserveConfiguration.Pins memory p = source.pins();
        factory = msg.sender;
        agentId = agentId_;
        lastAcquireAt = block.timestamp;
        dollar = i.dollar;
        diem = i.diem;
        mirrors = i.mirrors;
        transmitter = i.transmitter;
        tokenMessenger = i.tokenMessenger;
        router = i.router;
        quoter = i.quoter;
        sourceDollar = i.sourceDollar;
        sourceTokenMessenger = i.sourceTokenMessenger;
        platform = i.platform;
        verifierA = i.signatureVerifiers[0];
        verifierB = i.signatureVerifiers[1];
        hopToken = r.hopToken;
        diemFee = r.diemFee;
        hopFee = r.hopFee;
        diemPool = r.diemPool;
        hopPool = r.hopPool;
        slippageBps = b.slippageBps;
        twapWindow = b.twapWindow;
        longWindow = b.longWindow;
        maxTickDeviation = b.maxTickDeviation;
        maxLongTickDeviation = b.maxLongTickDeviation;
        diemIsToken0 = IEarnedDiemPool(r.diemPool).token0() == address(i.diem);
        hopIsToken0 = r.hopPool != address(0) && IEarnedDiemPool(r.hopPool).token0() == r.hopToken;
        maxReturnFee = b.maxReturnFee;
        minimumReturnUSDC = b.minimumReturnUSDC;
        dollarCodeHash = p.dollar;
        diemCodeHash = p.diem;
        transmitterCodeHash = p.transmitter;
        tokenMessengerCodeHash = p.tokenMessenger;
        routerCodeHash = p.router;
        quoterCodeHash = p.quoter;
    }

    // ----------------------------------------------------------------------------------------------------- views

    /// @notice The agent's canonical Base authority mirror (zero until Ethereum authority is first delivered).
    function authority() public view returns (NoerraAgentMirror) {
        return NoerraAgentMirror(mirrors.accounts(agentId));
    }

    /// @notice The reversed exact-output path: DIEM, fee, [hop, fee,] USDC.
    function exactOutputPath() public view returns (bytes memory) {
        return hopToken == address(0)
            ? abi.encodePacked(address(diem), diemFee, address(dollar))
            : abi.encodePacked(address(diem), diemFee, hopToken, hopFee, address(dollar));
    }

    /// @notice Staked plus cooling DIEM. A pending platform withdrawal still counts until it completes.
    function principal() public view returns (uint256 staked, uint256 cooling, uint256 coolDownEnd) {
        (staked, coolDownEnd, cooling) = diem.stakedInfos(address(this));
    }

    /// @notice True at or above 10 DIEM: the reserve stops buying and the escrow should route brain fees to cash.
    function full() public view returns (bool) {
        (uint256 staked, uint256 cooling,) = principal();
        return staked + cooling >= CAP;
    }

    /// @notice DIEM that may still be bought before the cap (zero while a platform withdrawal is pending).
    function remainingCapacity() external view returns (uint256) {
        (uint256 staked, uint256 cooling,) = principal();
        return cooling > 0 || pendingWithdrawal.operation != bytes32(0) || staked >= CAP ? 0 : CAP - staked;
    }

    // ------------------------------------------------------------------------------------------------- internals

    function _pins() private view {
        require(
            address(dollar).codehash == dollarCodeHash && address(diem).codehash == diemCodeHash
                && address(transmitter).codehash == transmitterCodeHash
                && address(tokenMessenger).codehash == tokenMessengerCodeHash
                && address(router).codehash == routerCodeHash && address(quoter).codehash == quoterCodeHash,
            "Reserve infrastructure changed"
        );
    }

    function _word(bytes calldata data, uint256 at) private pure returns (bytes32) {
        return bytes32(data[at:at + 32]);
    }

    function _addressWord(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _quote(uint256 diemOut) private returns (uint256 amountIn) {
        (amountIn,,,) = quoter.quoteExactOutput(exactOutputPath(), diemOut);
    }

    function _mean(int56 delta, uint32 window) private pure returns (int24 average) {
        int56 w = int56(uint56(window));
        int56 m = delta / w;
        if (delta < 0 && delta % w != 0) m--;
        average = int24(m);
    }

    /// @dev One-sided oracle guard for one pool. "Adverse" is the direction in which the token this hop buys gets more
    /// expensive (tick up when it is token0, down when it is token1). Spot may sit at most maxTickDeviation adverse of
    /// the twapWindow average, and that average at most maxLongTickDeviation adverse of the longWindow average, so a
    /// caller can neither push the price inside its own transaction nor cheaply hold a short pump. Buying below the
    /// averages is always allowed. Returns the twapWindow average tick for the time-weighted price.
    function _poolGuard(address pool, bool outIsToken0) private view returns (int24 shortAverage) {
        (, int24 spot,,,,,) = IEarnedDiemPool(pool).slot0();
        uint32[] memory ago = new uint32[](3);
        ago[0] = longWindow;
        ago[1] = twapWindow;
        (int56[] memory c,) = IEarnedDiemPool(pool).observe(ago);
        shortAverage = _mean(c[2] - c[1], twapWindow);
        int24 longAverage = _mean(c[2] - c[0], longWindow);
        int256 spotAdverse = outIsToken0 ? int256(spot) - shortAverage : int256(shortAverage) - spot;
        int256 averageAdverse =
            outIsToken0 ? int256(shortAverage) - longAverage : int256(longAverage) - shortAverage;
        require(spotAdverse <= int256(uint256(maxTickDeviation)), "Pool price above its average");
        require(averageAdverse <= int256(uint256(maxLongTickDeviation)), "Pool average above its long average");
    }

    /// @dev Input needed for `amountOut` of one hop at a tick, including that pool's fee (exact-output direction).
    function _hopInput(uint256 amountOut, int24 tick, bool outIsToken0, uint24 fee)
        private
        pure
        returns (uint256 amountIn)
    {
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        amountIn = outIsToken0
            ? Math.mulDiv(Math.mulDiv(amountOut, sqrtPrice, Q96), sqrtPrice, Q96)
            : Math.mulDiv(Math.mulDiv(amountOut, Q96, sqrtPrice), Q96, sqrtPrice);
        amountIn = Math.mulDiv(amountIn, 1_000_000, 1_000_000 - fee, Math.Rounding.Ceil);
    }

    /// @dev Guards every pool and returns the USDC that diemOut costs at the 30-minute time-weighted prices (with fees).
    function _twapCost(uint256 diemOut) private view returns (uint256 cost) {
        cost = _hopInput(diemOut, _poolGuard(diemPool, diemIsToken0), diemIsToken0, diemFee);
        if (hopPool != address(0)) cost = _hopInput(cost, _poolGuard(hopPool, hopIsToken0), hopIsToken0, hopFee);
    }

    function _noPendingWithdrawal(uint256 cooling) private view {
        require(cooling == 0 && pendingWithdrawal.operation == bytes32(0), "Platform withdrawal pending");
    }

    // ------------------------------------------------------------------------------------------- permissionless

    /// @notice Relays a finalized-or-fast CCTP V2 burn from Ethereum to this reserve. The reserve is the burn's fixed
    /// destination caller, so only this function can complete it. Anyone may relay; the mint must be exact. Trailing
    /// hookData is ignored, and no infrastructure pin can strand an attested burn (the exact-mint check is the bound).
    function receiveBridge(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
        returns (uint256 net)
    {
        require(
            message.length >= 376 && uint32(bytes4(message[0:4])) == 1
                && uint32(bytes4(message[4:8])) == SOURCE_DOMAIN && uint32(bytes4(message[8:12])) == BASE_DOMAIN,
            "Ethereum to Base CCTP V2"
        );
        require(
            _word(message, 44) == _addressWord(sourceTokenMessenger)
                && _word(message, 76) == _addressWord(address(tokenMessenger))
                && _word(message, 108) == _addressWord(address(this)),
            "Exact CCTP parties"
        );
        require(
            uint32(bytes4(message[148:152])) == 1 && _word(message, 152) == _addressWord(sourceDollar)
                && _word(message, 184) == _addressWord(address(this)),
            "USDC to this reserve"
        );
        uint256 gross = uint256(_word(message, 216));
        uint256 fee = uint256(_word(message, 312));
        require(gross > fee, "Bridge amount");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        require(transmitter.receiveMessage(message, attestation), "CCTP attestation rejected");
        net = gross - fee;
        require(dollar.balanceOf(address(this)) == beforeBalance + net, "Exact attested mint");
        totalReceivedUSDC += net;
        if (pendingSince == 0) pendingSince = block.timestamp;
        emit BridgeReceived(
            _word(message, 12), address(uint160(uint256(_word(message, 248)))), gross, fee, net
        );
    }

    /// @notice Live quote for a buy of exactly diemOut and its cost at the 30-minute time-weighted prices.
    /// @dev Call through eth_call; QuoterV2 is not a view. Reverts like acquire when the oracle guard refuses.
    function quoteAcquire(uint256 diemOut) external returns (uint256 quoted, uint256 twapCost, bool withinImpact) {
        twapCost = _twapCost(diemOut);
        quoted = _quote(diemOut);
        withinImpact = quoted * 10_000 <= twapCost * (10_000 + MAX_IMPACT_BPS);
    }

    /// @notice EIP-712 digest the agent's runtime signer signs for one keeper buy (domain: this reserve on this chain).
    function buyDigest(uint256 diemOut, uint256 maxUsdcIn, uint256 deadline, uint256 nonce) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Noerra brain fund"), keccak256("1"), block.chainid, address(this)));
        return keccak256(abi.encodePacked(
            "\x19\x01", domain, keccak256(abi.encode(BUY_TYPEHASH, diemOut, maxUsdcIn, deadline, nonce))));
    }

    /// @dev The agent's keeper decides every buy: its current mirrored runtime signer calls directly, or signs a
    /// single-use authorization that its Base gas wallet (or anyone) submits. Only after KEEPER_LIVENESS without any
    /// buy may anyone buy, so funds cannot strand; every price guard applies on both paths.
    function _authorizeBuy(uint256 diemOut, uint256 maxUsdcIn, uint256 deadline, bytes calldata authorization)
        private
    {
        uint256 since = pendingSince > lastAcquireAt ? pendingSince : lastAcquireAt;
        if (block.timestamp < since + KEEPER_LIVENESS) {
            NoerraAgentMirror mirror = authority();
            // A frozen or platform-reported (C-4, also after the freeze's lapse) signer is no keeper: its buys wait for the
            // rotation, the platform's unfreeze or the fallback.
            address signer = address(mirror) == address(0) || mirror.frozen() || mirror.reported() ? address(0) : mirror.signer();
            bool ok = signer != address(0) && msg.sender == signer;
            if (!ok && signer != address(0) && authorization.length == 65) {
                (address recovered, ECDSA.RecoverError error,) =
                    ECDSA.tryRecover(buyDigest(diemOut, maxUsdcIn, deadline, buyNonce), authorization);
                ok = error == ECDSA.RecoverError.NoError && recovered == signer;
            }
            require(ok, "Brain fund keeper only");
        }
        ++buyNonce;
        lastAcquireAt = block.timestamp;
        pendingSince = 0;
    }

    /// @notice Buys exactly diemOut DIEM with the reserve's USDC and stakes it, as decided by the agent's keeper.
    /// @param maxUsdcIn the keeper's own bound from its earlier view of the price.
    /// @param authorization the runtime signer's signature over buyDigest(..., buyNonce); empty when it calls itself.
    function acquire(uint256 diemOut, uint256 maxUsdcIn, uint256 deadline, bytes calldata authorization)
        external
        nonReentrant
        returns (uint256 spent)
    {
        require(deadline >= block.timestamp, "Expired buy");
        _authorizeBuy(diemOut, maxUsdcIn, deadline, authorization);
        spent = _buy(diemOut, maxUsdcIn);
    }

    function _buy(uint256 diemOut, uint256 maxUsdcIn) private returns (uint256 spent) {
        _pins();
        (uint256 staked, uint256 cooling,) = principal();
        _noPendingWithdrawal(cooling);
        require(diemOut > 0 && staked + diemOut <= CAP, "Brain fund cap");
        uint256 twapCost = _twapCost(diemOut);
        uint256 quoted = _quote(diemOut);
        require(quoted * 10_000 <= twapCost * (10_000 + MAX_IMPACT_BPS), "Price impact above 1%");
        uint256 limit = quoted + quoted * slippageBps / 10_000;
        if (limit > maxUsdcIn) limit = maxUsdcIn;
        uint256 beforeDollar = dollar.balanceOf(address(this));
        if (limit > beforeDollar) limit = beforeDollar;
        require(quoted > 0 && quoted <= limit, "Live price above bound or funds");
        uint256 beforeDiem = diem.balanceOf(address(this));
        dollar.forceApprove(address(router), limit);
        spent = router.exactOutput(
            IEarnedDiemSwapRouter.ExactOutputParams(exactOutputPath(), address(this), diemOut, limit)
        );
        dollar.forceApprove(address(router), 0);
        require(
            spent > 0 && spent <= limit && dollar.balanceOf(address(this)) + spent == beforeDollar
                && diem.balanceOf(address(this)) == beforeDiem + diemOut,
            "Exact bounded swap"
        );
        diem.stake(diemOut);
        (uint256 afterStaked, uint256 afterCooling,) = principal();
        require(
            afterStaked == staked + diemOut && afterCooling == 0 && diem.balanceOf(address(this)) == beforeDiem,
            "Exact DIEM stake"
        );
        totalSpentUSDC += spent;
        totalAcquiredDiem += diemOut;
        emit Acquired(diemOut, spent, quoted, twapCost, afterStaked);
    }

    /// @notice Stakes every DIEM token deposited directly into the reserve (tokenless agents and donors alike).
    function stakeDeposits() external nonReentrant returns (uint256 amount) {
        _pins();
        (uint256 staked, uint256 cooling,) = principal();
        _noPendingWithdrawal(cooling);
        amount = diem.balanceOf(address(this));
        require(amount > 0, "No DIEM deposit");
        diem.stake(amount);
        (uint256 afterStaked, uint256 afterCooling,) = principal();
        require(
            afterStaked == staked + amount && afterCooling == 0 && diem.balanceOf(address(this)) == 0,
            "Exact DIEM stake"
        );
        totalDepositedDiem += amount;
        emit DepositStaked(amount, afterStaked);
    }

    /// @notice USDC that may go back to the agent's own Ethereum account now (none while a platform withdrawal is pending,
    /// since the fund then needs it): all of it at the cap or once no buy happened for IDLE_EXIT since funds arrived, else
    /// what exceeds 1.25 x the time-weighted cost of the remaining capacity (reverts while the oracle guard refuses).
    function returnable() public view returns (uint256 amount) {
        (uint256 staked, uint256 cooling,) = principal();
        if (cooling > 0 || pendingWithdrawal.operation != bytes32(0)) return 0;
        amount = dollar.balanceOf(address(this));
        uint256 since = pendingSince > lastAcquireAt ? pendingSince : lastAcquireAt;
        if (staked >= CAP || block.timestamp >= since + IDLE_EXIT) return amount;
        uint256 keep = _twapCost(CAP - staked) * KEEP_PERCENT / 100;
        amount = amount > keep ? amount - keep : 0;
    }

    /// @notice Largest CCTP fee a return of `amount` may carry: the fixed bound, or 0.1% of the amount when larger.
    function returnFeeBound(uint256 amount) public view returns (uint256) {
        uint256 proportional = amount * PROPORTIONAL_FEE_BPS / 10_000;
        return proportional > maxReturnFee ? proportional : maxReturnFee;
    }

    /// @notice Returns everything returnable() to the agent's own Ethereum account (all of it at the cap).
    function returnExcess(uint256 maxFee) external nonReentrant returns (uint256 amount) {
        amount = _return(returnable(), maxFee);
    }

    /// @notice Returns `amount` (at most returnable()) to the agent's own Ethereum account over CCTP V2. Anyone may call;
    /// the recipient comes from the agent's canonical mirror and the destination caller is open so anyone can relay the
    /// mint on Ethereum. Partial amounts let a proportional CCTP fee or a burn limit never freeze a large balance.
    function returnExcess(uint256 amount, uint256 maxFee) external nonReentrant returns (uint256) {
        require(amount <= returnable(), "Above the returnable USDC");
        return _return(amount, maxFee);
    }

    function _return(uint256 amount, uint256 maxFee) private returns (uint256) {
        _pins();
        (, uint256 cooling,) = principal();
        _noPendingWithdrawal(cooling); // after a withdrawal completes the fund is below the cap and needs this USDC
        NoerraAgentMirror mirror = authority();
        require(address(mirror) != address(0), "Agent authority not mirrored");
        address account = mirror.sourceAccount();
        require(account != address(0), "Agent account");
        require(amount >= minimumReturnUSDC && maxFee <= returnFeeBound(amount) && maxFee < amount, "Bounded return");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
            amount, SOURCE_DOMAIN, _addressWord(account), address(dollar), bytes32(0), maxFee, STANDARD_FINALITY
        );
        dollar.forceApprove(address(tokenMessenger), 0);
        require(dollar.balanceOf(address(this)) + amount == beforeBalance, "Exact return debit");
        if (beforeBalance == amount) pendingSince = 0; // nothing unspent is left: the next arrival starts a fresh window
        totalReturnedUSDC += amount;
        emit ExcessReturned(account, amount, maxFee);
        return amount;
    }

    // ------------------------------------------------------------------------------------------ platform withdrawal

    /// @notice The platform may withdraw staked DIEM from any agent's reserve, unconditionally. The unstake starts now;
    /// the DIEM can be taken exactly 7 days later (or when Venice's own cooldown ends, if that is later).
    function requestPlatformWithdrawal(bytes32 operation, uint256 amount) external nonReentrant {
        require(msg.sender == platform, "Platform only");
        require(operation != bytes32(0) && !operations[operation], "Unused operation");
        (uint256 staked, uint256 cooling,) = principal();
        _noPendingWithdrawal(cooling);
        require(amount > 0 && amount <= staked, "Staked DIEM only");
        operations[operation] = true;
        diem.initiateUnstake(amount);
        (uint256 nextStaked, uint256 nextCooling, uint256 end) = principal();
        require(nextStaked + amount == staked && nextCooling == amount && end > block.timestamp, "Exact DIEM cooldown");
        uint256 availableAt = block.timestamp + PLATFORM_WITHDRAWAL_DELAY;
        pendingWithdrawal = PlatformWithdrawal(operation, amount, uint64(block.timestamp), uint64(availableAt));
        emit PlatformWithdrawalRequested(operation, amount, availableAt, end);
    }

    /// @notice After the 7-day wait anyone may complete; the DIEM has exactly one destination, the fixed platform.
    function completePlatformWithdrawal(bytes32 operation) external nonReentrant returns (uint256 amount) {
        PlatformWithdrawal memory pending = pendingWithdrawal;
        require(operation != bytes32(0) && pending.operation == operation, "Pending operation");
        (uint256 staked, uint256 cooling, uint256 end) = principal();
        require(
            block.timestamp >= pending.availableAt && block.timestamp >= end && cooling == pending.amount,
            "Seven day wait"
        );
        amount = pending.amount;
        uint256 beforeBalance = diem.balanceOf(address(this));
        diem.unstake();
        (uint256 afterStaked, uint256 afterCooling,) = principal();
        require(
            afterStaked == staked && afterCooling == 0 && diem.balanceOf(address(this)) == beforeBalance + amount,
            "Exact unstaked DIEM"
        );
        delete pendingWithdrawal;
        lastAcquireAt = block.timestamp; // the fund just dropped below the cap: the keeper gets its full window first
        IERC20(address(diem)).safeTransfer(platform, amount);
        require(diem.balanceOf(address(this)) == beforeBalance, "Exact platform debit");
        totalWithdrawnDiem += amount;
        emit PlatformWithdrawalCompleted(operation, platform, amount);
    }

    // ---------------------------------------------------------------------------------------------- ERC-1271

    /// @notice Who may ask this wallet to validate a signature. Tokens (Base USDC accepts ERC-1271 signatures for
    /// EIP-3009 transferWithAuthorization and EIP-2612 permit), Permit2, the router, bridge and pools would act on a
    /// "valid" answer by moving this reserve's funds, so they are always refused, and so is every other contract except
    /// a reviewed verifier. Off-chain verifiers such as Venice SIGN-IN-WITH-X call through eth_call from an EOA or the
    /// zero address, or through a deployless ERC-6492 validator (its constructor has no code yet); both have no code.
    function signatureCallerAllowed(address caller) public view returns (bool) {
        if (
            caller == address(dollar) || caller == address(diem) || (hopToken != address(0) && caller == hopToken)
                || caller == PERMIT2 || caller == address(router) || caller == address(quoter)
                || caller == address(tokenMessenger) || caller == address(transmitter) || caller == diemPool
                || (hopPool != address(0) && caller == hopPool) || caller == factory || caller == address(this)
        ) return false;
        return caller.code.length == 0 || (caller != address(0) && (caller == verifierA || caller == verifierB));
    }

    /// @notice Venice SIGN-IN-WITH-X for this reserve wallet: valid for the agent's current mirrored runtime signer,
    /// and only for an allowed caller (never an asset, router or bridge contract), so it cannot authorize a transfer.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (!signatureCallerAllowed(msg.sender)) return bytes4(0xffffffff);
        NoerraAgentMirror mirror = authority();
        if (address(mirror) == address(0) || mirror.frozen() || mirror.reported()) return bytes4(0xffffffff);
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(hash, signature);
        return error == ECDSA.RecoverError.NoError && recovered != address(0) && recovered == mirror.signer()
            ? bytes4(0x1626ba7e)
            : bytes4(0xffffffff);
    }
}
