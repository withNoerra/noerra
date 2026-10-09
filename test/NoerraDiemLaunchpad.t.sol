// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoerraDiem, IVeniceDiem, IAgentPoolBacking} from "../src/agents/NoerraDiem.sol";
import {NoerraDiemLaunchpad, NoerraDiemCreation, NoerraDiemBackingReader, NoerraDiemCreationDeployer} from "../src/agents/NoerraDiemLaunchpad.sol";
import {NoerraAgentRegistry, IAgentRegistry, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {NoerraBackers} from "../src/agents/NoerraLaunchpad.sol";
import {SyntheticDiem} from "./NoerraDiem.t.sol";
import {LaunchDollar} from "./NoerraLaunchpad.t.sol";

contract NoerraDiemLaunchpadTest is Test {
    SyntheticDiem diem;
    NoerraDiem wrapper;
    NoerraAgentRegistry registry;
    NoerraDiemBackingReader reader;
    NoerraDiemLaunchpad factory;
    NoerraDiemCreation locker;
    PoolManager manager;
    bytes32 id;
    address human = address(0xa1);
    address trader = address(0xb1);
    address signer = address(0xc1);
    address protocol = address(0xd1);
    address noer = address(0xe1);

    function setUp() public {
        diem = new SyntheticDiem(); manager = new PoolManager(address(this));
        registry = new NoerraAgentRegistry(new LaunchDollar(), IAgentRecoveryVerifier(address(0)));
        reader = new NoerraDiemBackingReader(IPoolManager(address(manager)), registry);
        wrapper = new NoerraDiem(IVeniceDiem(address(diem)), IAgentRegistry(address(registry)), reader, 3500);
        NoerraDiemCreationDeployer deployer = new NoerraDiemCreationDeployer(wrapper, IPoolManager(address(manager)));
        factory = new NoerraDiemLaunchpad(registry, wrapper, IPoolManager(address(manager)), deployer, protocol, noer);
        reader.bind(factory);
        diem.mint(human, 100 ether); diem.mint(trader, 100 ether);
        vm.startPrank(human);
        diem.approve(address(wrapper), 100 ether); wrapper.wrap(100 ether, human);
        (id,) = registry.create(signer, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        wrapper.approve(address(factory), 10 ether);
        locker = factory.launch(id, "Renewable", "RENEW", 10 ether);
        vm.stopPrank();
        vm.startPrank(trader); diem.approve(address(wrapper), 100 ether); wrapper.wrap(100 ether, trader); vm.stopPrank();
    }
    function buy(uint256 value) internal returns (uint256) {
        vm.startPrank(trader); wrapper.approve(address(locker), value);
        uint256 bought = locker.trade(true, value, 1, block.timestamp + 60); vm.stopPrank(); return bought;
    }
    function identity() internal view { assertEq(wrapper.backing(), wrapper.obligations()); }

    function testActualPositionNotManagerBalancesAndStakeTracksPrice() public {
        uint256 before = reader.poolBacking(id);
        // Full-range liquidity and price round down; never count seed dust as backing.
        assertLe(before, 10 ether); assertGt(before, 10 ether - 1e6);
        wrapper.reconcile(id); (uint256 stake,,) = diem.stakedInfos(address(wrapper.vaults(id)));
        assertEq(stake, before * 6500 / 10000); identity();
        vm.prank(human); wrapper.transfer(address(manager), 20 ether);
        assertEq(reader.poolBacking(id), before); (uint256 subtotal, uint256 next) = reader.poolBackingPage(0, 64); assertEq(subtotal, before); assertEq(next, 1);
        buy(2 ether);
        uint256 afterBuy = reader.poolBacking(id); assertGt(afterBuy, before);
        wrapper.reconcile(id); (stake,,) = diem.stakedInfos(address(wrapper.vaults(id)));
        assertEq(stake, afterBuy * 6500 / 10000); identity();
    }
    function testQuoteFeesLockIntoComputeAndBackerClaimsAreRedeemableDiem() public {
        uint256 bought = buy(2 ether); NoerraBackers backers = locker.backers();
        vm.startPrank(trader); locker.token().approve(address(backers), bought); backers.back(bought);
        vm.expectRevert("Soulbound"); backers.transfer(human, 1); vm.stopPrank();
        uint128 liquidity = locker.lockedLiquidity();
        (uint256 fees,) = locker.collect(); assertGt(fees, 0);
        assertEq(wrapper.lockedTreasury(id), fees * 20 / 100);
        uint256 pending = backers.pending(trader); assertGt(pending, 0);
        uint256 balance = wrapper.balanceOf(trader);
        vm.prank(trader); assertEq(backers.claim(), pending);
        assertEq(wrapper.balanceOf(trader), balance + pending);
        vm.prank(trader); wrapper.redeem(pending);
        assertEq(diem.balanceOf(trader), pending); identity();
        wrapper.reconcile(id);
        (uint256 stake,,) = diem.stakedInfos(address(wrapper.vaults(id)));
        assertEq(stake, wrapper.target(id)); assertEq(locker.lockedLiquidity(), liquidity);
        assertGt(wrapper.balanceOf(protocol), 0); assertGt(wrapper.balanceOf(noer), 0);
    }
    function testNoBackersAllComputeShareLockedAndNoPrincipalExit() public {
        buy(3 ether); (uint256 fees,) = locker.collect();
        assertEq(wrapper.lockedTreasury(id), fees * 20 / 100 * 2);
        vm.prank(human); (bool ok,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256)", 1)); assertFalse(ok);
        vm.expectRevert("One binding"); reader.bind(factory);
        vm.prank(trader); vm.expectRevert("Agent human only"); factory.launch(id, "Copy", "COPY", 1 ether);
        vm.prank(human); vm.expectRevert("One creation token"); factory.launch(id, "Copy", "COPY", 1 ether);
        assertEq(reader.deployer(), address(0)); assertEq(factory.count(), 1); identity();
    }
    function testDeployableSizeAndFrozenCreationBuilder() public {
        assertLe(address(factory).code.length, 24576); assertLe(address(factory.creationDeployer()).code.length, 24576);
        assertLe(address(locker).code.length, 24576); assertLe(address(wrapper).code.length, 24576);
        NoerraDiemCreationDeployer builder = factory.creationDeployer();
        vm.expectRevert("Frozen factory only"); builder.deploy(id);
        assertEq(locker.factory(), address(factory));
    }
    function testMultiplePoolsRemainIndependentAndUnrelatedHoldingsExcluded() public {
        vm.startPrank(human);
        (bytes32 second,) = registry.create(signer, keccak256("second"), keccak256("build"), 5e6, 10e6, "", "");
        wrapper.approve(address(factory), 4 ether); factory.launch(second, "Second", "SECOND", 4 ether);
        vm.stopPrank();
        uint256 secondBefore = reader.poolBacking(second); buy(1 ether);
        assertEq(reader.poolBacking(second), secondBefore);
        (uint256 subtotal, uint256 next) = reader.poolBackingPage(0, 1); assertEq(subtotal, reader.poolBacking(id)); assertEq(next, 1); (subtotal, next) = reader.poolBackingPage(next, 1); assertEq(subtotal, secondBefore); assertEq(next, 2);
        assertEq(reader.poolBacking(bytes32(uint256(123))), 0);
        wrapper.reconcile(id); wrapper.reconcile(second); identity();
    }
    function testLaunchBeyond64AndConstantCostReconciliation() public {
        wrapper.reconcile(id);
        uint256 gasBefore = gasleft(); wrapper.target(id); uint256 baseline = gasBefore - gasleft();
        vm.startPrank(human);
        wrapper.approve(address(factory), type(uint256).max);
        bytes32 last;
        for (uint256 i; i < 70; ++i) {
            (last,) = registry.create(signer, keccak256(abi.encode(i)), keccak256("build"), 5e6, 10e6, "", "");
            factory.launch(last, "More", "MORE", 0.1 ether);
        }
        vm.stopPrank();
        assertEq(factory.count(), 71);
        gasBefore = gasleft(); wrapper.target(id); uint256 later = gasBefore - gasleft();
        assertLe(later, baseline + 1000, "Target gas must not grow with market count");
        wrapper.reconcile(last); identity();
        (uint256 subtotal, uint256 next) = reader.poolBackingPage(64, 64);
        assertGt(subtotal, 0); assertEq(next, 71);
        vm.expectRevert("Page bounds"); reader.poolBackingPage(0, 65);
        vm.expectRevert("Page cursor"); reader.poolBackingPage(72, 1);
        (subtotal, next) = reader.poolBackingPage(71, 1); assertEq(subtotal, 0); assertEq(next, 71);
    }
    function testFuzzRoundTripFeeConservation(uint96 input) public {
        uint256 value = bound(input, 1e14, 50 ether); uint256 bought = buy(value);
        vm.startPrank(trader); locker.token().approve(address(locker), bought);
        uint256 received = locker.trade(false, bought, 1, block.timestamp + 60); vm.stopPrank();
        assertLt(received, value); uint128 liquidity = locker.lockedLiquidity();
        (uint256 fees,) = locker.collect();
        assertEq(wrapper.lockedTreasury(id), fees * 20 / 100 * 2);
        assertEq(wrapper.balanceOf(protocol), fees * 20 / 100);
        assertEq(wrapper.balanceOf(noer), fees - fees * 20 / 100 * 3 - fees * 30 / 100);
        assertEq(locker.lockedLiquidity(), liquidity);
        wrapper.reconcile(id); identity();
    }
}
