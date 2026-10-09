// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraAccessMarket} from "../src/personal/NoerraAccessMarket.sol";

contract AccessPaymentFixture is ERC20 {
    constructor() ERC20("Local fixture dollar", "FUSD") { _mint(msg.sender, 1e30); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract AccessHostilePaymentFixture is ERC20 {
    bool public taxed;
    bool public blocked;
    bool public reentered;
    bool public callback;
    address public target;
    constructor() ERC20("Hostile test payment", "BAD") { _mint(msg.sender, 1e30); }
    function configure(address m, bool tax, bool blockTransfers, bool callBack) external { target = m; taxed = tax; blocked = blockTransfers; callback = callBack; }
    function _update(address from, address to, uint256 value) internal override {
        if (from == target) {
            require(!blocked, "Blocked payment");
            if (callback) { (bool ok,) = target.call(abi.encodeCall(NoerraAccessMarket.claim, ())); reentered = ok; }
        }
        if (taxed && to == target && value > 0) { super._update(from, address(0), 1); value--; }
        super._update(from, to, value);
    }
}

contract NoerraAccessMarketTest is Test {
    NoerraRevenueCoin coin;
    AccessPaymentFixture usd;
    NoerraAccessMarket market;
    uint256 signer = 123456;
    address provider;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");
    address treasury = makeAddr("treasury");
    uint256 epoch;

    function signature(NoerraAccessMarket.CapacityQuote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, market.quoteDigest(q)); return abi.encodePacked(r, s, v);
    }
    function quote(uint256 start) internal pure returns (NoerraAccessMarket.CapacityQuote memory) {
        return NoerraAccessMarket.CapacityQuote(start, 1000, 1 ether, 250, 1000, keccak256("local bounded provider policy"), 1000);
    }
    function setUp() public {
        vm.warp(10 days + 1);
        provider = vm.addr(signer); coin = new NoerraRevenueCoin(address(this)); usd = new AccessPaymentFixture();
        market = new NoerraAccessMarket(coin, usd, provider, treasury, 500);
        usd.approve(address(market), type(uint256).max);
        for (uint256 i; i < 2; i++) { address owner = i == 0 ? alice : bob; coin.transfer(owner, 1000 ether); vm.startPrank(owner); coin.approve(address(market), type(uint256).max); market.stake(1000 ether); vm.stopPrank(); }
        usd.transfer(buyer, 1e9); vm.prank(buyer); usd.approve(address(market), type(uint256).max);
        epoch = 11 days; NoerraAccessMarket.CapacityQuote memory q = quote(epoch); market.fund(q, signature(q));
    }
    function list() internal {
        vm.prank(alice); market.register(epoch, 100, 540);
        vm.prank(bob); market.register(epoch, 0, 360);
        vm.warp(epoch);
    }
    function testRecurringActivationUsesOwnerTermsAndStopsOnCancelOrExit() public {
        bytes32 policy = quote(epoch).policy;
        vm.prank(alice); market.configureRecurring(100, 100, epoch + 3 days, policy);
        vm.prank(buyer); market.activateRecurring(alice, epoch);
        (uint256 own, uint256 listed,, bool registered) = market.positions(epoch, alice);
        assertTrue(registered); assertEq(own, 100); assertEq(listed, 100);
        vm.expectRevert(); market.activateRecurring(alice, epoch);
        vm.prank(alice); market.cancelRecurring();
        vm.expectRevert(); market.activateRecurring(alice, epoch + 1 days);
        vm.prank(alice); market.configureRecurring(100, 100, epoch + 3 days, policy);
        vm.prank(alice); market.requestExit();
        (,,uint256 until,) = market.recurring(alice); assertEq(until, 0);
        vm.expectRevert(); market.activateRecurring(alice, epoch + 1 days);
        vm.warp(market.exitAt(alice)); vm.prank(alice); market.withdraw();
        assertEq(coin.balanceOf(alice), 1000 ether);
    }
    function testRecurringCannotChangePolicyExtendUnapprovedTermOrActivateLate() public {
        vm.prank(alice); vm.expectRevert(); market.configureRecurring(1, 0, block.timestamp + 32 days, quote(epoch).policy);
        vm.prank(alice); market.configureRecurring(1, 0, epoch + 1 days, keccak256("different policy"));
        vm.expectRevert(); market.activateRecurring(alice, epoch);
        vm.prank(alice); market.configureRecurring(1, 0, epoch + 1 days - 1, quote(epoch).policy);
        vm.expectRevert(); market.activateRecurring(alice, epoch);
        vm.prank(alice); market.configureRecurring(1, 0, epoch + 1 days, quote(epoch).policy);
        vm.warp(epoch); vm.expectRevert(); market.activateRecurring(alice, epoch);
    }
    function testPersonalSubsidyCapIsSignedAndEnforcedAcrossHolders() public {
        NoerraAccessMarket.CapacityQuote memory q = quote(12 days); q.personalCapacity = 10;
        bytes memory sig = signature(q); q.personalCapacity = 11; vm.expectRevert(); market.fund(q, sig);
        q.personalCapacity = 10; market.fund(q, sig);
        vm.prank(alice); market.register(q.start, 6, 20);
        vm.prank(bob); vm.expectRevert(); market.register(q.start, 5, 20);
        vm.prank(bob); market.register(q.start, 4, 20);
        assertEq(market.epochState(q.start).personalGranted, 10);
        q = quote(13 days); q.personalCapacity = q.capacity + 1;
        sig = signature(q); vm.expectRevert(); market.fund(q, sig);
    }
    function testRecurringBatchIsAtomicAndCannotAllocateAgainstMissingCapacity() public {
        vm.prank(alice); market.configureRecurring(10, 20, epoch + 2 days, quote(epoch).policy);
        address[] memory owners = new address[](2); owners[0] = alice; owners[1] = bob;
        vm.expectRevert(); market.activateRecurringBatch(owners, epoch);
        (,,,bool registered) = market.positions(epoch, alice); assertFalse(registered);
        vm.prank(bob); market.configureRecurring(0, 20, epoch + 2 days, quote(epoch).policy);
        market.activateRecurringBatch(owners, epoch); assertEq(market.epochState(epoch).listed, 40);
        vm.expectRevert(); market.activateRecurring(alice, epoch + 1 days);
    }
    function testGroupedClaimPaysOnceAcrossDaysAndPreservesDust() public {
        list(); uint256 id = buy(100); used(id, 100, keccak256("grouped claim"));
        uint256[] memory days_ = new uint256[](3); days_[0] = epoch; days_[1] = epoch; days_[2] = epoch - 1 days;
        uint256 expected = market.earned(epoch, alice);
        vm.prank(alice); market.collectAndClaim(days_); assertEq(usd.balanceOf(alice), expected);
        vm.prank(alice); market.collectAndClaim(days_); assertEq(usd.balanceOf(alice), expected);
        assertGe(usd.balanceOf(address(market)), market.paymentLiability());
        vm.expectRevert(); market.collectAndClaim(new uint256[](32));
    }
    function testRecurringCannotPreLockAllFutureFundedDays() public {
        NoerraAccessMarket.CapacityQuote memory q = quote(epoch + 1 days); market.fund(q, signature(q));
        vm.prank(alice); market.configureRecurring(10, 20, epoch + 30 days, q.policy);
        vm.expectRevert(); market.activateRecurring(alice, epoch + 1 days);
        market.activateRecurring(alice, epoch);
        vm.prank(alice); market.requestExit(); assertEq(market.exitAt(alice), epoch + 1 days + 1 hours);
        vm.warp(epoch); vm.expectRevert(); market.activateRecurring(alice, epoch + 1 days);
    }
    function buy(uint256 amount) internal returns (uint256) { vm.prank(buyer); return market.buy(epoch, amount, amount * 1000, epoch + 1 days - 1); }
    function used(uint256 id, uint256 units, bytes32 receipt) internal { vm.prank(provider); market.consume(id, units, receipt); }
    function testPurchaseEscrowsAndFulfillmentPaysSixtyForty() public {
        list(); uint256 id = buy(100);
        assertEq(market.earned(epoch, alice), 0); assertEq(market.earned(epoch, bob), 0);
        used(id, 100, keccak256("fulfilled"));
        assertApproxEqAbs(market.earned(epoch, alice), 42000, 1); assertApproxEqAbs(market.earned(epoch, bob), 28000, 1);
        assertEq(market.balances(provider), 25000); assertEq(market.balances(treasury), 5000);
        vm.startPrank(alice); market.collectEarnings(epoch); market.claim(); market.collectEarnings(epoch); market.claim(); vm.stopPrank();
        assertApproxEqAbs(usd.balanceOf(alice), 42000, 1);
    }
    function testComputeClaimPreservesProviderSponsorRefund() public {
        NoerraAccessMarket.CapacityQuote memory q = quote(12 days);
        usd.transfer(provider, 250000);
        vm.startPrank(provider); usd.approve(address(market), 250000); vm.stopPrank();
        bytes memory sig = signature(q); vm.prank(provider); market.fund(q, sig);
        list(); uint256 id = buy(100); used(id, 100, keccak256("compute claim"));
        assertEq(market.computeEarnings(), 25000);
        vm.warp(13 days + 1 hours); market.close(12 days);
        assertEq(market.balances(provider), 275000);
        vm.prank(provider); market.claimCompute();
        assertEq(usd.balanceOf(provider), 25000);
        assertEq(market.balances(provider), 250000);
        assertEq(market.computeEarnings(), 0);
        vm.prank(provider); market.claimCompute(); assertEq(usd.balanceOf(provider), 25000);
        vm.prank(provider); market.claim(); assertEq(usd.balanceOf(provider), 275000);
        assertEq(usd.balanceOf(address(market)), market.paymentLiability());
    }
    function testComputeClaimAuthorityAndRegularClaimCannotDoublePay() public {
        list(); uint256 id = buy(10); used(id, 10, keccak256("ordinary claim"));
        vm.prank(buyer); vm.expectRevert(); market.claimCompute();
        vm.prank(provider); market.claim(); assertEq(usd.balanceOf(provider), 2500);
        assertEq(market.computeEarnings(), 0);
        vm.prank(provider); market.claimCompute(); assertEq(usd.balanceOf(provider), 2500);
    }
    function testCapacityIsNotDoubleSpentOrOverSold() public {
        list(); uint256 id = buy(900);
        vm.prank(buyer); vm.expectRevert(); market.buy(epoch, 1, 1000, epoch + 100);
        used(id, 900, keccak256("all"));
        vm.prank(provider); vm.expectRevert(); market.consume(id, 1, keccak256("over"));
        vm.prank(provider); vm.expectRevert(); market.consumeOwned(epoch, alice, 101, keccak256("over-owned"));
        vm.prank(provider); market.consumeOwned(epoch, alice, 100, keccak256("owned"));
        vm.prank(provider); vm.expectRevert(); market.consumeOwned(epoch, alice, 1, keccak256("double-owned"));
    }
    function testLateListingsCannotCaptureRevenue() public {
        list(); uint256 id = buy(10); used(id, 10, keccak256("used"));
        vm.prank(buyer); vm.expectRevert(); market.register(epoch, 0, 1);
        vm.prank(alice); vm.expectRevert(); market.register(epoch, 0, 1);
    }
    function testProviderReceiptsRequireAuthorityAndCannotReplay() public {
        list(); uint256 id = buy(10);
        vm.prank(buyer); vm.expectRevert(); market.consume(id, 10, keccak256("used"));
        used(id, 5, keccak256("used"));
        vm.prank(provider); vm.expectRevert(); market.consume(id, 5, keccak256("used"));
        vm.prank(provider); vm.expectRevert(); market.consumeOwned(epoch, alice, 1, keccak256("used"));
    }
    function testUnfulfilledPaymentRemainsRefundableAfterRestartEquivalentState() public {
        list(); uint256 id = buy(100); used(id, 25, keccak256("partial"));
        vm.prank(buyer); vm.expectRevert(); market.refund(id);
        vm.warp(epoch + 1 days + 1 hours); vm.startPrank(buyer); market.refund(id); market.claim(); vm.expectRevert(); market.refund(id); vm.stopPrank();
        assertEq(usd.balanceOf(buyer), 1e9 - 25000);
        vm.prank(provider); vm.expectRevert(); market.consume(id, 1, keccak256("too late"));
    }
    function testPrincipalLocksThroughListedWindowThenExitsWithoutProviderApproval() public {
        list(); vm.startPrank(alice); market.requestExit(); vm.expectRevert(); market.withdraw(); vm.stopPrank();
        assertEq(market.exitAt(alice), epoch + 1 days + 1 hours);
        vm.warp(epoch + 1 days + 1 hours); vm.prank(alice); market.withdraw(); assertEq(coin.balanceOf(alice), 1000 ether);
    }
    function testFreshStakeExitRequiresOneDayAndCannotRegisterWhileExiting() public {
        vm.prank(alice); market.requestExit(); vm.prank(alice); vm.expectRevert(); market.register(epoch, 1, 1);
        vm.warp(block.timestamp + 1 days); vm.prank(alice); market.withdraw(); assertEq(market.staked(alice), 0);
    }
    function testFundingRequiresProviderQuoteAndExactCapacityCoverage() public {
        NoerraAccessMarket.CapacityQuote memory q = quote(12 days); bytes memory sig = signature(q); q.capacity++;
        vm.expectRevert(); market.fund(q, sig); q.capacity--; market.fund(q, sig);
        vm.expectRevert(); market.fund(q, sig);
        vm.prank(alice); vm.expectRevert(); market.register(epoch, 1001, 0);
        vm.prank(alice); market.register(epoch, 1000, 0);
        vm.prank(bob); vm.expectRevert(); market.register(epoch, 1, 0);
    }
    function testMaxCostDeadlineAndEpochChecks() public {
        vm.prank(alice); market.register(epoch, 0, 100);
        vm.prank(buyer); vm.expectRevert(); market.buy(epoch, 10, 10000, epoch);
        vm.warp(epoch); vm.prank(buyer); vm.expectRevert(); market.buy(epoch, 10, 9999, epoch + 100);
        vm.warp(epoch + 1); vm.prank(buyer); vm.expectRevert(); market.buy(epoch, 10, 10000, epoch);
    }
    function testFuzzConservation(uint256 purchased, uint256 consumed, uint256 owned) public {
        purchased = bound(purchased, 1, 900); consumed = bound(consumed, 0, purchased); owned = bound(owned, 0, 100);
        list(); uint256 id = buy(purchased); if (consumed != 0) used(id, consumed, keccak256("buyer"));
        if (owned != 0) { vm.prank(provider); market.consumeOwned(epoch, alice, owned, keccak256("owner")); }
        vm.warp(epoch + 1 days + 1 hours); market.close(epoch);
        vm.prank(buyer); market.refund(id);
        address[6] memory owners = [address(this), alice, bob, buyer, provider, treasury];
        for (uint256 i; i < owners.length; i++) { vm.startPrank(owners[i]); if (owners[i] == alice || owners[i] == bob) market.collectEarnings(epoch); market.claim(); vm.stopPrank(); }
        assertEq(usd.balanceOf(address(market)), market.paymentLiability());
        assertLe(market.paymentLiability(), 2); // pro-rata integer dust stays reserved
        assertEq(coin.balanceOf(address(market)), market.totalStaked());
    }
    function testBatchSettlesPaidAndOwnedAndConservesLiabilities() public {
        list(); uint256 id = buy(100);
        NoerraAccessMarket.Charge[] memory charges = new NoerraAccessMarket.Charge[](2);
        charges[0] = NoerraAccessMarket.Charge(id, epoch, buyer, 10, keccak256("batch-paid"));
        charges[1] = NoerraAccessMarket.Charge(0, epoch, alice, 20, keccak256("batch-owned"));
        vm.prank(provider); market.consumeBatch(charges);
        assertEq(market.receiptRecords(charges[0].receipt), keccak256(abi.encode(id, uint256(10))));
        assertEq(market.receiptRecords(charges[1].receipt), keccak256(abi.encode(epoch, alice, uint256(20))));
        assertEq(market.balances(provider), 7500);
        assertEq(market.balances(treasury), 500);
        assertEq(usd.balanceOf(address(market)), market.paymentLiability());
    }
    function testBatchInvalidOrDuplicateChargeRevertsEntireBatch() public {
        list(); uint256 id = buy(100);
        NoerraAccessMarket.Charge[] memory charges = new NoerraAccessMarket.Charge[](2);
        charges[0] = NoerraAccessMarket.Charge(id, epoch, buyer, 10, keccak256("batch-atomic"));
        charges[1] = charges[0];
        vm.prank(provider); vm.expectRevert(); market.consumeBatch(charges);
        assertFalse(market.receipts(charges[0].receipt)); assertEq(market.balances(provider), 0);
        charges[1].receipt = keccak256("different"); charges[1].owner = alice;
        vm.prank(provider); vm.expectRevert(); market.consumeBatch(charges);
        assertFalse(market.receipts(charges[0].receipt));
    }
    function testBatchAuthorityAndSizeBound() public {
        NoerraAccessMarket.Charge[] memory empty = new NoerraAccessMarket.Charge[](0);
        vm.prank(buyer); vm.expectRevert(); market.consumeBatch(empty);
        vm.prank(provider); vm.expectRevert(); market.consumeBatch(empty);
        NoerraAccessMarket.Charge[] memory oversized = new NoerraAccessMarket.Charge[](51);
        vm.prank(provider); vm.expectRevert(); market.consumeBatch(oversized);
    }
    function testQuoteCannotReplayOnAnotherMarketOrChain() public {
        NoerraAccessMarket.CapacityQuote memory q = quote(12 days); bytes memory sig = signature(q);
        NoerraAccessMarket other = new NoerraAccessMarket(coin, usd, provider, treasury, 500);
        usd.approve(address(other), type(uint256).max);
        vm.expectRevert(); other.fund(q, sig);
        vm.chainId(block.chainid + 1); vm.expectRevert(); market.fund(q, sig);
    }
    function testReceiptGraceBoundarySeparatesUsageAndRefundExactly() public {
        list(); uint256 id = buy(100);
        vm.warp(epoch + 1 days + 1 hours - 1); used(id, 25, keccak256("last second"));
        vm.prank(buyer); vm.expectRevert(); market.refund(id);
        vm.warp(epoch + 1 days + 1 hours);
        vm.prank(provider); vm.expectRevert(); market.consume(id, 1, keccak256("exact expiry"));
        vm.prank(buyer); market.refund(id); assertEq(market.balances(buyer), 75000);
    }
    function testFullFiftyChargeBatchAndSponsorCloseCannotReplay() public {
        list(); uint256 id = buy(100);
        NoerraAccessMarket.Charge[] memory charges = new NoerraAccessMarket.Charge[](50);
        for (uint256 i; i < 50; ++i) charges[i] = NoerraAccessMarket.Charge(id, epoch, buyer, 1, keccak256(abi.encode(i)));
        vm.prank(provider); market.consumeBatch(charges);
        (, , , uint256 spent, ) = market.orders(id); assertEq(spent, 50);
        vm.warp(epoch + 1 days + 1 hours); market.close(epoch);
        uint256 credit = market.balances(address(this)); vm.expectRevert(); market.close(epoch);
        assertEq(market.balances(address(this)), credit);
    }
    function testTaxedFundingRevertsWithoutCreatingCapacityOrLiability() public {
        AccessHostilePaymentFixture bad = new AccessHostilePaymentFixture();
        NoerraAccessMarket m = new NoerraAccessMarket(coin, bad, provider, address(bad), 500);
        bad.approve(address(m), type(uint256).max); bad.configure(address(m), true, false, false);
        NoerraAccessMarket.CapacityQuote memory q = quote(epoch);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, m.quoteDigest(q));
        vm.expectRevert(); m.fund(q, abi.encodePacked(r, s, v));
        assertEq(m.paymentLiability(), 0); assertEq(bad.balanceOf(address(m)), 0);
        assertEq(m.epochState(epoch).sponsor, address(0));
    }
    function testBlockedPaymentAndReentrantClaimCannotLoseOrDrainBalances() public {
        AccessHostilePaymentFixture bad = new AccessHostilePaymentFixture();
        NoerraAccessMarket m = new NoerraAccessMarket(coin, bad, provider, address(bad), 500);
        bad.approve(address(m), type(uint256).max); bad.configure(address(m), false, false, false);
        NoerraAccessMarket.CapacityQuote memory q = quote(epoch);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, m.quoteDigest(q)); m.fund(q, abi.encodePacked(r, s, v));
        coin.transfer(buyer, 10 ether); bad.transfer(buyer, 10000);
        vm.startPrank(buyer); coin.approve(address(m), type(uint256).max); m.stake(10 ether);
        m.register(epoch, 0, 10); bad.approve(address(m), 10000); vm.stopPrank(); vm.warp(epoch);
        vm.prank(buyer); uint256 id = m.buy(epoch, 10, 10000, epoch + 1);
        vm.prank(provider); m.consume(id, 10, keccak256("hostile payment charge"));
        uint256 liability = m.paymentLiability(); uint256 due = m.balances(provider);
        bad.configure(address(m), false, true, false);
        vm.prank(provider); vm.expectRevert(); m.claim();
        assertEq(m.balances(provider), due); assertEq(m.paymentLiability(), liability);
        bad.configure(address(m), false, false, true); vm.prank(provider); m.claim();
        assertFalse(bad.reentered()); assertEq(m.balances(address(bad)), 500);
        assertEq(bad.balanceOf(provider), due); assertEq(m.paymentLiability(), liability - due);
    }
}
