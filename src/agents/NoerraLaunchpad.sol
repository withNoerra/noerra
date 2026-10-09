// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraCreationToken, NoerraAgentCredits} from "./NoerraAgents.sol";

/// @notice Permanently locked backing receipts. They cannot be sold, sent or redeemed for the creation token.
///         Rewards are funded ERC-20 balances, never promised yield or principal withdrawals.
contract NoerraBackers is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    IERC20 public immutable credits;
    address public immutable locker;
    uint256 public accumulator;
    uint256 public reserved;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public earned;
    event Backed(address indexed backer, uint256 amount);
    event Rewarded(uint256 amount);
    event Claimed(address indexed backer, uint256 amount);

    constructor(IERC20 token_, IERC20 credits_, address locker_)
        ERC20("Noerra Backer", "xAGENT") { token = token_; credits = credits_; locker = locker_; }

    function _update(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "Soulbound");
        super._update(from, to, amount);
    }

    function _settle(address user) private {
        uint256 accrued = Math.mulDiv(balanceOf(user), accumulator, 1e27);
        earned[user] += accrued - debt[user]; debt[user] = accrued;
    }

    function back(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount"); _settle(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        debt[msg.sender] = Math.mulDiv(balanceOf(msg.sender), accumulator, 1e27);
        emit Backed(msg.sender, amount);
    }

    function distribute(uint256 amount) external {
        require(msg.sender == locker && totalSupply() > 0, "Locker and backers required");
        require(credits.balanceOf(address(this)) >= reserved + amount, "Actual credit backing");
        accumulator += Math.mulDiv(amount, 1e27, totalSupply()); reserved += amount;
        emit Rewarded(amount);
    }

    function pending(address user) external view returns (uint256) {
        return earned[user] + Math.mulDiv(balanceOf(user), accumulator, 1e27) - debt[user];
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender); amount = earned[msg.sender]; require(amount > 0, "No rewards");
        earned[msg.sender] = 0; reserved -= amount;
        IERC20(address(credits)).safeTransfer(msg.sender, amount); emit Claimed(msg.sender, amount);
    }
}

/// @notice Owns a direct v4 position forever. No negative liquidity operation or sweep exists.
///         A zero-liquidity modification collects earned fees without removing the position.
contract NoerraLockedCreation is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    IHooks public launchProtectionHook;
    NoerraAgentAccount public immutable agent;
    NoerraAgentCredits public immutable credits;
    IERC20 public immutable dollar;
    address public immutable factory;
    address public immutable creator;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    IERC20 public token;
    NoerraBackers public backers;
    PoolKey public pool;
    uint128 public lockedLiquidity;
    int24 public lower;
    int24 public upper;
    uint256 public feeTokens;
    bytes32 private callbackCommitment;
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 887220;
    function FEE() public pure virtual returns (uint24) {return 10000;} // Retained legacy pool fee.
    event Launched(address indexed token, address indexed backers, uint128 liquidity, uint256 seed);
    event Fees(uint256 dollars, uint256 tokenAmount);
    event Trade(address indexed trader, bool buy, uint256 amountIn, uint256 amountOut);
    event FeeConversion(uint256 tokens, uint256 dollars);

    constructor(IPoolManager manager_, NoerraAgentAccount agent_, NoerraAgentCredits credits_, IERC20 quote_,
        address protocol_, address noer_, address factory_) {
        manager = manager_; agent = agent_; credits = credits_; dollar = quote_;
        require(factory_ != address(0), "Factory");
        factory = factory_; creator = agent_.human(); protocolTreasury = protocol_; noerTreasury = noer_;
    }

    function initialize(IERC20 token_, NoerraBackers backers_, uint256 seed) external nonReentrant {
        _initialize(token_, backers_, seed, 1_000_000_000 ether);
    }

    /// @notice Dual launches put exactly half the fixed supply in each permanent market.
    function initializeHalf(IERC20 token_, NoerraBackers backers_, uint256 seed) external nonReentrant {
        _initialize(token_, backers_, seed, 500_000_000 ether);
    }

    function _initialize(IERC20 token_, NoerraBackers backers_, uint256 seed, uint256 supply) private {
        require(msg.sender == factory && address(token) == address(0), "One launch");
        require(_validSeed(seed) && dollar.balanceOf(address(this)) == seed, "Seed bounds");
        require(token_.balanceOf(address(this)) == supply, "Entire supply");
        token = token_; backers = backers_; lower = LOWER; upper = UPPER;
        bool tokenFirst = address(token_) < address(dollar);
        pool = PoolKey(Currency.wrap(tokenFirst ? address(token_) : address(dollar)),
            Currency.wrap(tokenFirst ? address(dollar) : address(token_)), FEE(), 60, IHooks(address(0)));
        uint256 amount0 = tokenFirst ? token_.balanceOf(address(this)) : seed;
        uint256 amount1 = tokenFirst ? seed : token_.balanceOf(address(this));
        uint160 price = uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
        lockedLiquidity = LiquidityAmounts.getLiquidityForAmounts(price, TickMath.getSqrtPriceAtTick(LOWER),
            TickMath.getSqrtPriceAtTick(UPPER), amount0, amount1);
        require(lockedLiquidity > 0, "Liquidity");
        manager.initialize(pool, price);
        _unlock(abi.encode(uint8(0), false, uint256(0), address(this)));
        emit Launched(address(token_), address(backers_), lockedLiquidity, seed);
    }

    function setLaunchProtectionHook(IHooks hook) external {
        require(msg.sender == factory && address(token) == address(0)
            && address(launchProtectionHook) == address(0) && address(hook).code.length > 0, "Fixed launch hook");
        launchProtectionHook = hook;
    }

    /// @notice Starts asleep with tokens only. The immutable range cannot be withdrawn or changed.
    /// The quote treasury starts empty; buys must supply the first quote assets.
    function initializeSleeping(IERC20 token_, NoerraBackers backers_, uint256 supply,
        uint160 price, int24 lower_, int24 upper_) external virtual nonReentrant {
        require(supply == 1_000_000_000 ether && token_.totalSupply() == supply
            && token_.balanceOf(address(this)) == supply, "Full Ethereum supply");
        _initializeSleeping(token_, backers_, supply, price, lower_, upper_);
    }

    function _initializeSleeping(IERC20 token_, NoerraBackers backers_, uint256 supply,
        uint160 price, int24 lower_, int24 upper_) internal {
        require(msg.sender == factory && address(token) == address(0), "One launch");
        // Unsolicited quote dust at a predicted locker cannot block its token-only launch.
        // It is not deposited into the position or counted as collected fees.
        require(lower_ >= LOWER && upper_ <= UPPER && lower_ < upper_ && lower_ % 60 == 0 && upper_ % 60 == 0, "Sleeping range");
        bool first = address(token_) < address(dollar);
        uint160 low = TickMath.getSqrtPriceAtTick(lower_); uint160 high = TickMath.getSqrtPriceAtTick(upper_);
        require(first ? price <= low : price >= high, "One-sided token price");
        token = token_; backers = backers_; lower = lower_; upper = upper_;
        pool = PoolKey(Currency.wrap(first ? address(token_) : address(dollar)),
            Currency.wrap(first ? address(dollar) : address(token_)), FEE(), 60, launchProtectionHook);
        lockedLiquidity = LiquidityAmounts.getLiquidityForAmounts(price, low, high, first ? supply : 0, first ? 0 : supply);
        require(lockedLiquidity > 0, "Liquidity");manager.initialize(pool, price);
        _unlock(abi.encode(uint8(0), false, uint256(0), address(this)));
        emit Launched(address(token_), address(backers_), lockedLiquidity, 0);
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        callbackCommitment = keccak256(data); result = manager.unlock(data);
        require(callbackCommitment == bytes32(0), "Callback missing");
    }

    function _resolve(Currency currency, int128 delta, address recipient) private {
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) manager.take(currency, recipient, uint256(uint128(delta)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && callbackCommitment != bytes32(0) && callbackCommitment == keccak256(data), "Manager callback");
        callbackCommitment = bytes32(0);
        (uint8 kind, bool buy, uint256 amount, address recipient) = abi.decode(data, (uint8, bool, uint256, address));
        BalanceDelta delta;
        if (kind < 2) {
            if (kind == 0 || !_usesHookFees()) {
                (delta,) = manager.modifyLiquidity(pool, ModifyLiquidityParams(lower, upper,
                    kind == 0 ? int256(uint256(lockedLiquidity)) : int256(0), bytes32(0)), "");
            }
            if (kind == 1) _collectFeeClaims();
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
        require(lockedLiquidity > 0 && amountIn > 0 && amountIn <= uint256(uint128(type(int128).max)) && minimumOut > 0, "Trade bounds");
        require(block.timestamp <= deadline && deadline <= block.timestamp + 5 minutes, "Fresh deadline");
        IERC20 input = buy ? dollar : token; IERC20 output = buy ? token : dollar;
        input.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 beforeBalance = output.balanceOf(msg.sender);
        _unlock(abi.encode(uint8(2), buy, amountIn, msg.sender));
        amountOut = output.balanceOf(msg.sender) - beforeBalance; require(amountOut >= minimumOut, "Slippage");
        emit Trade(msg.sender, buy, amountIn, amountOut);
    }

    function collect() external nonReentrant returns (uint256 dollars, uint256 tokens) {
        require(lockedLiquidity > 0, "Not launched");
        uint256 beforeDollar = dollar.balanceOf(address(this)); uint256 beforeToken = token.balanceOf(address(this));
        _unlock(abi.encode(uint8(1), false, uint256(0), address(this)));
        dollars = dollar.balanceOf(address(this)) - beforeDollar; tokens = token.balanceOf(address(this)) - beforeToken;
        feeTokens += tokens; if (dollars > 0) _distribute(dollars);
        emit Fees(dollars, tokens);
    }

    /// @notice Only the creator or current runtime selects the conversion's price floor.
    ///         It can sell collected fee tokens, never principal or launch dust.
    function convertFees(uint256 amount, uint256 minimumOut, uint256 deadline) external nonReentrant returns (uint256 dollars) {
        require(msg.sender == agent.human() || msg.sender == agent.signer(), "Agent policy");
        require(amount > 0 && amount <= feeTokens && amount <= uint256(uint128(type(int128).max)) && minimumOut > 0, "Fee bounds");
        require(block.timestamp <= deadline && deadline <= block.timestamp + 5 minutes, "Fresh deadline");
        feeTokens -= amount; uint256 beforeBalance = dollar.balanceOf(address(this));
        _unlock(abi.encode(uint8(2), false, amount, address(this)));
        dollars = dollar.balanceOf(address(this)) - beforeBalance; require(dollars >= minimumOut, "Slippage");
        _distribute(dollars); emit FeeConversion(amount, dollars);
    }

    function _validSeed(uint256 seed) internal pure virtual returns (bool) { return seed >= 100e6 && seed <= 1_000_000e6; }
    function _collectFeeClaims() internal virtual {}
    function _usesHookFees() internal pure virtual returns (bool) {return false;}

    function _distribute(uint256 amount) internal virtual {
        uint256 agentShare = amount * 20 / 100; uint256 creditShare = amount * 20 / 100;
        uint256 humanShare = amount * 30 / 100; uint256 protocolShare = amount * 20 / 100;
        dollar.safeTransfer(address(agent), agentShare);
        if (creditShare > 0) {
            dollar.forceApprove(address(credits), creditShare);
            bool hasBackers = backers.totalSupply() > 0;
            credits.mint(creditShare, hasBackers ? address(backers) : address(agent));
            dollar.forceApprove(address(credits), 0);
            if (hasBackers) backers.distribute(creditShare);
            else credits.activateAccount(agent.agentId(), creditShare);
        }
        dollar.safeTransfer(creator, humanShare); dollar.safeTransfer(protocolTreasury, protocolShare);
        dollar.safeTransfer(noerTreasury, amount - agentShare - creditShare - humanShare - protocolShare);
    }
}

/// @notice Optional token launch for an existing, otherwise tokenless registered agent.
///         Nothing deploys until the human supplies real quote-asset liquidity.
contract NoerraAgentLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentRegistry public immutable registry;
    NoerraAgentCredits public immutable credits;
    IPoolManager public immutable manager;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    NoerraStandaloneCashDeployer public immutable creationDeployer;
    mapping(bytes32 => NoerraLockedCreation) public launches;
    event TokenLaunched(bytes32 indexed agentId, address indexed token, address locker, address backers);

    constructor(NoerraAgentRegistry registry_, NoerraAgentCredits credits_, IPoolManager manager_, address protocol_, address noer_) {
        require(address(registry_) == address(credits_.registry()) && address(registry_.dollar()) == address(credits_.dollar()), "Registry and dollar");
        require(address(manager_).code.length > 0 && protocol_ != address(0) && noer_ != address(0), "Pinned deployment");
        registry = registry_; credits = credits_; manager = manager_; protocolTreasury = protocol_; noerTreasury = noer_;
        creationDeployer = new NoerraStandaloneCashDeployer(address(this));
    }

    function launch(bytes32 agentId, string calldata name, string calldata symbol, uint256 seed)
        external nonReentrant returns (NoerraLockedCreation locker) {
        address account = registry.accounts(agentId);
        require(account != address(0) && NoerraAgentAccount(account).human() == msg.sender, "Agent human only");
        require(address(launches[agentId]) == address(0) && registry.tokens(agentId) == address(0), "One creation token");
        locker = creationDeployer.deploy(NoerraAgentAccount(account));
        IERC20 token = IERC20(address(new NoerraCreationToken(name, symbol, address(locker))));
        NoerraBackers backers = new NoerraBackers(token, IERC20(address(credits)), address(locker));
        launches[agentId] = locker;
        IERC20(address(credits.dollar())).safeTransferFrom(msg.sender, address(locker), seed);
        locker.initialize(token, backers, seed);
        emit TokenLaunched(agentId, address(token), address(locker), address(backers));
    }
}

/// @dev Fixed child builder keeps the source factory runtime below EIP-170.
contract NoerraStandaloneCashDeployer {
    address public immutable factory;
    constructor(address factory_) {factory=factory_;}
    function deploy(NoerraAgentAccount account) external returns(NoerraLockedCreation) {
        require(msg.sender==factory,"Factory only");NoerraAgentLaunchpad source=NoerraAgentLaunchpad(factory);
        return new NoerraLockedCreation(source.manager(),account,source.credits(),source.credits().dollar(),
            source.protocolTreasury(),source.noerTreasury(),factory);
    }
}
