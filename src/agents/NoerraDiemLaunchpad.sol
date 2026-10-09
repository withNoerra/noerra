// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {NoerraDiem, IAgentPoolBacking} from "./NoerraDiem.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, NoerraCreationToken} from "./NoerraAgents.sol";
import {NoerraLockedCreation, NoerraBackers} from "./NoerraLaunchpad.sol";

/// @notice Direct nDIEM position. Its earned quote fees increase renewable compute,
///         while backers receive redeemable nDIEM, not dollar-denominated NCC.
contract NoerraDiemCreation is NoerraLockedCreation {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    NoerraDiem public immutable wrapper;
    event ComputeLocked(bytes32 indexed agentId, uint256 amount);

    constructor(IPoolManager manager_, NoerraAgentAccount agent_, NoerraDiem wrapper_, address protocol_, address noer_, address factory_)
        NoerraLockedCreation(manager_, agent_, NoerraAgentCredits(address(0)), IERC20(address(wrapper_)), protocol_, noer_, factory_) {
        wrapper = wrapper_;
    }

    function _validSeed(uint256 seed) internal pure override returns (bool) {
        return seed >= 1e14 && seed <= 100_000 ether;
    }

    /// @notice Retained legacy Base-only bridged market; never an Ethereum genesis allocation.
    function initializeSleeping(IERC20 token_, NoerraBackers backers_, uint256 supply,
        uint160 price, int24 lower_, int24 upper_) external override nonReentrant {
        require(block.chainid == 8453, "Legacy Base market only");
        require(supply == 500_000_000 ether && token_.balanceOf(address(this)) == supply, "Legacy bridged supply");
        _initializeSleeping(token_, backers_, supply, price, lower_, upper_);
    }

    /// @notice Principal only, from this exact immutable owner/range/salt position.
    ///         Fees, other positions and manager donations cannot inflate backing.
    function positionBacking() external view returns (uint256) {
        PoolKey memory key = pool;
        (uint128 liquidity,,) = manager.getPositionInfo(key.toId(), address(this), lower, upper, bytes32(0));
        require(liquidity == lockedLiquidity && liquidity > 0, "Locked position changed");
        (uint160 current,,,) = manager.getSlot0(key.toId());
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        if (Currency.unwrap(key.currency0) == address(wrapper)) {
            if (current >= high) return 0;
            return SqrtPriceMath.getAmount0Delta(current > low ? current : low, high, liquidity, false);
        }
        require(Currency.unwrap(key.currency1) == address(wrapper), "Quote asset");
        if (current <= low) return 0;
        return SqrtPriceMath.getAmount1Delta(low, current < high ? current : high, liquidity, false);
    }

    function _distribute(uint256 amount) internal override {
        uint256 agentShare = amount * 20 / 100;
        uint256 backerShare = amount * 20 / 100;
        uint256 humanShare = amount * 30 / 100;
        uint256 protocolShare = amount * 20 / 100;
        bool hasBackers = backers.totalSupply() > 0;
        uint256 locked = agentShare + (hasBackers ? 0 : backerShare);
        if (locked > 0) {
            dollar.forceApprove(address(wrapper), locked);
            wrapper.lockFor(agent.agentId(), locked);
            dollar.forceApprove(address(wrapper), 0);
            emit ComputeLocked(agent.agentId(), locked);
        }
        if (hasBackers && backerShare > 0) {
            dollar.safeTransfer(address(backers), backerShare);
            backers.distribute(backerShare);
        }
        dollar.safeTransfer(creator, humanShare);
        dollar.safeTransfer(protocolTreasury, protocolShare);
        dollar.safeTransfer(noerTreasury, amount - agentShare - backerShare - humanShare - protocolShare);
    }
}

/// @dev Separate immutable creation bytecode keeps the factory under EIP-170.
///      Only the reader's frozen factory can deploy; no upgradeable delegatecall.
contract NoerraDiemCreationDeployer {
    NoerraDiem public immutable wrapper;
    IPoolManager public immutable manager;
    constructor(NoerraDiem wrapper_, IPoolManager manager_) {
        require(address(wrapper_).code.length > 0 && address(manager_).code.length > 0, "Pinned deployment");
        wrapper = wrapper_; manager = manager_;
    }
    function deploy(bytes32 id) external returns (NoerraDiemCreation) {
        NoerraDiemLaunchpad factory = NoerraDiemLaunchpad(msg.sender);
        require(address(NoerraDiemBackingReader(address(wrapper.backingReader())).factory()) == msg.sender, "Frozen factory only");
        address account = wrapper.registry().accounts(id);
        require(account != address(0), "Agent account");
        return new NoerraDiemCreation(manager, NoerraAgentAccount(account), wrapper,
            factory.protocolTreasury(), factory.noerTreasury(), msg.sender);
    }
}

/// @notice One immutable deployment, bound once before any wrapping/staking launch.
///         The deployer disappears after binding; no price-reporting operator exists.
contract NoerraDiemBackingReader is IAgentPoolBacking {
    address public deployer;
    NoerraDiemLaunchpad public factory;
    IPoolManager public immutable manager;
    NoerraAgentRegistry public immutable registry;
    constructor(IPoolManager manager_, NoerraAgentRegistry registry_) {
        require(address(manager_).code.length > 0 && address(registry_).code.length > 0, "Pinned deployment");
        manager = manager_; registry = registry_; deployer = msg.sender;
    }
    function bind(NoerraDiemLaunchpad factory_) external {
        require(msg.sender == deployer && address(factory) == address(0), "One binding");
        require(address(factory_).code.length > 0 && address(factory_.manager()) == address(manager)
            && address(factory_.registry()) == address(registry)
            && address(factory_.wrapper().backingReader()) == address(this), "Backing wiring");
        factory = factory_; deployer = address(0);
    }
    function poolBacking(bytes32 id) external view returns (uint256) {
        require(address(factory) != address(0), "Reader not bound");
        NoerraDiemCreation locker = factory.launches(id);
        return address(locker) == address(0) ? 0 : locker.positionBacking();
    }
    /// @notice Bounded discovery only; never used by staking or redemption.
    function poolBackingPage(uint256 start, uint256 maximum) external view returns (uint256 subtotal, uint256 next) {
        require(address(factory) != address(0), "Reader not bound");
        require(maximum > 0 && maximum <= 64, "Page bounds");
        uint256 count = factory.count();
        require(start <= count, "Page cursor");
        next = count - start > maximum ? start + maximum : count;
        for (uint256 i = start; i < next; ++i) subtotal += factory.launches(factory.agentIds(i)).positionBacking();
    }

}

/// @notice Permanent nDIEM markets. Reconciliation reads one position; discovery is paginated.
///         Select one market factory per product deployment, not both quote routes.
contract NoerraDiemLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentRegistry public immutable registry;
    NoerraDiem public immutable wrapper;
    IPoolManager public immutable manager;
    NoerraDiemCreationDeployer public immutable creationDeployer;
    address public immutable protocolTreasury;
    address public immutable noerTreasury;
    mapping(bytes32 => NoerraDiemCreation) public launches;
    bytes32[] public agentIds;
    event TokenLaunched(bytes32 indexed agentId, address indexed token, address locker, address backers);
    constructor(NoerraAgentRegistry registry_, NoerraDiem wrapper_, IPoolManager manager_, NoerraDiemCreationDeployer deployer_, address protocol_, address noer_) {
        require(address(registry_) == address(wrapper_.registry()) && address(manager_).code.length > 0
            && protocol_ != address(0) && noer_ != address(0), "Pinned deployment");
        require(address(deployer_.wrapper()) == address(wrapper_) && address(deployer_.manager()) == address(manager_), "Creation wiring");
        registry = registry_; wrapper = wrapper_; manager = manager_; creationDeployer = deployer_;
        protocolTreasury = protocol_; noerTreasury = noer_;
    }
    function count() external view returns (uint256) { return agentIds.length; }
    function launch(bytes32 id, string calldata name, string calldata symbol, uint256 seed)
        external nonReentrant returns (NoerraDiemCreation locker) {
        address account = registry.accounts(id);
        require(account != address(0) && NoerraAgentAccount(account).human() == msg.sender, "Agent human only");
        require(address(launches[id]) == address(0) && registry.tokens(id) == address(0), "One creation token");
        require(address(NoerraDiemBackingReader(address(wrapper.backingReader())).factory()) == address(this), "Reader not bound");
        locker = creationDeployer.deploy(id);
        IERC20 token = IERC20(address(new NoerraCreationToken(name, symbol, address(locker))));
        NoerraBackers backers = new NoerraBackers(token, IERC20(address(wrapper)), address(locker));
        launches[id] = locker; agentIds.push(id);
        IERC20(address(wrapper)).safeTransferFrom(msg.sender, address(locker), seed);
        locker.initialize(token, backers, seed);
        emit TokenLaunched(id, address(token), address(locker), address(backers));
    }
}
