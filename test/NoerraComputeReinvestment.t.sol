// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraComputeReinvestment, IReinvestmentRouter, IReinvestmentPool} from "../src/agents/NoerraComputeReinvestment.sol";
import {NoerraDiem, IVeniceDiem} from "../src/agents/NoerraDiem.sol";
import {SyntheticDiem, SyntheticDiemRegistry, SyntheticBackingReader} from "./NoerraDiem.t.sol";
import {LaunchDollar} from "./NoerraLaunchpad.t.sol";
contract ReinvestmentFactory {
    mapping(bytes32=>address) public pools;
    function set(address a,address b,uint24 fee,address pool) external { pools[keccak256(abi.encode(a,b,fee))]=pool; }
    function getPool(address a,address b,uint24 fee) external view returns(address){return pools[keccak256(abi.encode(a,b,fee))];}
}
contract ReinvestmentPool {
    address public token0; address public token1; uint24 public fee; address public factory;
    int56 public difference; bool public unavailable;
    constructor(address a,address b,uint24 f,address maker){token0=a;token1=b;fee=f;factory=maker;}
    function set(int56 delta,bool fail) external {difference=delta;unavailable=fail;}
    function observe(uint32[] calldata times) external view returns(int56[] memory ticks,uint160[] memory secondsPerLiquidity){
        require(!unavailable && times.length==2 && times[0]==1800 && times[1]==0,"No history");
        ticks=new int56[](2);ticks[1]=difference;secondsPerLiquidity=new uint160[](2);
    }
}
contract ReinvestmentRouter {
    LaunchDollar public dollar; SyntheticDiem public diem; uint256 public numerator=100; bool public shortDelivery;
    constructor(LaunchDollar d,SyntheticDiem brain){dollar=d;diem=brain;}
    function set(uint256 n,bool short_) external {numerator=n;shortDelivery=short_;}
    function exactInput(IReinvestmentRouter.ExactInputParams calldata p) external payable returns(uint256){
        dollar.transferFrom(msg.sender,address(this),p.amountIn);
        uint256 output=p.amountIn*numerator/100;
        diem.mint(p.recipient,shortDelivery?0:output);return output;
    }
}
contract NoerraComputeReinvestmentTest is Test {
    LaunchDollar dollar;SyntheticDiem diem;NoerraDiem wrapper;NoerraComputeReinvestment treasury;
    ReinvestmentPool first;ReinvestmentPool second;ReinvestmentRouter router;
    bytes32 id=bytes32(uint256(1));address hosting=address(0x123);address intermediate=address(0x456);
    function setUp() public {
        vm.warp(200 days);dollar=new LaunchDollar();diem=new SyntheticDiem();
        SyntheticDiemRegistry registry=new SyntheticDiemRegistry();hosting=address(registry);
        wrapper=new NoerraDiem(IVeniceDiem(address(diem)),registry,new SyntheticBackingReader(),3500);
        ReinvestmentFactory factory=new ReinvestmentFactory();
        first=new ReinvestmentPool(address(dollar),intermediate,500,address(factory));
        second=new ReinvestmentPool(intermediate,address(diem),10000,address(factory));
        factory.set(address(dollar),intermediate,500,address(first));factory.set(intermediate,address(diem),10000,address(second));
        router=new ReinvestmentRouter(dollar,diem);
        treasury=new NoerraComputeReinvestment(wrapper,id,hosting,NoerraComputeReinvestment.Route(dollar,diem,intermediate,IReinvestmentRouter(address(router)),IReinvestmentPool(address(first)),IReinvestmentPool(address(second))),10e6,20e6,40e6);
        dollar.mint(address(treasury),100e6);
    }
    function testOnlyEarnedCashBuysCapacityAndKeepsReserve() public {
        treasury.invest(20e6,treasury.minimumOutput(20e6),block.timestamp+120);
        assertEq(dollar.balanceOf(hosting),6e6);assertEq(dollar.balanceOf(address(treasury)),80e6);
        assertEq(dollar.allowance(address(treasury),address(router)),0);assertEq(diem.allowance(address(treasury),address(wrapper)),0);
        assertEq(wrapper.lockedTreasury(id),14e6);assertEq(wrapper.backing(),wrapper.obligations());
        (uint256 stake,,)=diem.stakedInfos(address(wrapper.vaults(id)));assertEq(stake,14e6);
        treasury.invest(20e6,treasury.minimumOutput(20e6),block.timestamp+120);
        uint256 floor=treasury.minimumOutput(1e6);vm.expectRevert("Daily purchase limit");treasury.invest(1e6,floor,block.timestamp+120);
        vm.warp(block.timestamp+1 days);treasury.invest(20e6,treasury.minimumOutput(20e6),block.timestamp+120);
    }
    function testBadDeliveryAndPriceRollBackAllAccounting() public {
        router.set(100,true);uint256 floor=treasury.minimumOutput(20e6);
        vm.expectRevert("Actual DIEM delivery");treasury.invest(20e6,floor,block.timestamp+120);
        assertEq(treasury.spentToday(),0);assertEq(dollar.balanceOf(address(treasury)),100e6);assertEq(dollar.balanceOf(hosting),0);
        router.set(98,false);vm.expectRevert("Actual DIEM delivery");treasury.invest(20e6,floor,block.timestamp+120);
        vm.expectRevert("TWAP price floor");treasury.invest(20e6,floor-1,block.timestamp+120);
        first.set(0,true);vm.expectRevert("No history");treasury.minimumOutput(20e6);
    }
    function testBatchReserveDeadlineAndCanonicalPoolLimits() public {
        vm.expectRevert("Fresh deadline");treasury.invest(20e6,1,block.timestamp+121);
        vm.expectRevert("Funded batch");treasury.invest(21e6,1,block.timestamp+120);
        vm.prank(address(treasury));dollar.transfer(address(0xdead),89e6);
        uint256 floor=treasury.minimumOutput(2e6);vm.expectRevert("Funded batch");treasury.invest(2e6,floor,block.timestamp+120);
        (bool ok,)=address(treasury).call(abi.encodeWithSignature("withdraw(address,uint256)",hosting,1));assertFalse(ok);
    }
    function testFuzzConservation(uint256 input) public {
        uint256 amount=bound(input,1e6,20e6);treasury.invest(amount,treasury.minimumOutput(amount),block.timestamp+120);
        uint256 hostingAmount=amount*30/100;
        assertEq(dollar.balanceOf(hosting),hostingAmount);assertEq(wrapper.lockedTreasury(id),amount-hostingAmount);
        assertEq(dollar.balanceOf(address(treasury))+dollar.balanceOf(address(router))+dollar.balanceOf(hosting),100e6);
        assertEq(wrapper.backing(),wrapper.obligations());
    }
}
