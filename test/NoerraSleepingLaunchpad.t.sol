// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {NoerraLaunchProtectionHook} from "../src/agents/NoerraLaunchProtectionHook.sol";
import {NoerraQuoter} from "../src/agents/NoerraQuoter.sol";
import {
    NoerraAgentRegistry,
    NoerraAgentCredits,
    NoerraAgentAccount,
    NoerraCreationToken,
    IAgentRegistry,
    IAgentRecoveryVerifier
} from "../src/agents/NoerraAgents.sol";
import {NoerraLockedCreation, NoerraBackers} from "../src/agents/NoerraLaunchpad.sol";
import {NoerraSleepingLaunchpad, NoerraSleepingCashDeployer, NoerraSleepingTokenDeployer} from "../src/agents/NoerraSleepingLaunchpad.sol";
import {NoerraEcosystemVault} from "../src/agents/NoerraEcosystem.sol";
import {NoerraEcosystemFixture} from "./NoerraEcosystemFixture.sol";
import {NoerraBrainLaunchpad} from "../src/agents/NoerraBrainLaunchpad.sol";
import {
    NoerraBridgedToken,
    NoerraTokenBridgeReserve,
    INoerraOptimismMintableERC20,
    INoerraStandardBridge
} from "../src/agents/NoerraCanonicalToken.sol";
import {NoerraAgentMirrorRegistry, NoerraAgentAuthorityMessenger} from "../src/agents/NoerraAgentMirror.sol";
import {NoerraDiem, IVeniceDiem} from "../src/agents/NoerraDiem.sol";
import {
    NoerraDiemCreation,
    NoerraDiemLaunchpad,
    NoerraDiemCreationDeployer,
    NoerraDiemBackingReader
} from "../src/agents/NoerraDiemLaunchpad.sol";
import {AgentTestVerifier} from "./NoerraAgents.t.sol";
import {LaunchDollar} from "./NoerraLaunchpad.t.sol";
import {MessageFixture} from "./NoerraAgentMirror.t.sol";
import {SyntheticDiem} from "./NoerraDiem.t.sol";

/// @dev Local unsigned price fixture; production pins a reviewed Ethereum ETH/USD feed.
contract SleepingEthUsdFixture {
    uint8 public decimals = 8;
    uint80 public roundId = 1;
    int256 public answer = 2000e8;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor() { startedAt = block.timestamp; updatedAt = block.timestamp; }
    function setDecimals(uint8 value) external { decimals = value; }
    function setRoundData(uint80 round_, int256 answer_, uint256 started_, uint256 updated_, uint80 answered_) external {
        roundId = round_; answer = answer_; startedAt = started_; updatedAt = updated_; answeredInRound = answered_;
    }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// Fixture only: models canonical escrow→message→mint, never manufactures source supply.
contract CanonicalBridgeFixture is INoerraStandardBridge {
    address public local;
    address public remote;
    address public recipient;
    uint256 public amount;
    bool public finalized;
    bool public reject;

    function setReject(bool value) external {
        reject = value;
    }

    function bridgeERC20To(address local_, address remote_, address to, uint256 amount_, uint32, bytes calldata)
        external
    {
        require(!reject, "Bridge rejected");
        require(amount == 0, "One fixture transfer");
        require(IERC20(local_).transferFrom(msg.sender, address(this), amount_), "Escrow transfer");
        local = local_;
        remote = remote_;
        recipient = to;
        amount = amount_;
    }

    function finalize() external {
        require(!finalized && amount > 0, "Pending bridge");
        require(
            NoerraBridgedToken(remote).remoteToken() == local && NoerraBridgedToken(remote).bridge() == address(this),
            "Canonical pair"
        );
        finalized = true;
        NoerraBridgedToken(remote).mint(recipient, amount);
    }

    /// @dev Explicit local-test relay for separate Anvil processes. This is not production authentication.
    function finalizeDeposit(address source, address destination, address to, uint256 value) external {
        require(
            NoerraBridgedToken(destination).remoteToken() == source
                && NoerraBridgedToken(destination).bridge() == address(this),
            "Canonical pair"
        );
        NoerraBridgedToken(destination).mint(to, value);
    }
}

contract NoerraSleepingLaunchpadTest is Test {
    LaunchDollar dollar;
    NoerraAgentRegistry registry;
    NoerraAgentCredits credits;
    PoolManager manager;
    PoolManager baseManager;
    NoerraSleepingLaunchpad source;
    NoerraBrainLaunchpad brain;
    NoerraDiem wrapper;
    SyntheticDiem diem;
    NoerraAgentMirrorRegistry mirrors;
    NoerraAgentAuthorityMessenger authority;
    NoerraDiemBackingReader reader;
    MessageFixture l1;
    MessageFixture l2;
    CanonicalBridgeFixture bridge;
    SleepingEthUsdFixture feed;
    bytes32 id;
    address account;
    address human = address(0xA11CE);
    address trader = address(0xB0B);
    NoerraEcosystemVault ecosystem;

    function setUp() public {
        vm.chainId(1);
        dollar = new LaunchDollar();
        manager = new PoolManager(address(this));
        baseManager = new PoolManager(address(this));
        registry = new NoerraAgentRegistry(dollar, new AgentTestVerifier());
        credits = new NoerraAgentCredits(dollar, IAgentRegistry(address(registry)), address(0));
        (ecosystem,,) = NoerraEcosystemFixture.deploy(manager, dollar, address(0xC1), address(this));
        l1 = new MessageFixture();
        l2 = new MessageFixture();
        bridge = new CanonicalBridgeFixture();
        feed = new SleepingEthUsdFixture();
        address authorityAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        mirrors = new NoerraAgentMirrorRegistry(l2, authorityAddress, address(registry));
        authority = new NoerraAgentAuthorityMessenger(registry, l1, address(mirrors), 1_000_000);
        diem = new SyntheticDiem();
        reader = new NoerraDiemBackingReader(baseManager, NoerraAgentRegistry(address(mirrors)));
        wrapper = new NoerraDiem(IVeniceDiem(address(diem)), IAgentRegistry(address(mirrors)), reader, 3500);
        NoerraDiemCreationDeployer brainBuilder = new NoerraDiemCreationDeployer(wrapper, baseManager);
        address sourceAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        brain = new NoerraBrainLaunchpad(
            mirrors,
            wrapper,
            baseManager,
            brainBuilder,
            address(0xC1),
            address(0xC2),
            NoerraBrainLaunchpad.SourcePins(address(l2), sourceAddress, address(bridge), 1 ether)
        );
        NoerraSleepingCashDeployer cashBuilder = _cashBuilder(sourceAddress);
        source = new NoerraSleepingLaunchpad(
            registry,
            credits,
            manager,
            cashBuilder,
            address(0xC1),
            address(ecosystem),
            NoerraSleepingLaunchpad.BridgePins(address(bridge), address(l1), address(bridge), address(brain), 1_000_000),
            NoerraSleepingLaunchpad.OraclePins(address(feed), 7200)
        );
        assertEq(address(source), sourceAddress);
        registry.enrollAutonomousLaunchFactory(address(source));
        reader.bind(NoerraDiemLaunchpad(address(brain)));
        vm.prank(human);
        (id, account) = registry.createAccount(human, keccak256("metadata"), keccak256("build"), 5e6, 10e6);
        _approveStartup();
    }

    function _approveStartup() internal {
        vm.startPrank(human);
        NoerraAgentAccount(account).setRecoveryPolicy(1e6,1e6);
        NoerraAgentAccount(account).approveAutomaticActivation(1,keccak256("approved startup"),6e6,block.timestamp+1 days,0.001 ether);
        vm.stopPrank();
    }

    function testLaunchAtomicallyLocksApprovedCoreAndRefusesUnapprovedTokenCreation() public {
        vm.prank(human); NoerraAgentAccount(account).cancelAutomaticActivation();
        (,uint160 price,int24 lower,int24 upper)=source.quoteSleeping(id,"Sleeping","SLEEP");
        vm.prank(human); vm.expectRevert("Autonomous approval");
        source.launchSleeping(id,"Sleeping","SLEEP",price,lower,upper);
        assertFalse(NoerraAgentAccount(account).autonomousCoreLocked());
        _approveStartup();
        vm.prank(human); source.launchSleeping(id,"Sleeping","SLEEP",price,lower,upper);
        assertTrue(NoerraAgentAccount(account).autonomousCoreLocked());
        vm.prank(human); vm.expectRevert("Autonomous policy"); NoerraAgentAccount(account).cancelAutomaticActivation();
    }

    function _launch() internal returns (NoerraLockedCreation locker) {
        if (!NoerraAgentAccount(account).autonomousCoreLocked()) _approveStartup();
        (address predicted, uint160 price, int24 lower, int24 upper) =
            source.quoteSleeping(id, "Sleeping", "SLEEP");
        vm.prank(human);
        (address token, address address_, address reserve) =
            source.launchSleeping(id, "Sleeping", "SLEEP", price, lower, upper);
        locker = NoerraLockedCreation(address_);
        assertEq(token, predicted);
        assertEq(reserve, address(source.bridgeReserves(id)));
    }

    function _cashBuilder(address factory) private returns (NoerraSleepingCashDeployer) {
        address builder = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address quoter = vm.computeCreateAddress(builder, 2);
        bytes32 initHash = keccak256(abi.encodePacked(type(NoerraLaunchProtectionHook).creationCode,
            abi.encode(manager, factory, quoter)));
        uint256 salt;
        bytes memory payload = abi.encodePacked(bytes1(0xff), builder, bytes32(0), initHash);
        while (true) {
            assembly ("memory-safe") {mstore(add(payload,53),salt)}
            if (uint160(uint256(keccak256(payload))) & 0x3fff == 0x20cc) break;
            ++salt;
        }
        return new NoerraSleepingCashDeployer(factory, manager, credits, bytes32(salt));
    }

    function _authority() internal {
        authority.sync(id);
        l2.relay(address(authority), address(mirrors), l1.message());
    }

    function _finalizeLegacyBrain() internal returns (NoerraDiemCreation value) {
        vm.chainId(8453);
        value = brain.finalize(id);
        vm.chainId(1);
    }

    function _metadata() internal {
        source.dispatchBrain(id);
        l2.relay(address(source), address(brain), l1.message());
    }

    /// @dev Exercises the retained optional legacy bridge with tokens actually bought on Ethereum.
    /// Genesis itself contributes no bridge supply, and launch/activation never requires this path.
    function _voluntaryLegacyBridge(NoerraLockedCreation cash) internal {
        vm.roll(block.number + 10);
        dollar.mint(trader, 10_000e6);
        vm.startPrank(trader);
        dollar.approve(address(cash), 10_000e6);
        uint256 bought = cash.trade(true, 10_000e6, 500_000_000 ether, block.timestamp + 60);
        assertGe(bought, 500_000_000 ether);
        cash.token().transfer(address(source.bridgeReserves(id)), 500_000_000 ether);
        vm.stopPrank();
        source.bridgeReserves(id).bridgeTokens();
    }

    function testSleepingLaunchRequiresNoOtherAssetsAndSupplyConserves() public {
        NoerraLockedCreation locker = _launch();
        IERC20 token = locker.token();
        assertEq(dollar.balanceOf(human), 0);
        assertEq(dollar.balanceOf(account), 0);
        assertEq(wrapper.totalLocked(), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(human), 0);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(locker)), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(source.bridgeReserves(id))), 0);
        assertEq(token.balanceOf(address(source)), 0);
        assertGt(locker.lockedLiquidity(), 0);
    }

    function testRealCashBuySellAndFeeCollectionLeavesPrincipalLocked() public {
        NoerraLockedCreation locker = _launch();
        vm.roll(block.number + 10);
        dollar.mint(trader, 100e6);
        vm.startPrank(trader);
        dollar.approve(address(locker), 100e6);
        uint256 bought = locker.trade(true, 100e6, 1, block.timestamp + 60);
        locker.token().approve(address(locker), bought);
        uint256 sold = locker.trade(false, bought, 1, block.timestamp + 60);
        vm.stopPrank();
        assertGt(sold, 0);
        assertLt(sold, 100e6);
        uint128 liquidity = locker.lockedLiquidity();
        locker.collect();
        assertEq(locker.lockedLiquidity(), liquidity);
        assertGt(dollar.balanceOf(account), 0);
    }

    function testSharedHookCannotCollectAnotherAgentsEarnedUsdcOrPrincipal() public {
        NoerraLockedCreation first=_launch();address firstAccount=account;
        vm.prank(human);(id,account)=registry.createAccount(human,keccak256("second-fee-pool"),keccak256("build"),5e6,10e6);
        NoerraLockedCreation second=_launch();
        // The NOERRA-specific launch tax must never spill into ordinary agents.
        assertEq(source.launchProtectionHook().feeBps(),175);
        dollar.mint(trader,2e6);vm.startPrank(trader);
        dollar.approve(address(first),1e6);first.trade(true,1e6,1,block.timestamp+60);
        dollar.approve(address(second),1e6);second.trade(true,1e6,1,block.timestamp+60);vm.stopPrank();
        NoerraLaunchProtectionHook hook=source.launchProtectionHook();
        PoolKey memory a; (a.currency0,a.currency1,a.fee,a.tickSpacing,a.hooks)=first.pool();
        PoolKey memory b; (b.currency0,b.currency1,b.fee,b.tickSpacing,b.hooks)=second.pool();
        assertEq(hook.accruedFees(PoolIdLibrary.toId(a)),17500);
        assertEq(hook.accruedFees(PoolIdLibrary.toId(b)),17500);
        vm.expectRevert("Fee locker only");hook.withdrawFees(b);
        (uint256 dollars,uint256 tokens)=first.collect();assertEq(dollars,17500);assertEq(tokens,0);
        assertEq(hook.accruedFees(PoolIdLibrary.toId(b)),17500);
        assertEq(manager.balanceOf(address(hook),uint160(address(dollar))),17500);
        assertEq(dollar.balanceOf(firstAccount),10500);assertEq(dollar.balanceOf(account),0);
        (dollars,tokens)=second.collect();assertEq(dollars,17500);assertEq(tokens,0);
        assertEq(dollar.balanceOf(firstAccount),10500);assertEq(dollar.balanceOf(account),10500);
        assertEq(manager.balanceOf(address(hook),uint160(address(dollar))),0);
        assertGt(first.lockedLiquidity(),0);assertGt(second.lockedLiquidity(),0);
        vm.roll(block.number+10);assertEq(hook.feeBps(),175);
    }

    function testCanonicalCashFeeSplitNoBackersAndTaxFreeTransfers() public {
        NoerraLockedCreation locker = _launch(); vm.roll(block.number + 10);
        assertEq(locker.FEE(), 0); assertEq(NoerraLaunchProtectionHook(address(locker.launchProtectionHook())).FEE_BPS(),175); assertEq(address(locker.backers().credits()), address(dollar));
        dollar.mint(trader, 100e6); vm.startPrank(trader); dollar.approve(address(locker), 100e6);
        uint256 bought = locker.trade(true, 100e6, 1, block.timestamp + 60);
        locker.token().transfer(human, bought / 10); vm.stopPrank();
        assertEq(locker.token().balanceOf(human), bought / 10);
        uint128 liquidity = locker.lockedLiquidity();
        (uint256 collected,) = locker.collect();
        assertEq(collected,1_750000);
        uint256 creatorAmount = collected * 20 / 100; uint256 ecosystemAmount = collected * 20 / 100;
        assertEq(dollar.balanceOf(account), collected - creatorAmount - ecosystemAmount);
        assertEq(dollar.balanceOf(human), creatorAmount);
        assertEq(ecosystem.totalRevenue(), ecosystemAmount);
        assertEq(dollar.balanceOf(address(0xC1)), ecosystemAmount * 50 / 100);
        assertEq(ecosystem.totalBuybackFunding(), ecosystemAmount - ecosystemAmount * 50 / 100 - ecosystemAmount / 10);
        assertEq(credits.totalSupply(), 0); assertEq(locker.lockedLiquidity(), liquidity);
        uint256 accountBefore = dollar.balanceOf(account); locker.collect(); locker.collect();
        assertEq(dollar.balanceOf(account), accountBefore);
    }

    function testCanonicalCashBackersReceiveUsdcWithoutCreditWrapper() public {
        NoerraLockedCreation locker = _launch(); vm.roll(block.number + 10);
        dollar.mint(trader, 100e6); vm.startPrank(trader); dollar.approve(address(locker), 100e6);
        uint256 bought = locker.trade(true, 100e6, 1, block.timestamp + 60);
        locker.token().approve(address(locker.backers()), bought / 4);
        locker.backers().back(bought / 4); vm.stopPrank();
        (uint256 collected,) = locker.collect();
        uint256 creatorAmount = collected * 20 / 100; uint256 ecosystemAmount = collected * 20 / 100;
        uint256 backerAmount = collected * 10 / 100;
        assertEq(dollar.balanceOf(account), collected - creatorAmount - ecosystemAmount - backerAmount);
        assertEq(dollar.balanceOf(address(locker.backers())), backerAmount);
        NoerraBackers rewardPool = locker.backers();
        vm.prank(trader); uint256 claimed = rewardPool.claim();
        assertGt(claimed, 0); assertLe(claimed, backerAmount); assertLe(backerAmount - claimed, 1);
        assertEq(credits.totalSupply(), 0); assertEq(credits.balanceOf(trader), 0);
    }

    function testPredictedLockerQuoteDustCannotGriefTokenOnlyLaunchOrBecomeFeeRevenue() public {
        address builder = address(source.cashDeployer());
        address predicted = vm.computeCreateAddress(builder, vm.getNonce(builder));
        dollar.mint(predicted, 1);
        NoerraLockedCreation locker = _launch(); assertEq(address(locker), predicted);
        assertEq(dollar.balanceOf(address(locker)), 1); assertEq(dollar.balanceOf(address(manager)), 0);
        locker.collect(); assertEq(dollar.balanceOf(address(locker)), 1);
        assertEq(dollar.balanceOf(account), 0); assertEq(ecosystem.totalRevenue(), 0);
    }

    function testCanonicalBridgeAndBaseBrainRealTradingBacking() public {
        NoerraLockedCreation cash = _launch();
        _authority();
        _metadata();
        assertEq(address(brain.tokens(id)), source.bridgeReserves(id).remoteToken());
        vm.expectRevert("Canonical tokens pending");
        _finalizeLegacyBrain();
        _voluntaryLegacyBridge(cash);
        bridge.finalize();
        NoerraDiemCreation locker = _finalizeLegacyBrain();
        assertEq(reader.poolBacking(id), 0);
        assertEq(cash.token().balanceOf(address(bridge)), 500_000_000 ether);
        assertEq(brain.tokens(id).totalSupply(), 500_000_000 ether);
        diem.mint(trader, 0.1 ether);
        vm.startPrank(trader);
        diem.approve(address(wrapper), 0.1 ether);
        wrapper.wrap(0.1 ether, trader);
        wrapper.approve(address(locker), 0.1 ether);
        uint256 bought = locker.trade(true, 0.1 ether, 1, block.timestamp + 60);
        vm.stopPrank();
        assertGt(bought, 0);
        assertGt(reader.poolBacking(id), 0);
        locker.collect();
        wrapper.reconcile(id);
        assertGt(wrapper.lockedTreasury(id), 0);
        assertEq(wrapper.backing(), wrapper.obligations());
        assertEq(address(wrapper.vaults(id).account()), mirrors.accounts(id));
    }

    function testBaseWaitsForAuthorityRegardlessOfTokenDeliveryOrder() public {
        NoerraLockedCreation cash = _launch();
        _metadata();
        _voluntaryLegacyBridge(cash);
        bridge.finalize();
        vm.expectRevert("Authority pending");
        _finalizeLegacyBrain();
        _authority();
        _finalizeLegacyBrain();
        vm.expectRevert("Canonical tokens pending");
        _finalizeLegacyBrain();
    }

    function testForeignMetadataAndUnbackedMintRejected() public {
        _launch();
        vm.expectRevert("Canonical source launch only");
        brain.receiveLaunch(id, address(0xBAD), "Fake", "FAKE");
        bytes memory payload = abi.encodeCall(brain.receiveLaunch, (id, address(0xBAD), "Fake", "FAKE"));
        vm.expectRevert("Canonical source launch only");
        l2.relay(human, address(brain), payload);
        _metadata();
        NoerraBridgedToken token = brain.tokens(id);
        vm.expectRevert("Canonical bridge only");
        token.mint(trader, 1 ether);
        assertTrue(token.supportsInterface(type(INoerraOptimismMintableERC20).interfaceId));
    }

    function testMetadataOnlyDoesNotRequireBaseTokenAllocationOrBridgeAvailability() public {
        NoerraLockedCreation cash = _launch();
        bridge.setReject(true);
        source.dispatchBrain(id);
        assertTrue(source.metadataSent(id));
        NoerraTokenBridgeReserve reserve = source.bridgeReserves(id);
        assertFalse(reserve.initiated());
        assertEq(cash.token().balanceOf(address(reserve)), 0);
        assertEq(bridge.amount(), 0);
        assertEq(reserve.token().allowance(address(reserve), address(bridge)), 0);
    }

    function testUnauthorizedAndInvalidRangeRollBackWholeLaunch() public {
        (, uint160 price, int24 lower, int24 upper) = source.quoteSleeping(id, "Sleeping", "SLEEP");
        vm.expectRevert("Agent human only");
        source.launchSleeping(id, "Sleeping", "SLEEP", price, lower, upper);
        vm.prank(human);
        vm.expectRevert("Fresh fixed launch quote");
        source.launchSleeping(id, "Sleeping", "SLEEP", price, lower + 1, upper);
        assertEq(address(source.cashLaunches(id)), address(0));
        assertEq(address(source.bridgeReserves(id)), address(0));
        _launch();
    }

    function testReserveCanOnlyBridgeOnceToFixedRecipient() public {
        NoerraLockedCreation cash = _launch();
        NoerraTokenBridgeReserve reserve = source.bridgeReserves(id);
        vm.expectRevert("Pending allocation"); reserve.bridgeTokens();
        _voluntaryLegacyBridge(cash);
        assertEq(bridge.recipient(), address(brain));
        assertEq(bridge.amount(), 500_000_000 ether);
        assertEq(reserve.token().allowance(address(reserve), address(bridge)), 0);
        vm.expectRevert("Pending allocation");
        reserve.bridgeTokens();
        source.dispatchBrain(id);
        assertTrue(source.metadataSent(id));
    }

    function testOneSidedBuyWorksForBothTokenSortOrders() public {
        bool tokenFirst;
        bool quoteFirst;
        dollar.mint(trader, 2000e6);
        for (uint256 i; i < 20 && !(tokenFirst && quoteFirst); ++i) {
            vm.prank(human);
            (id, account) = registry.createAccount(human, keccak256(abi.encode(i)), keccak256("build"), 5e6, 10e6);
            NoerraLockedCreation locker = _launch();
            bool first = address(locker.token()) < address(dollar);
            if (first) tokenFirst = true;
            else quoteFirst = true;
            vm.startPrank(trader);
            dollar.approve(address(locker), 1e6);
            assertGt(locker.trade(true, 1e6, 1, block.timestamp + 60), 0);
            vm.stopPrank();
        }
        assertTrue(tokenFirst && quoteFirst, "Both currency directions exercised");
    }

    function testFixedEthTargetAndCompatibilityQuoteCannotChooseValuation() public {
        assertEq(source.LAUNCH_FDV_ETH(), 1 ether);
        assertEq(source.initialPoolNotional(), 2000e6);
        (address token, uint160 price, int24 lower, int24 upper) = source.quoteSleeping(id, "Sleeping", "SLEEP");
        (address compatible, uint160 compatiblePrice, int24 compatibleLower, int24 compatibleUpper) =
            source.quoteSleeping(id, "Sleeping", "SLEEP", 2000e6);
        assertEq(token, compatible); assertEq(price, compatiblePrice);
        assertEq(lower, compatibleLower); assertEq(upper, compatibleUpper);
        vm.expectRevert("Fixed ETH launch valuation");
        source.quoteSleeping(id, "Sleeping", "SLEEP", 100e6);
        uint256 supply = 1_000_000_000 ether;
        uint256 actual = token < address(dollar)
            ? Math.mulDiv(uint256(price), uint256(price) * supply, 1 << 192)
            : Math.mulDiv(Math.mulDiv(1 << 96, supply, price), 1 << 96, price);
        assertApproxEqAbs(actual, 2000e6, 1);
        uint160 boundary = TickMath.getSqrtPriceAtTick(token < address(dollar) ? lower : upper);
        uint256 executable = token < address(dollar)
            ? Math.mulDiv(uint256(boundary), uint256(boundary) * supply, 1 << 192)
            : Math.mulDiv(Math.mulDiv(1 << 96, supply, boundary), 1 << 96, boundary);
        assertGe(executable, actual);
        assertApproxEqRel(executable, actual, 0.0061e18);
        feed.setRoundData(2, 3000e8, block.timestamp, block.timestamp, 2);
        assertEq(source.initialPoolNotional(), 3000e6);
        vm.prank(human); vm.expectRevert("Fresh fixed launch quote");
        source.launchSleeping(id, "Sleeping", "SLEEP", price, lower, upper);
        assertEq(address(source.cashLaunches(id)), address(0));
        _launch();
    }

    function testLaunchRejectsDirectPriceAndRangeBypass() public {
        (, uint160 price, int24 lower, int24 upper) = source.quoteSleeping(id, "Sleeping", "SLEEP");
        vm.prank(human); vm.expectRevert("Fresh fixed launch quote");
        source.launchSleeping(id, "Sleeping", "SLEEP", price + 1, lower, upper);
        vm.prank(human); vm.expectRevert("Fresh fixed launch quote");
        source.launchSleeping(id, "Sleeping", "SLEEP", price, lower + 60, upper);
        assertEq(address(source.cashLaunches(id)), address(0));
    }

    function testERC6909ClaimOutputCannotBypassLaunchRoutingThenAutomaticallyOpens() public {
        NoerraLockedCreation locker = _launch();
        PoolSwapTest router = new PoolSwapTest(manager);
        PoolKey memory key;
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = locker.pool();
        bool quoteFirst = address(dollar) < address(locker.token());
        dollar.mint(trader, 200e6);
        vm.startPrank(trader);
        dollar.approve(address(router), 200e6);
        vm.expectRevert();
        router.swap(key, SwapParams(quoteFirst, -int256(100e6),
            quoteFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(true, false), "");
        vm.expectRevert();
        router.swap(key, SwapParams(quoteFirst, -int256(1e6),
            quoteFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        dollar.approve(address(locker), 10e6);
        uint256 bought = locker.trade(true, 10e6, 1, block.timestamp + 60);
        locker.token().approve(address(router), bought);
        uint256 priorDollar = dollar.balanceOf(trader);
        router.swap(key, SwapParams(!quoteFirst, -int256(bought),
            quoteFirst ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        assertGt(dollar.balanceOf(trader), priorDollar);
        vm.stopPrank();
        assertEq(locker.token().balanceOf(trader), 0);
        assertEq(manager.balanceOf(trader, uint160(address(locker.token()))), 0);
        assertTrue(NoerraCreationToken(address(locker.token())).launchProtectionActive());
        vm.roll(NoerraCreationToken(address(locker.token())).protectionEndBlock());
        vm.prank(trader);
        router.swap(key, SwapParams(quoteFirst, -int256(100e6),
            quoteFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(true, false), "");
        assertGt(manager.balanceOf(trader, uint160(address(locker.token()))), 20_000_000 ether);
        assertFalse(NoerraCreationToken(address(locker.token())).launchProtectionActive());
    }

    function testPredictedPoolCannotBePreinitializedAndProtectionQuoterHasNoSettlementPath() public {
        NoerraLaunchProtectionHook hook = source.launchProtectionHook();
        NoerraQuoter quoter = source.cashDeployer().protectionQuoter();
        (address predicted, uint160 price,,) = source.quoteSleeping(id, "Sleeping", "SLEEP");
        bool first = predicted < address(dollar);
        PoolKey memory key = PoolKey(Currency.wrap(first ? predicted : address(dollar)),
            Currency.wrap(first ? address(dollar) : predicted), 0, 60, IHooks(address(hook)));
        vm.expectRevert(); manager.initialize(key, price);
        NoerraLockedCreation locker = _launch();
        (uint256 output,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(key, !first, 10e6, ""));
        assertGt(output, 0); assertLe(output, 20_000_000 ether);
        assertEq(locker.token().balanceOf(trader), 0);
        assertEq(manager.balanceOf(trader, uint160(predicted)), 0);
        vm.expectRevert(); quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(key, !first, 100e6, ""));
        vm.expectRevert("Fixed launch hook"); locker.setLaunchProtectionHook(IHooks(address(hook)));
        vm.expectRevert("Source factory only"); hook.register(predicted, address(locker), address(dollar));
        vm.prank(address(source)); vm.expectRevert("Launch protection fixed");
        hook.register(predicted, address(locker), address(dollar));
    }

    function testOracleFreshnessBoundaryAndInvalidRoundsBlockQuoteAndLaunch() public {
        (, uint160 price, int24 lower, int24 upper) = source.quoteSleeping(id, "Sleeping", "SLEEP");
        vm.warp(100_000);
        feed.setRoundData(2, 2000e8, block.timestamp - 7200, block.timestamp - 7200, 2);
        assertEq(source.initialPoolNotional(), 2000e6);
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Oracle freshness"); source.quoteSleeping(id, "Sleeping", "SLEEP");
        vm.prank(human); vm.expectRevert("Oracle freshness");
        source.launchSleeping(id, "Sleeping", "SLEEP", price, lower, upper);
        feed.setRoundData(2, 2000e8, block.timestamp, block.timestamp + 1, 2);
        vm.expectRevert("Oracle freshness"); source.initialPoolNotional();
        feed.setRoundData(2, 2000e8, 1, 0, 2);
        vm.expectRevert("Oracle round"); source.initialPoolNotional();
        feed.setRoundData(2, 0, block.timestamp, block.timestamp, 2);
        vm.expectRevert("Oracle round"); source.initialPoolNotional();
        feed.setRoundData(2, -1, block.timestamp, block.timestamp, 2);
        vm.expectRevert("Oracle round"); source.initialPoolNotional();
        feed.setRoundData(2, 2000e8, block.timestamp, block.timestamp, 1);
        vm.expectRevert("Oracle round"); source.initialPoolNotional();
        feed.setRoundData(0, 2000e8, block.timestamp, block.timestamp, 0);
        vm.expectRevert("Oracle round"); source.initialPoolNotional();
        feed.setRoundData(2, 99, block.timestamp, block.timestamp, 2);
        vm.expectRevert("Oracle price bounds"); source.initialPoolNotional();
        feed.setRoundData(2, type(int256).max, block.timestamp, block.timestamp, 2);
        vm.expectRevert("Oracle price bounds"); source.initialPoolNotional();
        assertEq(address(source.cashLaunches(id)), address(0));
    }

    function _deploySourceForOracle(address feed_, uint32 age_, string memory error_) private returns (NoerraSleepingLaunchpad) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        NoerraSleepingCashDeployer builder = _cashBuilder(predicted);
        if (bytes(error_).length > 0) vm.expectRevert(bytes(error_));
        return new NoerraSleepingLaunchpad(registry, credits, manager, builder, address(0xC1), address(ecosystem),
            NoerraSleepingLaunchpad.BridgePins(address(bridge), address(l1), address(bridge), address(brain), 1_000_000),
            NoerraSleepingLaunchpad.OraclePins(feed_, age_));
    }

    function testOracleConstructorPinsRequireEthereumDecimalsAndBoundedHeartbeat() public {
        feed.setDecimals(18);
        _deploySourceForOracle(address(feed), 7200, "Ethereum ETH USD feed");
        feed.setDecimals(8);
        _deploySourceForOracle(address(feed), 59, "Oracle age bounds");
        _deploySourceForOracle(address(feed), 7201, "Oracle age bounds");
        _deploySourceForOracle(address(0xBAD), 7200, "Ethereum ETH USD feed");
        vm.chainId(8453);
        _deploySourceForOracle(address(feed), 7200, "Ethereum ETH USD feed");
        vm.chainId(1);
        NoerraSleepingLaunchpad fresh = _deploySourceForOracle(address(feed), 60, "");
        assertEq(address(fresh.ethUsdFeed()), address(feed)); assertEq(fresh.oracleMaximumAge(), 60);
    }

    function testTokenChildCanOnlyServeItsImmutableSourceFactory() public {
        NoerraSleepingCashDeployer builder = source.cashDeployer();
        NoerraSleepingTokenDeployer child = builder.tokenDeployer();
        assertEq(builder.tokenDeployer().factory(), address(source));
        vm.expectRevert("Source factory only");
        child.deploy(id, "Forged", "FAKE");
        _launch();
    }

    function testLegacyBaseSleepingEntryCannotReintroduceHalfSupplyOnEthereum() public {
        NoerraDiemCreation legacy = new NoerraDiemCreation(baseManager, NoerraAgentAccount(account), wrapper,
            address(0xC1), address(0xC2), address(this));
        vm.expectRevert("Legacy Base market only");
        legacy.initializeSleeping(IERC20(address(0)), NoerraBackers(address(0)), 500_000_000 ether, 1, 0, 60);
    }

    function testCanonicalLaunchProtectionAllocationsBridgeAndAutomaticExpiry() public {
        NoerraLockedCreation locker = _launch();
        NoerraCreationToken token = NoerraCreationToken(address(locker.token()));
        assertTrue(token.protectionInitialized()); assertTrue(token.launchProtectionActive());
        assertEq(token.protectionStartBlock(), block.number); assertEq(token.protectionEndBlock(), block.number + 10);
        assertFalse(token.launchExempt(human)); assertEq(token.totalSupply(), 1_000_000_000 ether);
        _metadata(); assertEq(token.balanceOf(address(bridge)), 0);
        assertEq(token.balanceOf(address(source.bridgeReserves(id))), 0);
        dollar.mint(trader, 100e6);
        vm.startPrank(trader); dollar.approve(address(locker), 100e6);
        vm.expectRevert(); locker.trade(true, 100e6, 1, block.timestamp + 60);
        uint256 bought = locker.trade(true, 10e6, 1, block.timestamp + 60);
        assertGt(bought, 0); assertLe(bought, token.MAX_LAUNCH_HOLDING());
        token.approve(address(locker), bought); assertGt(locker.trade(false, bought, 1, block.timestamp + 60), 0);
        vm.stopPrank(); vm.roll(token.protectionEndBlock());
        assertFalse(token.launchProtectionActive());
        vm.startPrank(trader); assertGt(locker.trade(true, 80e6, 1, block.timestamp + 60), token.MAX_LAUNCH_HOLDING());
        vm.stopPrank(); assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
