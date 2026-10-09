// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoerraDiem, NoerraDiemVault, IVeniceDiem, IAgentPoolBacking} from "../src/agents/NoerraDiem.sol";
import {IAgentRegistry} from "../src/agents/NoerraAgents.sol";

contract SyntheticDiem is ERC20 {
    struct Stake { uint256 amountStaked; uint256 coolDownEnd; uint256 coolDownAmount; }
    mapping(address => Stake) public stakedInfos;
    constructor() ERC20("Synthetic DIEM", "TEST") {}
    function mint(address who, uint256 amount) external { _mint(who, amount); }
    function stake(uint256 amount) external { _transfer(msg.sender, address(this), amount); stakedInfos[msg.sender].amountStaked += amount; }
    function initiateUnstake(uint256 amount) external {
        Stake storage row = stakedInfos[msg.sender]; require(row.coolDownAmount == 0 && amount > 0 && amount <= row.amountStaked, "Cooldown");
        row.amountStaked -= amount; row.coolDownAmount = amount; row.coolDownEnd = block.timestamp + 1 days;
    }
    function unstake() external { Stake storage row = stakedInfos[msg.sender]; require(row.coolDownAmount > 0 && row.coolDownEnd <= block.timestamp, "Not mature"); uint256 amount = row.coolDownAmount; row.coolDownAmount = 0; _transfer(address(this), msg.sender, amount); }
}
contract SyntheticDiemRegistry is IAgentRegistry {
    address public signer;
    function setSigner(address value) external { signer = value; }
    function accounts(bytes32 id) external view returns (address) { return id == bytes32(uint256(1)) || id == bytes32(uint256(2)) ? address(this) : address(0); }
}
contract SyntheticBackingReader is IAgentPoolBacking {
    mapping(bytes32 => uint256) public poolBacking;
    uint256 public totalPoolBacking;
    function set(bytes32 id, uint256 amount) external { totalPoolBacking = totalPoolBacking - poolBacking[id] + amount; poolBacking[id] = amount; }
}
contract NoerraDiemTest is Test {
    SyntheticDiem diem; NoerraDiem wrapper; SyntheticBackingReader reader;
    bytes32 a = bytes32(uint256(1)); bytes32 b = bytes32(uint256(2)); address alice = address(0xA1); address bob = address(0xB1);
    function setUp() public {
        diem = new SyntheticDiem(); reader = new SyntheticBackingReader(); wrapper = new NoerraDiem(IVeniceDiem(address(diem)), new SyntheticDiemRegistry(), reader, 3500);
        diem.mint(alice, 100 ether); vm.startPrank(alice); diem.approve(address(wrapper), 100 ether); wrapper.wrap(100 ether, alice); vm.stopPrank();
    }
    function identity() internal view { assertEq(wrapper.backing(), wrapper.obligations()); }
    function testVaultSignatureFollowsRecoveryWithoutMovingItsStake() public {
        reader.set(a, 100 ether); wrapper.reconcile(a);
        SyntheticDiemRegistry registry = SyntheticDiemRegistry(address(wrapper.registry()));
        registry.setSigner(vm.addr(123));
        bytes32 digest = keccak256("endpoint-bound SIWE digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, digest);
        NoerraDiemVault vault = wrapper.vaults(a);
        assertEq(vault.isValidSignature(digest, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
        registry.setSigner(vm.addr(456));
        assertEq(vault.isValidSignature(digest, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
        (v, r, s) = vm.sign(456, digest);
        assertEq(vault.isValidSignature(digest, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
        assertEq(vault.isValidSignature(digest, hex"12"), bytes4(0xffffffff));
        (uint256 stake,,) = diem.stakedInfos(address(vault)); assertEq(stake, 65 ether); identity();
        vm.prank(vm.addr(456)); vm.expectRevert("Wrapper only"); vault.initiate(1 ether);
    }
    function testWrapAndImmediateRedemption() public {
        identity(); vm.prank(alice); wrapper.redeem(10 ether); assertEq(diem.balanceOf(alice), 10 ether); assertEq(wrapper.balanceOf(alice), 90 ether); identity();
    }
    function testPoolBackingRenewsCapacityAndKeepsBuffer() public {
        reader.set(a, 100 ether); wrapper.reconcile(a);
        (uint256 staked,,) = diem.stakedInfos(address(wrapper.vaults(a))); assertEq(staked, 65 ether); assertEq(wrapper.liquidAvailable(), 35 ether); identity();
    }
    function testLargeRedemptionCooldownFifoAndPartialClaims() public {
        reader.set(a, 100 ether); wrapper.reconcile(a);
        vm.prank(alice); uint256 request = wrapper.redeem(80 ether); assertEq(request, 1); assertEq(diem.balanceOf(alice), 35 ether); assertEq(wrapper.queueDebt(), 45 ether); identity();
        reader.set(a, wrapper.totalSupply());
        wrapper.reconcile(a); (, uint256 end, uint256 cooling) = diem.stakedInfos(address(wrapper.vaults(a))); assertGt(cooling, 45 ether);
        vm.prank(alice); wrapper.transfer(bob, 20 ether); vm.prank(bob); uint256 second = wrapper.redeem(20 ether); assertEq(second, 2);
        reader.set(a, wrapper.totalSupply());
        vm.warp(end); wrapper.reconcile(a); assertEq(wrapper.claimable(alice), 45 ether); assertGt(wrapper.claimable(bob), 0); identity();
        vm.prank(alice); wrapper.claim(); assertEq(diem.balanceOf(alice), 80 ether);
        // A second pass starts the remaining cooldown rather than pretending instant liquidity.
        (, end, cooling) = diem.stakedInfos(address(wrapper.vaults(a))); if (cooling > 0) { vm.warp(end); wrapper.reconcile(a); }
        vm.prank(bob); wrapper.claim(); assertEq(diem.balanceOf(bob), 20 ether); identity(); assertEq(wrapper.totalSupply(), 0);
    }
    function testPermanentTreasuryFloorAndPermissionlessPass() public {
        vm.prank(alice); wrapper.lockFor(a, 10 ether); reader.set(a, 90 ether); wrapper.reconcile(a);
        (uint256 staked,,) = diem.stakedInfos(address(wrapper.vaults(a))); assertEq(staked, 68.5 ether); assertEq(wrapper.totalLocked(), 10 ether);
        reader.set(a, 0); wrapper.reconcile(a); (staked,,) = diem.stakedInfos(address(wrapper.vaults(a))); assertEq(staked, 10 ether); identity();
    }
    function testNoUnregisteredVaultOrFabricatedPoolBacking() public {
        vm.expectRevert("Registered agent only"); wrapper.activate(bytes32(uint256(7)));
        reader.set(a, 101 ether); vm.expectRevert("Backing reader bounds"); wrapper.reconcile(a);
    }
    function testLargeBackingAndRedemptionDebtDoNotOverflowTarget() public {
        uint256 amount = 1 << 160;
        diem.mint(bob, amount); vm.startPrank(bob); diem.approve(address(wrapper), amount); wrapper.wrap(amount, bob); vm.stopPrank();
        reader.set(a, amount); wrapper.reconcile(a);
        vm.prank(bob); wrapper.redeem(amount / 2);
        assertGt(wrapper.queueDebt(), 0); reader.set(a, wrapper.totalSupply());
        uint256 desired = wrapper.target(a);
        assertGt(desired, 0); assertLt(desired, amount / 2);
        wrapper.reconcile(a); identity();
    }
    function testMatureExitSurvivesInvalidBackingReader() public {
        reader.set(a, 100 ether); wrapper.reconcile(a);
        vm.prank(alice); wrapper.redeem(80 ether);
        reader.set(a, wrapper.totalSupply()); wrapper.reconcile(a);
        (, uint256 end,) = diem.stakedInfos(address(wrapper.vaults(a)));
        reader.set(a, 1000 ether); vm.warp(end);
        vm.expectRevert("Backing reader bounds"); wrapper.reconcile(a);
        wrapper.harvest(a);
        assertEq(wrapper.claimable(alice), 45 ether);
        vm.prank(alice); wrapper.claim(); assertEq(diem.balanceOf(alice), 80 ether); identity();
    }
    function testFuzzExitTargetNeverExceedsAggregateProrata(uint96 poolA, uint96 poolB) public {
        poolA = uint96(bound(poolA, 0, 65 ether));
        poolB = uint96(bound(poolB, 0, 65 ether - poolA));
        reader.set(a, 100 ether); wrapper.reconcile(a);
        vm.prank(alice); wrapper.redeem(80 ether);
        assertEq(wrapper.queueDebt(), 45 ether);
        reader.set(a, poolA); reader.set(b, poolB);
        uint256 total = uint256(poolA) + poolB;
        uint256 oldA = total > 45 ether ? uint256(poolA) * (total - 45 ether) / total * 6500 / 10000 : 0;
        uint256 oldB = total > 45 ether ? uint256(poolB) * (total - 45 ether) / total * 6500 / 10000 : 0;
        assertLe(wrapper.target(a), oldA); assertLe(wrapper.target(b), oldB);
        wrapper.reconcile(a); identity();
    }
    function testFuzzFlatBackingThroughStakeAndRedeem(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether)); reader.set(a, 100 ether); wrapper.reconcile(a);
        vm.prank(alice); wrapper.redeem(amount); reader.set(a, wrapper.totalSupply()); identity(); wrapper.reconcile(a); identity();
        (, uint256 end, uint256 cooling) = diem.stakedInfos(address(wrapper.vaults(a))); if (cooling > 0) { vm.warp(end); wrapper.reconcile(a); identity(); }
    }
}
