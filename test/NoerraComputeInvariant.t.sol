// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";
import {ComputeTestRegistry} from "./NoerraComputeMarket.t.sol";
import {NoerraComputeMarket} from "../src/agents/NoerraComputeMarket.sol";
import {NoerraAgentCredits} from "../src/agents/NoerraAgents.sol";

contract ComputeSequenceHandler is Test {
    NoerraComputeMarket public market;
    NoerraAgentCredits public credits;
    address[3] public buyers;
    bytes32[3] public agents;
    bytes32[] public orderIds;
    uint256 public first;
    uint256 private receiptNonce;
    uint256 private constant KEY = 0x1234;

    constructor(NoerraComputeMarket m, address[3] memory b, bytes32[3] memory a, uint256 f) {
        market = m; credits = m.credits(); buyers = b; agents = a; first = f;
    }
    function signed(bytes32 hash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        return abi.encodePacked(r, s, v);
    }
    function buy(uint256 who, uint256 count) external {
        if (orderIds.length >= 128) return;
        uint256 day = block.timestamp / 1 days * 1 days;
        bytes32 id = keccak256(abi.encode("order", orderIds.length));
        vm.prank(buyers[who % 3]);
        try market.buy(day, bound(count, 1, 200), id) { orderIds.push(id); } catch {}
    }
    function consume(uint256 which, uint256 count) external {
        if (orderIds.length == 0) return;
        bytes32 id = orderIds[which % orderIds.length];
        bytes32 receipt = keccak256(abi.encode("receipt", ++receiptNonce));
        uint256 units = bound(count, 1, 200);
        try market.consume(id, receipt, units, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", id, receipt, units)))) {} catch {}
    }
    function refund(uint256 who, uint256 which) external {
        if (orderIds.length == 0) return;
        vm.prank(buyers[who % 3]); try market.refund(orderIds[which % orderIds.length]) {} catch {}
    }
    function claim(uint256 day, uint256 which) external {
        // Claims are permissionless but their recipient is the registered agent.
        try market.claim(first + day % 3 * 1 days, agents[which % 3]) {} catch {}
    }
    function redeem(uint256 who, uint256 amount) external {
        address buyer = buyers[who % 3]; uint256 held = credits.balanceOf(buyer);
        if (held == 0) return;
        vm.prank(buyer); credits.redeem(bound(amount, 1, held));
    }
    function advance(uint256 elapsed) external { vm.warp(block.timestamp + bound(elapsed, 1, 6 hours)); }
    function orderCount() external view returns (uint256) { return orderIds.length; }
}

contract NoerraComputeInvariantTest is StdInvariant, Test {
    AgentTestDollar dollar;
    ComputeTestRegistry registry;
    NoerraComputeMarket market;
    NoerraAgentCredits credits;
    ComputeSequenceHandler handler;
    address[3] buyers;
    bytes32[3] agents;
    uint256 first = 100 days;
    uint256 private constant KEY = 0x1234;

    function signed(bytes32 hash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        return abi.encodePacked(r, s, v);
    }
    function setUp() public {
        vm.warp(first); dollar = new AgentTestDollar(); registry = new ComputeTestRegistry();
        market = new NoerraComputeMarket(dollar, registry, vm.addr(KEY), address(0xD1)); credits = market.credits();
        for (uint256 i; i < 3; ++i) {
            agents[i] = keccak256(abi.encode("agent", i)); registry.set(agents[i], address(uint160(0xB0 + i)));
            buyers[i] = address(uint160(0xA0 + i)); dollar.mint(buyers[i], 1e9);
            vm.startPrank(buyers[i]); dollar.approve(address(credits), 1e9); credits.mint(1e9, buyers[i]); credits.approve(address(market), type(uint256).max); vm.stopPrank();
        }
        for (uint256 d; d < 3; ++d) {
            uint256 epoch = first + d * 1 days;
            market.open(epoch, 3000, 137, signed(keccak256(abi.encode(block.chainid, address(market), "capacity", epoch, uint256(3000), uint256(137)))));
            for (uint256 i; i < 3; ++i) {
                vm.prank(registry.accounts(agents[i]));
                market.list(epoch, agents[i], 1000, signed(keccak256(abi.encode(block.chainid, address(market), "listing", epoch, agents[i], uint256(1000)))));
            }
        }
        handler = new ComputeSequenceHandler(market, buyers, agents, first);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buy.selector; selectors[1] = handler.consume.selector; selectors[2] = handler.refund.selector;
        selectors[3] = handler.claim.selector; selectors[4] = handler.redeem.selector; selectors[5] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors)); targetContract(address(handler));
    }
    function invariantCreditsAndCashAlwaysCoverOutstandingLiabilities() public view {
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply());
        uint256 escrow;
        for (uint256 i; i < handler.orderCount(); ++i) { (,,,, uint256 paid) = market.orders(handler.orderIds(i)); escrow += paid; }
        assertEq(credits.balanceOf(address(market)), escrow);
        uint256 sellerLiability;
        for (uint256 d; d < 3; ++d) {
            uint256 epoch = first + d * 1 days; (,,,,, uint256 earnings,) = market.epochs(epoch);
            uint256 claimed;
            for (uint256 i; i < 3; ++i) { (, uint256 got,) = market.listings(epoch, agents[i]); claimed += got; }
            assertLe(claimed, earnings); sellerLiability += earnings - claimed;
        }
        assertEq(dollar.balanceOf(address(market)), sellerLiability);
    }
    function invariantNoCapacityIsSoldOrReservedTwice() public view {
        for (uint256 d; d < 3; ++d) {
            uint256 epoch = first + d * 1 days;
            (uint256 capacity, uint256 listed, uint256 reserved, uint256 consumed,,,) = market.epochs(epoch);
            assertLe(listed, capacity); assertLe(reserved + consumed, listed);
            uint256 actualReserved;
            for (uint256 i; i < handler.orderCount(); ++i) {
                (, uint256 day, uint256 units, uint256 remaining, uint256 paid) = market.orders(handler.orderIds(i));
                assertLe(remaining, units); assertEq(paid, remaining * 137);
                if (day == epoch) actualReserved += remaining;
            }
            assertEq(actualReserved, reserved);
        }
    }
}
