// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, NoerraCreationToken} from "./NoerraAgents.sol";
import {NoerraLockedCreation, NoerraBackers} from "./NoerraLaunchpad.sol";
import {NoerraBridgedToken, NoerraTokenBridgeReserve, INoerraStandardBridge} from "./NoerraCanonicalToken.sol";
import {INoerraCrossDomainMessenger} from "./NoerraAgentMirror.sol";
import {NoerraLaunchProtectionHook} from "./NoerraLaunchProtectionHook.sol";
import {NoerraQuoter} from "./NoerraQuoter.sol";
import {NoerraEthereumCreation} from "./NoerraEthereumCreation.sol";

interface INoerraBrainReceiver {
    function receiveLaunch(bytes32 id, address sourceToken, string calldata name, string calldata symbol) external;
}

interface INoerraEthUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev Source-only token creation keeps permanent-pool factories below EIP-170.
contract NoerraSleepingTokenDeployer {
    address public immutable factory;
    constructor(address factory_) { factory = factory_; }
    function predict(bytes32 id, string memory name, string memory symbol) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(type(NoerraCreationToken).creationCode, abi.encode(name, symbol, factory)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), id, hash)))));
    }
    function deploy(bytes32 id, string calldata name, string calldata symbol) external returns (NoerraCreationToken) {
        require(msg.sender == factory, "Source factory only");
        return new NoerraCreationToken{salt: id}(name, symbol, factory);
    }
}

/// @dev Isolates permanent-pool creation bytecode; can serve only its immutable source factory.
contract NoerraSleepingCashDeployer {
    address public immutable factory;
    IPoolManager public immutable manager;
    NoerraAgentCredits public immutable credits;
    NoerraSleepingTokenDeployer public immutable tokenDeployer;
    NoerraQuoter public immutable protectionQuoter;
    NoerraLaunchProtectionHook public immutable launchProtectionHook;

    constructor(address factory_, IPoolManager manager_, NoerraAgentCredits credits_, bytes32 hookSalt) {
        require(
            factory_ != address(0) && address(manager_).code.length > 0 && address(credits_).code.length > 0,
            "Source pins"
        );
        factory = factory_;
        manager = manager_;
        credits = credits_;
        tokenDeployer = new NoerraSleepingTokenDeployer(factory_);
        protectionQuoter = new NoerraQuoter(manager_);
        launchProtectionHook = new NoerraLaunchProtectionHook{salt: hookSalt}(manager_, factory_, address(protectionQuoter));
    }

    function deploy(bytes32 id) external returns (NoerraLockedCreation) {
        require(msg.sender == factory, "Source factory only");
        NoerraSleepingLaunchpad launchpad = NoerraSleepingLaunchpad(factory);
        return new NoerraEthereumCreation(
            manager,
            NoerraAgentAccount(credits.registry().accounts(id)),
            credits,
            credits.dollar(),
            launchpad.protocolTreasury(),
            launchpad.noerTreasury(),
            factory
        );
    }
}

/// @notice Ethereum cash launch. Zero quote seed, zero DIEM, no promised running agent.
/// All one-billion tokens enter permanent Ethereum cash liquidity. No Base supply is preallocated.
contract NoerraSleepingLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct BridgePins {
        address standardBridge;
        address messenger;
        address baseBridge;
        address baseLaunchpad;
        uint32 minGasLimit;
    }

    struct OraclePins {
        address feed;
        uint32 maximumAge;
    }

    struct Launch {
        IERC20 token;
        NoerraLockedCreation locker;
        NoerraBackers backers;
        NoerraTokenBridgeReserve reserve;
        address remote;
    }
    NoerraAgentRegistry public immutable registry;
    NoerraAgentCredits public immutable credits;
    IPoolManager public immutable manager;
    NoerraSleepingCashDeployer public immutable cashDeployer;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    address public immutable standardBridge;
    address public immutable messenger;
    address public immutable baseBridge;
    address public immutable baseLaunchpad;
    uint32 public immutable minGasLimit;
    INoerraEthUsdFeed public immutable ethUsdFeed;
    uint32 public immutable oracleMaximumAge;
    NoerraLaunchProtectionHook public immutable launchProtectionHook;
    uint256 public constant LAUNCH_FDV_ETH = 1 ether;
    uint256 public constant LAUNCH_PROTECTION_BLOCKS = 10;
    uint256 public constant LAUNCH_MAX_HOLDING_BPS = 200;
    uint256 public constant sourceChainId = 1;
    uint256 public constant providerChainId = 8453;
    mapping(bytes32 => NoerraLockedCreation) public cashLaunches;
    mapping(bytes32 => NoerraTokenBridgeReserve) public bridgeReserves;
    mapping(bytes32 => bool) public metadataSent;
    event SleepingLaunched(
        bytes32 indexed agentId,
        address indexed token,
        address locker,
        address backers,
        address bridgeReserve,
        address baseToken
    );
    event BrainLaunchSent(bytes32 indexed agentId, address indexed token, address baseToken);

    constructor(
        NoerraAgentRegistry registry_,
        NoerraAgentCredits credits_,
        IPoolManager manager_,
        NoerraSleepingCashDeployer builder_,
        address protocol_,
        address noer_,
        BridgePins memory bridge_,
        OraclePins memory oracle_
    ) {
        require(
            address(credits_.registry()) == address(registry_)
                && address(credits_.dollar()) == address(registry_.dollar()),
            "Source registry"
        );
        require(address(manager_).code.length > 0 && protocol_ != address(0) && noer_ != address(0), "Source pins");
        require(
            builder_.factory() == address(this) && address(builder_.manager()) == address(manager_)
                && address(builder_.credits()) == address(credits_),
            "Source builder"
        );
        require(
            bridge_.standardBridge.code.length > 0 && bridge_.messenger.code.length > 0
                && bridge_.baseBridge != address(0) && bridge_.baseLaunchpad != address(0),
            "Canonical bridge pins"
        );
        require(bridge_.minGasLimit >= 1_000_000 && bridge_.minGasLimit <= 5_000_000, "Message gas bounds");
        require(block.chainid == 1 && oracle_.feed.code.length > 0
            && INoerraEthUsdFeed(oracle_.feed).decimals() == 8, "Ethereum ETH USD feed");
        require(oracle_.maximumAge >= 60 && oracle_.maximumAge <= 2 hours, "Oracle age bounds");
        NoerraLaunchProtectionHook hook = builder_.launchProtectionHook();
        require(address(hook.manager()) == address(manager_) && hook.factory() == address(this)
            && hook.quoter() == address(builder_.protectionQuoter()), "Launch hook wiring");
        launchProtectionHook = hook;
        registry = registry_;
        credits = credits_;
        manager = manager_;
        cashDeployer = builder_;
        protocolTreasury = protocol_;
        noerTreasury = noer_;
        standardBridge = bridge_.standardBridge;
        messenger = bridge_.messenger;
        baseBridge = bridge_.baseBridge;
        baseLaunchpad = bridge_.baseLaunchpad;
        minGasLimit = bridge_.minGasLimit;
        ethUsdFeed = INoerraEthUsdFeed(oracle_.feed);
        oracleMaximumAge = oracle_.maximumAge;
    }

    function predictToken(bytes32 id, string memory name, string memory symbol) public view returns (address) {
        return cashDeployer.tokenDeployer().predict(id, name, symbol);
    }

    function predictBaseToken(bytes32 id, address source, string memory name, string memory symbol)
        public
        view
        returns (address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(type(NoerraBridgedToken).creationCode, abi.encode(baseBridge, source, name, symbol))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), baseLaunchpad, id, hash)))));
    }

    /// @notice A 1 ETH FDV target, denominated in six-decimal dollars.
    function initialPoolNotional() public view returns (uint256 value) {
        (uint80 round, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        require(round != 0 && answer > 0 && answeredInRound >= round && startedAt != 0 && startedAt <= updatedAt,
            "Oracle round");
        require(updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= oracleMaximumAge,
            "Oracle freshness");
        value = uint256(answer) / 100;
        require(value > 0 && value <= 1_000_000e6, "Oracle price bounds");
    }

    /// @notice Initializes the 1 ETH FDV spot target with an aligned token-only range. No quote asset is deposited.
    function quoteSleeping(bytes32 id, string calldata name, string calldata symbol)
        external view returns (address token, uint160 price, int24 lower, int24 upper)
    {
        return _quoteSleeping(id, name, symbol, initialPoolNotional());
    }

    /// @notice Compatibility overload accepts only the current fixed pool notional.
    function quoteSleeping(bytes32 id, string calldata name, string calldata symbol, uint256 valuation)
        external
        view
        returns (address token, uint160 price, int24 lower, int24 upper)
    {
        require(valuation == initialPoolNotional(), "Fixed ETH launch valuation");
        return _quoteSleeping(id, name, symbol, valuation);
    }

    function _quoteSleeping(bytes32 id, string calldata name, string calldata symbol, uint256 valuation)
        private view returns (address token, uint160 price, int24 lower, int24 upper)
    {
        token = predictToken(id, name, symbol);
        bool first = token < address(credits.dollar());
        uint256 supply = 1_000_000_000 ether;
        uint160 raw = uint160(Math.sqrt(Math.mulDiv(first ? valuation : supply, 1 << 192, first ? supply : valuation)));
        int24 tick = TickMath.getTickAtSqrtPrice(raw);
        int24 boundary = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) boundary -= 60;
        if (first && raw > TickMath.getSqrtPriceAtTick(boundary)) boundary += 60;
        require(boundary > -887220 && boundary < 887220, "Initial price bounds");
        lower = first ? boundary : int24(-887220);
        upper = first ? int24(887220) : boundary;
        price = raw;
    }

    function launchSleeping(
        bytes32 id,
        string calldata name,
        string calldata symbol,
        uint160 price,
        int24 lower,
        int24 upper
    ) external nonReentrant returns (address token, address locker, address reserve) {
        address account = registry.accounts(id);
        require(account != address(0) && NoerraAgentAccount(account).human() == msg.sender, "Agent human only");
        require(address(cashLaunches[id]) == address(0) && registry.tokens(id) == address(0), "One creation token");
        _requireCurrentQuote(id, name, symbol, price, lower, upper);
        NoerraAgentAccount(account).lockAutonomousCore();
        Launch memory value = _create(id, name, symbol);
        value.locker.initializeSleeping(value.token, value.backers, 1_000_000_000 ether, price, lower, upper);
        emit SleepingLaunched(
            id,
            address(value.token),
            address(value.locker),
            address(value.backers),
            address(value.reserve),
            value.remote
        );
        return (address(value.token), address(value.locker), address(value.reserve));
    }

    function _requireCurrentQuote(bytes32 id, string calldata name, string calldata symbol,
        uint160 price, int24 lower, int24 upper) private view
    {
        (, uint160 currentPrice, int24 currentLower, int24 currentUpper) =
            _quoteSleeping(id, name, symbol, initialPoolNotional());
        require(price == currentPrice && lower == currentLower && upper == currentUpper, "Fresh fixed launch quote");
    }

    function _create(bytes32 id, string calldata name, string calldata symbol) private returns (Launch memory value) {
        value.token = IERC20(address(cashDeployer.tokenDeployer().deploy(id, name, symbol)));
        value.locker = cashDeployer.deploy(id);
        value.backers = new NoerraBackers(value.token, credits.dollar(), address(value.locker));
        value.remote = predictBaseToken(id, address(value.token), name, symbol);
        value.reserve = new NoerraTokenBridgeReserve(
            value.token, INoerraStandardBridge(standardBridge), value.remote, baseLaunchpad, minGasLimit
        );
        cashLaunches[id] = value.locker;
        bridgeReserves[id] = value.reserve;
        NoerraCreationToken(address(value.token)).initializeLaunchProtection(
            address(manager), address(value.locker), address(value.reserve), standardBridge
        );
        value.locker.setLaunchProtectionHook(IHooks(address(launchProtectionHook)));
        launchProtectionHook.register(address(value.token), address(value.locker), address(credits.dollar()));
        value.token.safeTransfer(address(value.locker), 1_000_000_000 ether);
    }

    /// @notice Optional legacy metadata only. It allocates no tokens, bridges no funds and is not startup funding.
    function dispatchBrain(bytes32 id) external nonReentrant {
        NoerraLockedCreation locker = cashLaunches[id];
        require(address(locker) != address(0) && !metadataSent[id], "Pending brain launch");
        metadataSent[id] = true;
        NoerraCreationToken token = NoerraCreationToken(address(locker.token()));
        INoerraCrossDomainMessenger(messenger)
            .sendMessage(
                baseLaunchpad,
                abi.encodeCall(INoerraBrainReceiver.receiveLaunch, (id, address(token), token.name(), token.symbol())),
                minGasLimit
            );
        emit BrainLaunchSent(id, address(token), bridgeReserves[id].remoteToken());
    }
}
