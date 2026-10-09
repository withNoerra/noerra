// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NativeComputeTreasury, INativeComputeRouter} from "../src/personal/NativeComputeTreasury.sol";

contract NativeTokenFixture {
    mapping(address=>uint256) public balanceOf;
    function mint(address who,uint256 amount) external {balanceOf[who]+=amount;}
}
contract NativeRouterFixture {
    uint256 public spend;
    bool public shortPay;
    bool public skipRefund;
    address public reenter;
    function configure(uint256 amount,bool short_,bool skip_,address target) external {spend=amount;shortPay=short_;skipRefund=skip_;reenter=target;}
    function exactOutputSingle(INativeComputeRouter.ExactOutputSingleParams calldata p) external payable returns(uint256) {
        require(block.timestamp<=p.deadline && spend<=p.amountInMaximum);
        require(p.tokenIn==0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 && p.tokenOut==0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 && p.fee==500 && p.sqrtPriceLimitX96==0);
        if(reenter!=address(0)){(bool reentryOk,)=reenter.call(abi.encodeCall(NativeComputeTreasury.convertCompute,(p.amountOut,spend,p.deadline)));require(!reentryOk);}
        NativeTokenFixture(p.tokenOut).mint(p.recipient,shortPay?p.amountOut-1:p.amountOut);
        (bool ok,)=address(0xdead).call{value:spend}("");require(ok);return spend;
    }
    function refundETH() external {if(!skipRefund){(bool ok,)=msg.sender.call{value:address(this).balance}("");require(ok);}}
}
contract NativeComputeTreasuryTest is Test {
    NativeComputeTreasury treasury;
    address vault=address(0x123);
    address operator=address(0x456);
    function setUp() public {
        vm.etch(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,address(new NativeTokenFixture()).code);
        vm.etch(0xE592427A0AEce92De3Edee1F18E0157C05861564,address(new NativeRouterFixture()).code);
        treasury=new NativeComputeTreasury(vault,operator,0.02 ether);
        vm.deal(vault,1 ether);vm.prank(vault);(bool ok,)=address(treasury).call{value:1 ether}("");assertTrue(ok);
        router().configure(0.2 ether,false,false,address(0));
    }
    function router() internal pure returns(NativeRouterFixture){return NativeRouterFixture(0xE592427A0AEce92De3Edee1F18E0157C05861564);}
    function testExactOutputRefundAndReserve() public {
        vm.prank(operator);treasury.convertCompute(600e6,0.3 ether,block.timestamp+300);
        assertEq(address(treasury).balance,0.8 ether);assertEq(treasury.earnedWei(),0.8 ether);assertEq(treasury.convertedWei(),0.2 ether);
        assertEq(treasury.USDC().balanceOf(operator),600e6);assertEq(address(router()).balance,0);
    }
    function testUntrustedSenderAndOperatorRejected() public {
        vm.deal(address(this),1 ether);(bool ok,)=address(treasury).call{value:1}("");assertFalse(ok);
        vm.expectRevert();treasury.convertCompute(600e6,0.3 ether,block.timestamp+300);
    }
    function testReserveExpiryAndExcessSpendRejected() public {
        vm.startPrank(operator);
        vm.expectRevert();treasury.convertCompute(600e6,0.99 ether,block.timestamp+300);
        vm.expectRevert();treasury.convertCompute(600e6,0.3 ether,block.timestamp+301);
        vm.warp(1000);vm.expectRevert();treasury.convertCompute(600e6,0.3 ether,999);
        vm.expectRevert();treasury.convertCompute(600e6,0.1 ether,block.timestamp+300);vm.stopPrank();
        assertEq(treasury.earnedWei(),1 ether);
    }
    function testMissingRefundAndUnderpaymentRollBack() public {
        for(uint256 i;i<2;i++){
            router().configure(0.2 ether,i==0,i==1,address(0));
            vm.prank(operator);vm.expectRevert();treasury.convertCompute(600e6,0.3 ether,block.timestamp+300);
            assertEq(treasury.earnedWei(),1 ether);assertEq(address(treasury).balance,1 ether);assertEq(treasury.USDC().balanceOf(operator),0);
        }
    }
    function testForcedEthDoesNotGrantSpendingAuthority() public {
        vm.deal(address(treasury),10 ether);vm.prank(operator);vm.expectRevert();treasury.convertCompute(600e6,2 ether,block.timestamp+300);
    }
    function testRouterReentryCannotConvertAgain() public {
        router().configure(0.2 ether,false,false,address(treasury));vm.prank(operator);treasury.convertCompute(600e6,0.3 ether,block.timestamp+300);
        assertEq(treasury.convertedWei(),0.2 ether);
    }
    function testFuzzAccounting(uint96 input) public {
        uint256 spent=bound(input,1,0.98 ether);router().configure(spent,false,false,address(0));vm.prank(operator);treasury.convertCompute(1e6,spent,block.timestamp+300);
        assertEq(treasury.earnedWei()+treasury.convertedWei(),1 ether);assertGe(treasury.earnedWei(),treasury.reserveWei());
    }
}
