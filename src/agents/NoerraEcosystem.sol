// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {NoerraQuoter} from "./NoerraQuoter.sol";
import {NoerraNoerFeeHook} from "./NoerraUsdcFeeHook.sol";
import {NoerraRevenueCoin} from "../personal/NoerraRevenueCoin.sol";
interface INoerraPlatformEthUsdFeed {
    function decimals() external view returns(uint8);
    function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);
}

interface INoerraFlagshipRegistry {
    function dollar() external view returns (address);
    function accounts(bytes32 id) external view returns (address);
    function tokens(bytes32 id) external view returns (address);
    function creationBlocks(bytes32 id) external view returns (uint256);
}
interface INoerraFlagshipAccount {
    function registry() external view returns (address);
    function dollar() external view returns (address);
    function agentId() external view returns (bytes32);
    function human() external view returns (address);
    function signer() external view returns (address);
    function generation() external view returns (uint256);
    function buildHash() external view returns (bytes32);
    function dailyLimit() external view returns (uint256);
    function lockAutonomousCore() external;
    function autonomousCoreLocked() external view returns (bool);
}

/// @notice Funded ecosystem revenue is paid 50% to the protocol, 10% to the flagship,
/// and the remainder to a separate user-controlled buyback wallet. Purchases are manual.
abstract contract NoerraEcosystemVaultBase is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable dollar;
    IERC20 public immutable noer;
    IPoolManager public immutable manager;
    NoerraQuoter public immutable quoter;
    bytes32 public immutable quoterCodeHash;
    address public immutable deployer;
    address public immutable launchExecutor;
    bytes32 public immutable launchCommitment;
    address public immutable operationsTreasury;
    address public immutable agentTreasury;
    address public immutable buybackTreasury;
    uint256 public constant OPERATIONS_BPS = 6000;
    uint256 public constant PROTOCOL_BPS = 5000;
    uint256 public constant AGENT_BPS = 1000;
    uint256 public constant BUYBACK_BPS = 4000;
    NoerraNoerMarket public market;
    bytes32 public marketCodeHash;
    uint256 public totalRevenue;
    uint256 public totalOperations;
    uint256 public totalAgentFunding;
    uint256 public totalBuybackFunding;
    address public agentRegistry;
    bytes32 public agentId;
    address public agentAccount;
    bytes32 public agentBuildHash;
    uint256 public agentBoundBlock;
    event MarketBound(address indexed market, bytes32 codeHash);
    event AgentBound(bytes32 indexed agentId, address indexed account, address indexed registry, bytes32 buildHash);
    event Revenue(address indexed source, uint256 amount, uint256 operations, uint256 agent, uint256 buybacks);

    constructor(IERC20 dollar_, IERC20 noer_, IPoolManager manager_, NoerraQuoter quoter_,
        address operations_, address agentTreasury_, address buybackTreasury_, address owner_, address executor_, bytes32 commitment_) {
        require(block.chainid == 1 && address(dollar_).code.length > 0 && address(noer_).code.length > 0
            && address(dollar_) != address(noer_) && address(manager_).code.length > 0, "Ethereum assets");
        require(address(quoter_).code.length > 0 && address(quoter_.poolManager()) == address(manager_), "Pinned quoter");
        require(operations_ != address(0) && operations_ != address(this) && buybackTreasury_ != address(0)
            && buybackTreasury_ != address(this), "Revenue authority");
        require(agentTreasury_ != address(0) && agentTreasury_ != address(this) && agentTreasury_ != operations_
            && agentTreasury_ != buybackTreasury_ && operations_ != buybackTreasury_, "Separate revenue authorities");
        dollar = dollar_; noer = noer_; manager = manager_; quoter = quoter_;
        require(owner_ != address(0) && ((executor_ == address(0) && owner_ == msg.sender && commitment_ == bytes32(0))
            || (executor_ == msg.sender && commitment_ != bytes32(0))), "Bootstrap authority");
        quoterCodeHash = address(quoter_).codehash; deployer = owner_; launchExecutor = executor_; launchCommitment = commitment_;
        operationsTreasury = operations_; agentTreasury = agentTreasury_; buybackTreasury = buybackTreasury_;
    }

    function bindMarket(NoerraNoerMarket market_) external {
        require(msg.sender == (launchExecutor == address(0) ? deployer : launchExecutor) && address(market) == address(0) && totalRevenue == 0,
            "One unfunded market binding");
        require(address(market_).code.length > 0 && address(market_.manager()) == address(manager)
            && address(market_.dollar()) == address(dollar) && address(market_.token()) == address(noer)
            && address(market_.ecosystem()) == address(this) && market_.FEE() == 0
            && market_.SWAP_FEE_BPS() == 175 && address(market_.feeHook().manager()) == address(manager)
            && market_.feeHook().locker() == address(market_), "Direct permanent NOERRA market");
        market = market_; marketCodeHash = address(market_).codehash;
        emit MarketBound(address(market_), marketCodeHash);
    }

    /// @notice Associate this existing platform token with its dedicated operating account, once.
    /// Permissionless revenue received earlier cannot change or block the committed recipient.
    function bindAgent(INoerraFlagshipRegistry registry_, bytes32 id) external {
        require(msg.sender == (launchExecutor == address(0) ? deployer : launchExecutor) && agentAccount == address(0) && address(market) != address(0),
            "One platform agent binding");
        require(address(registry_).code.length > 0 && registry_.dollar() == address(dollar)
            && registry_.tokens(id) == address(0) && registry_.creationBlocks(id) > 0, "Tokenless registry account");
        address account = registry_.accounts(id);
        require(account == agentTreasury && account != operationsTreasury && account != buybackTreasury && account.code.length > 0, "Flagship account");
        INoerraFlagshipAccount source = INoerraFlagshipAccount(account);
        bytes32 build = source.buildHash();
        require(source.registry() == address(registry_) && source.dollar() == address(dollar)
            && source.agentId() == id && source.human() == deployer && source.signer() == deployer
            && source.generation() == 1 && build != bytes32(0) && source.dailyLimit() > 0,
            "Original platform authority");
        agentRegistry = address(registry_); agentId = id; agentAccount = account;
        agentBuildHash = build; agentBoundBlock = block.number;
        source.lockAutonomousCore();
        emit AgentBound(id, account, address(registry_), build);
    }

    /// @notice Donations and collected fees use the same exact funded allocation.
    function autonomousFlagshipReady() external view returns (bool) {
        return agentAccount != address(0) && agentAccount == agentTreasury &&
            INoerraFlagshipAccount(agentAccount).autonomousCoreLocked();
    }

    /// @notice Donations and collected fees use the same exact funded allocation.
    function receiveRevenue(uint256 amount) external nonReentrant {
        require(address(market) != address(0) && amount > 0, "Bound funded revenue");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        require(dollar.balanceOf(address(this)) == beforeBalance + amount, "Exact revenue funding");
        uint256 operations = Math.mulDiv(amount, PROTOCOL_BPS, 10000);
        uint256 agent = Math.mulDiv(amount, AGENT_BPS, 10000);
        uint256 buybacks = amount - operations - agent;
        totalRevenue += amount; totalOperations += operations; totalAgentFunding += agent; totalBuybackFunding += buybacks;
        if (operations > 0) dollar.safeTransfer(operationsTreasury, operations);
        if (agent > 0) dollar.safeTransfer(agentTreasury, agent);
        if (buybacks > 0) dollar.safeTransfer(buybackTreasury, buybacks);
        require(dollar.balanceOf(address(this)) == beforeBalance, "Exact funded distribution");
        emit Revenue(msg.sender, amount, operations, agent, buybacks);
    }
}

/// @notice Legacy EOA deployment remains unchanged.
contract NoerraEcosystemVault is NoerraEcosystemVaultBase {
    constructor(IERC20 dollar_, IERC20 noer_, IPoolManager manager_, NoerraQuoter quoter_,
        address operations_, address agentTreasury_, address buybackTreasury_)
        NoerraEcosystemVaultBase(dollar_,noer_,manager_,quoter_,operations_,agentTreasury_,buybackTreasury_,msg.sender,address(0),bytes32(0)) {}
}
/// @notice Separate immutable bootstrap executor never owns the account or revenue recipients.
contract NoerraAtomicEcosystemVault is NoerraEcosystemVaultBase {
    constructor(IERC20 dollar_, IERC20 noer_, IPoolManager manager_, NoerraQuoter quoter_,
        address operations_, address agentTreasury_, address buybackTreasury_, address owner_, bytes32 commitment_)
        NoerraEcosystemVaultBase(dollar_,noer_,manager_,quoter_,operations_,agentTreasury_,buybackTreasury_,owner_,msg.sender,commitment_) {}
}

/// @notice Direct Ethereum USDC/NOERRA liquidity held forever; all collected dollars fund the ecosystem.
/// A separate hook collects USDC fees and prevents third-party pool initialization.
contract NoerraNoerMarket is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    IPoolManager public immutable manager;
    IERC20 public immutable dollar;
    IERC20 public immutable token;
    NoerraEcosystemVaultBase public immutable ecosystem;
    NoerraNoerFeeHook public immutable feeHook;
    address public immutable deployer;
    address public immutable launchExecutor;
    uint24 public constant FEE = 0;
    uint256 public constant SWAP_FEE_BPS = 175;
    uint256 public constant LAUNCH_SWAP_FEE_BPS = 2500;
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 887220;
    PoolKey public pool;
    uint128 public lockedLiquidity;
    uint256 public launchBlock;
    int24 public tickLower;
    int24 public tickUpper;
    INoerraPlatformEthUsdFeed public immutable ethUsdFeed;
    uint32 public immutable oracleMaximumAge;
    uint256 public constant LAUNCH_FDV_ETH = 1 ether;
    uint256 public initialValuation;
    address public immutable protectionQuoter;
    uint256 public constant feeTokens = 0;
    bytes32 private callbackCommitment;
    event Launched(uint256 tokens, uint256 dollars, uint160 price, uint128 liquidity);
    event LaunchValuation(uint256 dollars, int24 lower, int24 upper);
    event Trade(address indexed trader, bool buy, uint256 amountIn, uint256 amountOut);
    event Fees(uint256 dollars, uint256 tokens);
    struct LaunchBuy {address buyer; uint256 amountIn; uint256 minimumOut; uint256 maximumOut;}
    event AtomicLaunch(uint256 wallets, uint256 dollars, uint256 tokens);

    constructor(IPoolManager manager_, IERC20 dollar_, IERC20 token_, NoerraEcosystemVaultBase ecosystem_, NoerraNoerFeeHook feeHook_, INoerraPlatformEthUsdFeed feed_, uint32 maximumAge_) {
        require(block.chainid == 1 && address(manager_).code.length > 0 && address(dollar_).code.length > 0
            && address(token_).code.length > 0 && address(dollar_) != address(token_), "Ethereum market assets");
        require(address(ecosystem_).code.length > 0 && address(ecosystem_.manager()) == address(manager_)
            && address(ecosystem_.dollar()) == address(dollar_) && address(ecosystem_.noer()) == address(token_), "Ecosystem wiring");
        require(address(feeHook_.manager()) == address(manager_) && feeHook_.dollar() == address(dollar_)
            && feeHook_.token() == address(token_), "External USDC fee hook");
        manager = manager_; dollar = dollar_; token = token_; ecosystem = ecosystem_; deployer = ecosystem_.deployer(); launchExecutor = ecosystem_.launchExecutor();
        feeHook = feeHook_;
        require(address(feed_).code.length > 0 && feed_.decimals() == 8 && maximumAge_ >= 60 && maximumAge_ <= 2 hours, "ETH USD oracle");
        ethUsdFeed = feed_; oracleMaximumAge = maximumAge_; protectionQuoter = address(ecosystem_.quoter());
        bool first = address(token_) < address(dollar_);
        pool = PoolKey(Currency.wrap(first ? address(token_) : address(dollar_)),
            Currency.wrap(first ? address(dollar_) : address(token_)), FEE, 60, IHooks(address(feeHook_)));
    }

    function initialPoolNotional() public view returns(uint256 value) {
        (uint80 round,int256 answer,uint256 started,uint256 updated,uint80 answered) = ethUsdFeed.latestRoundData();
        require(round != 0 && answer > 0 && answered >= round && started != 0 && started <= updated,"Oracle round");
        require(updated != 0 && updated <= block.timestamp && block.timestamp - updated <= oracleMaximumAge,"Oracle freshness");
        value = uint256(answer) / 100; require(value > 0 && value <= 1_000_000e6,"Oracle price bounds");
    }
    /// @notice Full token-only permanent liquidity at an oracle-valued one ETH spot target.
    function initialize(uint256 tokenSeed) external nonReentrant {
        require(launchExecutor == address(0), "Atomic launch only");
        _initialize(tokenSeed);
    }
    /// @notice Activate the pool and execute all reviewed bounded purchases in ONE
    /// transaction. Any failure rolls back pool initialization and every purchase.
    /// Wallets approve their exact USDC input beforehand; tokens go directly to
    /// each wallet and the existing two-percent launch cap remains in force.
    function initializeWithBuys(uint256 tokenSeed, LaunchBuy[] calldata buys, uint256 deadline)
        external nonReentrant returns(uint256[] memory outputs)
    {
        require(launchExecutor == address(0) || (buys.length == 24 && keccak256(abi.encode(buys)) == ecosystem.launchCommitment()), "Committed launch roster");
        require(buys.length >= 15 && buys.length <= 30, "Launch wallet count");
        require(block.timestamp <= deadline && deadline <= block.timestamp + 5 minutes, "Fresh deadline");
        for(uint256 i; i < buys.length; ++i) {
            LaunchBuy calldata b = buys[i];
            require(b.buyer != address(0) && b.buyer != address(this) && b.buyer != address(manager)
                && b.minimumOut >= 18_000_000 ether && b.maximumOut <= 19_900_000 ether
                && b.maximumOut >= b.minimumOut, "Launch allocation bounds");
            for(uint256 j; j < i; ++j) require(buys[j].buyer != b.buyer, "Distinct launch wallets");
        }
        _initialize(tokenSeed);
        outputs=new uint256[](buys.length);
        uint256 totalDollars; uint256 totalTokens;
        for(uint256 i; i < buys.length; ++i) {
            LaunchBuy calldata b = buys[i];
            uint256 received = _trade(true,b.amountIn,b.minimumOut,deadline,b.buyer);
            require(received <= b.maximumOut, "Launch maximum output");
            outputs[i]=received;
            totalDollars += b.amountIn; totalTokens += received;
        }
        emit AtomicLaunch(buys.length,totalDollars,totalTokens);
    }
    function _initialize(uint256 tokenSeed) private {
        require(msg.sender == (launchExecutor == address(0) ? deployer : launchExecutor) && lockedLiquidity == 0 && address(ecosystem.market()) == address(this), "One bound launch");
        require(ecosystem.autonomousFlagshipReady(), "Autonomous flagship binding");
        require(tokenSeed == 1_000_000_000 ether && tokenSeed == token.totalSupply()
            && token.balanceOf(address(this)) == tokenSeed, "Exact seed bounds");
        uint256 dollarValue = initialPoolNotional(); initialValuation = dollarValue;
        bool first = Currency.unwrap(pool.currency0) == address(token);
        uint256 root = Math.sqrt(Math.mulDiv(first ? dollarValue : tokenSeed, 1 << 192, first ? tokenSeed : dollarValue));
        require(root > TickMath.MIN_SQRT_PRICE && root < TickMath.MAX_SQRT_PRICE, "Seed price bounds");
        uint160 price = uint160(root);
        int24 tick = TickMath.getTickAtSqrtPrice(price); int24 boundary = tick / 60 * 60;
        if(tick < 0 && tick % 60 != 0) boundary -= 60;
        if(first && price > TickMath.getSqrtPriceAtTick(boundary)) boundary += 60;
        require(boundary > LOWER && boundary < UPPER,"Initial price bounds");
        tickLower = first ? boundary : LOWER; tickUpper = first ? UPPER : boundary;
        lockedLiquidity = LiquidityAmounts.getLiquidityForAmounts(price, TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper), first ? tokenSeed : 0, first ? 0 : tokenSeed);
        NoerraRevenueCoin(address(token)).beginLaunchProtection();
        require(lockedLiquidity > 0, "Liquidity"); manager.initialize(pool, price);
        _unlock(abi.encode(uint8(0), false, uint256(0), address(this)));
        launchBlock = block.number;
        emit Launched(tokenSeed, 0, price, lockedLiquidity);
        emit LaunchValuation(dollarValue,tickLower,tickUpper);
    }

    function poolKey() external view returns (PoolKey memory) { return pool; }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        callbackCommitment = keccak256(data); result = manager.unlock(data);
        require(callbackCommitment == bytes32(0), "Callback missing");
    }
    function _resolve(Currency currency, int128 delta, address recipient) private {
        if (delta < 0) {
            manager.sync(currency); IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(delta))); manager.settle();
        } else if (delta > 0) manager.take(currency, recipient, uint256(uint128(delta)));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && callbackCommitment != bytes32(0)
            && callbackCommitment == keccak256(data), "Manager callback");
        callbackCommitment = bytes32(0);
        (uint8 kind, bool buy, uint256 amount, address recipient) = abi.decode(data, (uint8,bool,uint256,address));
        BalanceDelta delta;
        if (kind < 2) {
            if (kind == 0) (delta,) = manager.modifyLiquidity(pool, ModifyLiquidityParams(tickLower, tickUpper,
                int256(uint256(lockedLiquidity)), bytes32(0)), "");
            else feeHook.withdrawFees(pool);
        } else {
            bool zeroForOne = buy ? Currency.unwrap(pool.currency0) == address(dollar) : Currency.unwrap(pool.currency0) == address(token);
            delta = manager.swap(pool, SwapParams(zeroForOne, -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
            int128 input = zeroForOne ? delta.amount0() : delta.amount1();
            require(input < 0 && uint256(-int256(input)) == amount, "Full input required");
        }
        _resolve(pool.currency0, delta.amount0(), recipient); _resolve(pool.currency1, delta.amount1(), recipient);
        return abi.encode(delta);
    }
    function trade(bool buy, uint256 amountIn, uint256 minimumOut, uint256 deadline)
        external nonReentrant returns (uint256 amountOut) {
        return _trade(buy,amountIn,minimumOut,deadline,msg.sender);
    }
    function _trade(bool buy, uint256 amountIn, uint256 minimumOut, uint256 deadline, address trader)
        private returns (uint256 amountOut) {
        require(lockedLiquidity > 0 && amountIn > 0 && amountIn <= uint256(uint128(type(int128).max)) && minimumOut > 0, "Trade bounds");
        require(block.timestamp <= deadline && deadline <= block.timestamp + 5 minutes, "Fresh deadline");
        IERC20 input = buy ? dollar : token; IERC20 output = buy ? token : dollar;
        input.safeTransferFrom(trader, address(this), amountIn);
        uint256 beforeBalance = output.balanceOf(trader);
        _unlock(abi.encode(uint8(2), buy, amountIn, trader));
        amountOut = output.balanceOf(trader) - beforeBalance; require(amountOut >= minimumOut, "Slippage");
        emit Trade(trader, buy, amountIn, amountOut);
    }
    function collect() external nonReentrant returns (uint256 dollars, uint256 tokens) {
        require(lockedLiquidity > 0, "Not launched");
        uint256 beforeDollar = dollar.balanceOf(address(this)); uint256 beforeToken = token.balanceOf(address(this));
        _unlock(abi.encode(uint8(1), false, uint256(0), address(this)));
        dollars = dollar.balanceOf(address(this)) - beforeDollar; tokens = token.balanceOf(address(this)) - beforeToken;
        require(tokens == 0, "USDC fees only"); if (dollars > 0) _distribute(dollars); emit Fees(dollars, 0);
    }
    /// @notice Retained ABI fails explicitly: this market never accrues token-denominated trading fees.
    function convertFees(uint256, uint256, uint256) external pure returns (uint256) {
        revert("USDC fees only");
    }
    function _distribute(uint256 amount) private {
        dollar.forceApprove(address(ecosystem), amount); ecosystem.receiveRevenue(amount);
        dollar.forceApprove(address(ecosystem), 0);
    }
}

/// @dev Non-executable immutable bytecode container avoids embedding both creation
/// codes in the builder's runtime, which would exceed EIP-170. The STOP prefix
/// prevents calls from executing the stored constructor code.
contract NoerraNoerHookCreationCode {
    constructor() {
        bytes memory code = abi.encodePacked(hex"00",type(NoerraNoerFeeHook).creationCode);
        assembly ("memory-safe") { return(add(code,32),mload(code)) }
    }
}

/// @dev Reviewed CREATE2 builder; only its immutable deployment owner may create a market.
contract NoerraNoerMarketDeployer {
    address public immutable owner;
    address public immutable hookCreationCode;
    constructor() { owner = msg.sender; hookCreationCode = address(new NoerraNoerHookCreationCode()); }
    function deploy(IPoolManager manager, IERC20 dollar, IERC20 noer, NoerraEcosystemVault ecosystem, bytes32 salt, INoerraPlatformEthUsdFeed feed, uint32 maximumAge)
        external returns (NoerraNoerMarket result) {
        require(msg.sender == owner && ecosystem.deployer() == owner, "Deployment owner only");
        address container = hookCreationCode;uint256 length = container.code.length - 1;
        bytes memory creation = new bytes(length);
        assembly ("memory-safe") { extcodecopy(container,add(creation,32),1,length) }
        bytes memory initcode = abi.encodePacked(creation,abi.encode(manager,address(dollar),address(noer),address(this)));
        address hookAddress;
        assembly ("memory-safe") { hookAddress := create2(0,add(initcode,32),mload(initcode),salt) }
        require(hookAddress != address(0),"Hook deployment");
        NoerraNoerFeeHook hook = NoerraNoerFeeHook(hookAddress);
        result = new NoerraNoerMarket{salt:salt}(manager, dollar, noer, ecosystem, hook,feed,maximumAge);
        hook.register(address(result));
    }
}
