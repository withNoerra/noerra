// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";
import {NoerraComputeMarket} from "../src/agents/NoerraComputeMarket.sol";
import {NoerraAgentCredits, IAgentRegistry} from "../src/agents/NoerraAgents.sol";
contract ComputeTestRegistry is IAgentRegistry {
    mapping(bytes32 => address) public accounts;
    function set(bytes32 id, address account) external { accounts[id] = account; }
}
contract NoerraComputeMarketTest is Test {
    AgentTestDollar dollar; ComputeTestRegistry registry; NoerraComputeMarket market; NoerraAgentCredits credits;
    uint256 key = 0x1234; address buyer = address(0xA1); address sellerA = address(0xB1); address sellerB = address(0xC1); address treasury = address(0xD1);
    bytes32 a = keccak256("agent a"); bytes32 b = keccak256("agent b"); uint256 epoch;
    function signed(bytes32 hash) internal view returns (bytes memory) { (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash))); return abi.encodePacked(r, s, v); }
    function setUp() public {
        vm.warp(2 days); epoch = 3 days; dollar = new AgentTestDollar(); registry = new ComputeTestRegistry(); registry.set(a, sellerA); registry.set(b, sellerB);
        market = new NoerraComputeMarket(dollar, registry, vm.addr(key), treasury); credits = market.credits();
        market.open(epoch, 100, 10000, signed(keccak256(abi.encode(block.chainid, address(market), "capacity", epoch, uint256(100), uint256(10000)))));
        vm.prank(sellerA); market.list(epoch, a, 25, signed(keccak256(abi.encode(block.chainid, address(market), "listing", epoch, a, uint256(25)))));
        vm.prank(sellerB); market.list(epoch, b, 75, signed(keccak256(abi.encode(block.chainid, address(market), "listing", epoch, b, uint256(75)))));
        dollar.mint(buyer, 1e6); vm.startPrank(buyer); dollar.approve(address(credits), 1e6); credits.mint(1e6, buyer); credits.approve(address(market), 1e6); vm.stopPrank(); vm.warp(epoch);
    }
    function testBuyCompletedUsageBackedCashbackAndProRataEarnings() public {
        bytes32 order = keccak256("order"); bytes32 receipt = keccak256("receipt");
        vm.prank(buyer); market.buy(epoch, 100, order);
        market.consume(order, receipt, 100, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", order, receipt, uint256(100)))));
        assertEq(credits.balanceOf(buyer), 100000); assertEq(dollar.balanceOf(address(credits)), credits.totalSupply()); assertEq(dollar.balanceOf(treasury), 500000);
        market.claim(epoch, a); market.claim(epoch, b); assertEq(dollar.balanceOf(sellerA), 100000); assertEq(dollar.balanceOf(sellerB), 300000);
        vm.expectRevert("No earnings"); market.claim(epoch, a);
        vm.expectRevert("Order"); market.consume(order, receipt, 1, "");
    }
    function testUnconsumedCreditsRefundWithoutProvider() public {
        bytes32 order = keccak256("order"); vm.prank(buyer); market.buy(epoch, 100, order);
        vm.prank(buyer); vm.expectRevert("Refund time"); market.refund(order);
        vm.warp(epoch + 1 days + 1 hours); vm.prank(buyer); market.refund(order);
        assertEq(credits.balanceOf(buyer), 1e6); assertEq(dollar.balanceOf(address(credits)), 1e6); assertEq(dollar.balanceOf(treasury), 0);
    }
    function testPartialUsageRefundAndReceiptCannotReplayAcrossOrders() public {
        bytes32 one = keccak256("one"); bytes32 two = keccak256("two"); bytes32 receipt = keccak256("receipt");
        vm.startPrank(buyer); market.buy(epoch, 50, one); market.buy(epoch, 50, two); vm.stopPrank();
        market.consume(one, receipt, 25, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", one, receipt, uint256(25)))));
        vm.expectRevert("Receipt used"); market.consume(two, receipt, 25, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", two, receipt, uint256(25)))));
        vm.warp(epoch + 1 days + 1 hours); vm.prank(buyer); market.refund(one); vm.prank(buyer); market.refund(two);
        assertEq(credits.balanceOf(buyer), 775000); assertEq(dollar.balanceOf(address(credits)), credits.totalSupply());
    }
    function testUnsignedConsumptionAndOversellingRejected() public {
        vm.prank(buyer); vm.expectRevert("Available units"); market.buy(epoch, 101, keccak256("one"));
        vm.prank(buyer); market.buy(epoch, 100, keccak256("one"));
        vm.expectRevert("Consumption evidence"); market.consume(keccak256("one"), keccak256("receipt"), 50, signed(keccak256("fake")));
        assertEq(dollar.balanceOf(treasury), 0); assertEq(credits.balanceOf(buyer), 0);
    }
    function testFuzzCashbackCannotInflateBacking(uint32 units) public {
        units = uint32(bound(units, 1, 100)); bytes32 order = keccak256("order"); bytes32 receipt = keccak256("receipt"); vm.prank(buyer); market.buy(epoch, units, order);
        market.consume(order, receipt, units, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", order, receipt, uint256(units)))));
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply()); assertEq(credits.balanceOf(buyer), 1e6 - uint256(units) * 9000);
    }
    function testCurrentDayCapacityAndLateListingDoNotTakeEarlierEarnings() public {
        bytes32 one = keccak256("early order");
        vm.prank(buyer); market.buy(epoch, 50, one);
        market.consume(one, keccak256("early receipt"), 50, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", one, keccak256("early receipt"), uint256(50)))));
        bytes32 c = keccak256("late agent"); address sellerC = address(0xE1); registry.set(c, sellerC);
        market.open(epoch, 200, 10000, signed(keccak256(abi.encode(block.chainid, address(market), "capacity", epoch, uint256(200), uint256(10000)))));
        vm.prank(sellerC); market.list(epoch, c, 100, signed(keccak256(abi.encode(block.chainid, address(market), "listing", epoch, c, uint256(100)))));
        vm.expectRevert("No earnings"); market.claim(epoch, c);
        bytes32 two = keccak256("late order"); vm.prank(buyer); market.buy(epoch, 50, two);
        market.consume(two, keccak256("late receipt"), 50, signed(keccak256(abi.encode(block.chainid, address(market), "consumed", two, keccak256("late receipt"), uint256(50)))));
        market.claim(epoch,a); market.claim(epoch,b); market.claim(epoch,c);
        assertEq(dollar.balanceOf(sellerA),75000); assertEq(dollar.balanceOf(sellerB),225000); assertEq(dollar.balanceOf(sellerC),100000);
        assertEq(dollar.balanceOf(address(market)),0); assertEq(dollar.balanceOf(address(credits)),credits.totalSupply());
        vm.expectRevert("Capacity"); market.open(epoch, 300, 9999, "");
        vm.expectRevert("Capacity"); market.open(epoch, 200, 10000, "");
    }
    function testOpenCurrentDayButNeverYesterday() public {
        uint256 today=2 days; NoerraComputeMarket fresh=new NoerraComputeMarket(dollar,registry,vm.addr(key),treasury);
        vm.warp(today+1 hours);
        fresh.open(today,10,1,signed(keccak256(abi.encode(block.chainid,address(fresh),"capacity",today,uint256(10),uint256(1)))));
        vm.expectRevert("Current or future UTC day"); fresh.open(today-1 days,10,1,"");
    }
}
