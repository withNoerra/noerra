// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraAgentRegistry, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {NoerraEthCheckout, INoerraExactOutputRouter} from "../src/agents/NoerraEthCheckout.sol";
import {LaunchDollar} from "./NoerraLaunchpad.t.sol";

contract CheckoutRouterFixture is INoerraExactOutputRouter {
    address public immutable WETH9;
    LaunchDollar dollar;
    uint256 public price = 0.01 ether;
    bool public badOutput;
    bool public keepRefund;

    constructor(address weth_, LaunchDollar dollar_) {
        WETH9 = weth_;
        dollar = dollar_;
    }
    receive() external payable {}

    function configure(uint256 price_, bool bad, bool keep) external {
        price = price_;
        badOutput = bad;
        keepRefund = keep;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256) {
        require(
            p.tokenIn == WETH9 && p.tokenOut == address(dollar) && p.fee == 500 && p.sqrtPriceLimitX96 == 0,
            "Fixed path"
        );
        require(msg.value == p.amountInMaximum && price <= p.amountInMaximum, "Too much requested");
        dollar.mint(p.recipient, badOutput ? p.amountOut - 1 : p.amountOut);
        (bool ok,) = address(0xFEE).call{value: price}("");
        require(ok);
        return price;
    }

    function refundETH() external payable {
        if (keepRefund) return;
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }
}

contract CheckoutQuoterFixture {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactOutputSingle(Params calldata) external pure returns (uint256, uint160, uint32, uint256) {
        return (0.01 ether, 0, 0, 100000);
    }
}

contract NoerraEthCheckoutTest is Test {
    NoerraAgentRegistry registry;
    NoerraEthCheckout checkout;
    CheckoutRouterFixture router;
    LaunchDollar dollar;
    address human = address(0xA11CE);
    address account;
    bytes32 id;

    function setUp() public {
        dollar = new LaunchDollar();
        LaunchDollar weth = new LaunchDollar();
        registry = new NoerraAgentRegistry(dollar, IAgentRecoveryVerifier(address(0)));
        router = new CheckoutRouterFixture(address(weth), dollar);
        checkout = new NoerraEthCheckout(registry, router, address(weth));
        vm.prank(human);
        (id, account) = registry.create(human, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        vm.deal(human, 10 ether);
    }

    function testFuzzExactBudgetAndEthRefund(uint256 maximum, uint256 dollars) public {
        maximum = bound(maximum, 0.01 ether, 10 ether);
        dollars = bound(dollars, 1e6, 100_000e6);
        uint256 before = human.balance;
        vm.prank(human);
        (uint256 spent, uint256 refunded) = checkout.fund{value: maximum}(id, dollars, block.timestamp + 60);
        assertEq(spent, 0.01 ether);
        assertEq(refunded, maximum - spent);
        assertEq(human.balance, before - spent);
        assertEq(dollar.balanceOf(account), dollars);
        assertEq(address(checkout).balance, 0);
        assertEq(dollar.balanceOf(address(checkout)), 0);
    }

    function testSlippageDeadlineAndOwnerFailClosed() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert("Agent human only");
        checkout.fund{value: 0.1 ether}(id, 10e6, block.timestamp + 60);
        vm.startPrank(human);
        vm.expectRevert("Fresh deadline");
        checkout.fund{value: 0.1 ether}(id, 10e6, block.timestamp + 301);
        vm.expectRevert("Too much requested");
        checkout.fund{value: 0.001 ether}(id, 10e6, block.timestamp + 60);
        vm.stopPrank();
        assertEq(checkout.operationNonce(), 0);
    }

    function testMissingOutputOrRefundRollsBackSourceBudget() public {
        router.configure(0.01 ether, true, false);
        vm.prank(human);
        vm.expectRevert("Exact purchased budget");
        checkout.fund{value: 0.1 ether}(id, 10e6, block.timestamp + 60);
        router.configure(0.01 ether, false, true);
        vm.prank(human);
        vm.expectRevert("Complete router refund");
        checkout.fund{value: 0.1 ether}(id, 10e6, block.timestamp + 60);
        assertEq(dollar.balanceOf(account), 0);
        assertEq(human.balance, 10 ether);
        assertEq(checkout.operationNonce(), 0);
    }

    function testForcedCheckoutDustIsNotAnotherOwnersRefund() public {
        vm.deal(address(checkout), 1 ether);
        vm.deal(address(router), 0.2 ether);
        vm.prank(human);
        (, uint256 refund) = checkout.fund{value: 0.1 ether}(id, 10e6, block.timestamp + 60);
        assertEq(refund, 0.29 ether);
        assertEq(address(checkout).balance, 1 ether);
        assertEq(dollar.balanceOf(account), 10e6);
    }

    function testUnsolicitedEthRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(checkout).call{value: 1}("");
        assertFalse(ok);
    }
}
