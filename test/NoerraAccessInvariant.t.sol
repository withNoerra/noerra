// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NoerraAccessMarket} from "../src/personal/NoerraAccessMarket.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {AccessPaymentFixture} from "./NoerraAccessMarket.t.sol";

contract AccessSequenceHandler is Test {
    NoerraAccessMarket public market;
    NoerraRevenueCoin public coin;
    address public provider;
    address[4] public actors;
    uint256 public first;
    uint256 public receiptNonce;

    constructor(NoerraAccessMarket m, NoerraRevenueCoin c, address p, address[4] memory a, uint256 start) {
        market = m; coin = c; provider = p; actors = a; first = start;
    }
    function buy(uint256 who, uint256 count) external {
        if (market.nextOrder() > 128) return;
        vm.prank(actors[2 + who % 2]);
        try market.buy(block.timestamp / 1 days * 1 days, bound(count, 1, 900), 900000, block.timestamp + 60) {} catch {}
    }
    function consume(uint256 selected, uint256 count) external {
        uint256 id = bound(selected, 1, market.nextOrder());
        vm.prank(provider);
        try market.consume(id, bound(count, 1, 900), keccak256(abi.encode(++receiptNonce))) {} catch {}
    }
    function consumeOwned(uint256 who, uint256 day, uint256 count) external {
        vm.prank(provider);
        try market.consumeOwned(first + day % 5 * 1 days, actors[who % 2], bound(count, 1, 100), keccak256(abi.encode(++receiptNonce))) {} catch {}
    }
    function advance(uint256 elapsed) external { vm.warp(block.timestamp + bound(elapsed, 1, 1 days)); }
    function refund(uint256 who, uint256 selected) external {
        vm.prank(actors[who % 4]);
        try market.refund(bound(selected, 1, market.nextOrder())) {} catch {}
    }
    function collect(uint256 who, uint256 day) external {
        vm.prank(actors[who % 4]); market.collectEarnings(first + day % 5 * 1 days);
    }
    function claim(uint256 who) external { vm.prank(actors[who % 4]); market.claim(); }
    function claimCompute() external { vm.prank(provider); market.claimCompute(); }
    function close(uint256 day) external { try market.close(first + day % 5 * 1 days) {} catch {} }
    function requestExit(uint256 who) external { vm.prank(actors[who % 4]); try market.requestExit() {} catch {} }
    function withdraw(uint256 who) external { vm.prank(actors[who % 4]); try market.withdraw() {} catch {} }
    function restake(uint256 who, uint256 amount) external {
        address actor = actors[who % 4]; uint256 balance = coin.balanceOf(actor);
        if (balance == 0) return;
        vm.prank(actor); try market.stake(bound(amount, 1, balance)) {} catch {}
    }
}

contract NoerraAccessInvariantTest is StdInvariant, Test {
    NoerraRevenueCoin coin;
    AccessPaymentFixture payment;
    NoerraAccessMarket market;
    AccessSequenceHandler handler;
    address provider;
    address treasury = makeAddr("invariant treasury");
    address[4] actors;
    uint256 first;

    function setUp() public {
        vm.warp(100 days + 1);
        provider = vm.addr(123456);
        coin = new NoerraRevenueCoin(address(this)); payment = new AccessPaymentFixture();
        market = new NoerraAccessMarket(coin, payment, provider, treasury, 500);
        payment.approve(address(market), type(uint256).max);
        for (uint256 i; i < 4; ++i) {
            address actor = makeAddr(string(abi.encodePacked("sequence actor", i))); actors[i] = actor;
            coin.transfer(actor, 1000 ether); payment.transfer(actor, 1e9);
            vm.startPrank(actor); coin.approve(address(market), type(uint256).max);
            payment.approve(address(market), type(uint256).max); market.stake(1000 ether); vm.stopPrank();
        }
        first = 101 days;
        for (uint256 i; i < 5; ++i) {
            uint256 day = first + i * 1 days;
            NoerraAccessMarket.CapacityQuote memory q = NoerraAccessMarket.CapacityQuote(day, 1000, 1 ether, 250, 1000, keccak256("synthetic invariant policy"), 1000);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(123456, market.quoteDigest(q));
            market.fund(q, abi.encodePacked(r, s, v));
            vm.prank(actors[0]); market.register(day, 100, 540);
            vm.prank(actors[1]); market.register(day, 0, 360);
        }
        handler = new AccessSequenceHandler(market, coin, provider, actors, first);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.buy.selector; selectors[1] = handler.consume.selector;
        selectors[2] = handler.consumeOwned.selector; selectors[3] = handler.advance.selector;
        selectors[4] = handler.refund.selector; selectors[5] = handler.collect.selector;
        selectors[6] = handler.claim.selector; selectors[7] = handler.close.selector;
        selectors[8] = handler.requestExit.selector; selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.restake.selector;
        selectors[11] = handler.claimCompute.selector;
        targetSelector(FuzzSelector(address(handler), selectors)); targetContract(address(handler));
    }
    function invariantPrincipalAndCashAlwaysCoverLiabilities() public view {
        assertEq(coin.balanceOf(address(market)), market.totalStaked());
        assertEq(payment.balanceOf(address(market)), market.paymentLiability());
        assertLe(market.computeEarnings(), market.balances(provider));
        uint256 total; for (uint256 i; i < 4; ++i) total += market.staked(actors[i]);
        assertEq(total, market.totalStaked());
    }
    function invariantCapacityAndOrdersCannotBeDoubleSpent() public view {
        for (uint256 i; i < 5; ++i) {
            NoerraAccessMarket.Epoch memory e = market.epochState(first + i * 1 days);
            assertLe(e.granted, e.capacity); assertLe(e.sold, e.listed); assertLe(e.used, e.sold);
            assertLe(e.ownerUsed, e.granted - e.listed);
        }
        for (uint256 id = 1; id < market.nextOrder(); ++id) {
            (, , uint256 units, uint256 used, ) = market.orders(id); assertLe(used, units);
        }
    }
    function invariantEveryReservedDollarHasAnOwnerOrBoundedDust() public view {
        uint256 owed = market.balances(address(this)) + market.balances(provider) + market.balances(treasury);
        for (uint256 i; i < 4; ++i) owed += market.balances(actors[i]);
        for (uint256 i; i < 5; ++i) {
            uint256 day = first + i * 1 days; NoerraAccessMarket.Epoch memory e = market.epochState(day);
            if (!e.closed) owed += e.sponsorCredit + (e.capacity - e.used - e.ownerUsed) * e.computePrice;
            owed += market.earned(day, actors[0]) + market.earned(day, actors[1]);
        }
        for (uint256 id = 1; id < market.nextOrder(); ++id) {
            (, uint256 day, uint256 units, uint256 used, bool refunded) = market.orders(id);
            if (!refunded) owed += (units - used) * market.epochState(day).retailPrice;
        }
        assertGe(market.paymentLiability(), owed);
        assertLe(market.paymentLiability() - owed, 10);
    }
}
