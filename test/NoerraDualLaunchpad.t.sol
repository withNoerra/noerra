// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, IAgentRegistry, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {NoerraDiem, IVeniceDiem} from "../src/agents/NoerraDiem.sol";
import {NoerraDiemCreation, NoerraDiemBackingReader, NoerraDiemCreationDeployer, NoerraDiemLaunchpad} from "../src/agents/NoerraDiemLaunchpad.sol";
import {NoerraLockedCreation} from "../src/agents/NoerraLaunchpad.sol";
import {NoerraDualLaunchpad, NoerraCashCreationDeployer} from "../src/agents/NoerraDualLaunchpad.sol";
import {SyntheticDiem} from "./NoerraDiem.t.sol";
import {LaunchDollar} from "./NoerraLaunchpad.t.sol";

contract NoerraDualLaunchpadTest is Test {
    LaunchDollar cash; SyntheticDiem diem; NoerraDiem wrapper; NoerraAgentRegistry registry;
    NoerraAgentCredits credits; NoerraDualLaunchpad factory; NoerraDiemBackingReader reader;
    NoerraLockedCreation dollarMarket; NoerraDiemCreation brainMarket;
    address human = address(0xa1); address trader = address(0xb1); address account; bytes32 id;
    function setUp() public {
        cash = new LaunchDollar(); diem = new SyntheticDiem(); PoolManager manager = new PoolManager(address(this));
        registry = new NoerraAgentRegistry(cash, IAgentRecoveryVerifier(address(0)));
        credits = new NoerraAgentCredits(cash, IAgentRegistry(address(registry)), address(0));
        reader = new NoerraDiemBackingReader(IPoolManager(address(manager)), registry);
        wrapper = new NoerraDiem(IVeniceDiem(address(diem)), IAgentRegistry(address(registry)), reader, 3500);
        factory = new NoerraDualLaunchpad(registry, credits, wrapper, IPoolManager(address(manager)),
            new NoerraDiemCreationDeployer(wrapper, IPoolManager(address(manager))),
            new NoerraCashCreationDeployer(wrapper, IPoolManager(address(manager))), address(0xd1), address(0xe1));
        reader.bind(NoerraDiemLaunchpad(address(factory)));
        vm.deal(human, 1 ether); cash.mint(human, 1000e6); cash.mint(trader, 1000e6); diem.mint(human, 100 ether); diem.mint(trader, 100 ether);
        vm.startPrank(human);
        diem.approve(address(wrapper), 100 ether); wrapper.wrap(100 ether, human);
        (id, account) = registry.create(address(0xc1), keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        cash.approve(address(factory), 1000e6); wrapper.approve(address(factory), 100 ether);
        vm.stopPrank();
    }
    function launch() internal { vm.prank(human); (dollarMarket, brainMarket) = factory.launch{value: 0.0002 ether}(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 10 ether, 0.1 ether, 25e6)); }
    function testOneAtomicTokenPaysBothCashAndRenewableCompute() public {
        launch(); IERC20 token = dollarMarket.token();
        assertEq(address(token), address(brainMarket.token())); assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0); assertEq(token.balanceOf(human), 0);
        assertGt(dollarMarket.lockedLiquidity(), 0); assertGt(brainMarket.lockedLiquidity(), 0);
        assertEq(wrapper.lockedTreasury(id), 0.1 ether); assertEq(cash.balanceOf(account), 25e6);
        assertEq(address(0xc1).balance, 0.0002 ether); assertEq(address(factory).balance, 0);
        (uint256 stake,,) = diem.stakedInfos(address(wrapper.vaults(id))); assertEq(stake, wrapper.target(id));
        vm.startPrank(trader); cash.approve(address(dollarMarket), 10e6); dollarMarket.trade(true, 10e6, 1, block.timestamp + 60);
        diem.approve(address(wrapper), 100 ether); wrapper.wrap(100 ether, trader); wrapper.approve(address(brainMarket), 1 ether);
        brainMarket.trade(true, 1 ether, 1, block.timestamp + 60); vm.stopPrank();
        uint256 cashBefore = cash.balanceOf(account); uint256 lockedBefore = wrapper.lockedTreasury(id);
        (uint256 cashFees,) = dollarMarket.collect(); (uint256 brainFees,) = brainMarket.collect();
        assertGt(cashFees, 0); assertGt(brainFees, 0);
        assertEq(cash.balanceOf(account) - cashBefore, cashFees * 20 / 100 * 2);
        assertEq(wrapper.lockedTreasury(id) - lockedBefore, brainFees * 20 / 100 * 2);
        wrapper.reconcile(id); assertEq(wrapper.backing(), wrapper.obligations());
    }
    function testUnderfundedLaunchRollsBackAllMarketsAndPrincipal() public {
        uint256 beforeCash = cash.balanceOf(human);
        vm.startPrank(human);
        vm.expectRevert("Permanent activation floor"); factory.launch{value: 0.0002 ether}(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 10 ether, 1, 25e6));
        vm.expectRevert("Fund hosting reserve and startup"); factory.launch{value: 0.0002 ether}(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 10 ether, 0.1 ether, 1));
        vm.expectRevert("Seed bounds"); factory.launch{value: 0.0002 ether}(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 0, 0.1 ether, 25e6));
        vm.stopPrank(); assertEq(factory.count(), 0); assertEq(address(factory.launches(id)), address(0)); assertEq(address(factory.cashLaunches(id)), address(0));
        assertEq(cash.balanceOf(human), beforeCash); assertEq(wrapper.lockedTreasury(id), 0);
    }
    function testDuplicateAndForeignFactoryCannotLaunchOrExtractPrincipal() public {
        launch(); vm.prank(human); vm.expectRevert("One creation token"); factory.launch{value: 0.0002 ether}(id, "Again", "AGAIN", NoerraDualLaunchpad.Funding(100e6, 10 ether, 0.1 ether, 25e6));
        NoerraCashCreationDeployer cashBuilder = factory.cashDeployer(); NoerraDiemCreationDeployer brainBuilder = factory.creationDeployer();
        vm.expectRevert("Frozen factory only"); cashBuilder.deploy(id);
        vm.expectRevert("Frozen factory only"); brainBuilder.deploy(id);
        (bool ok,) = address(dollarMarket).call(abi.encodeWithSignature("withdraw(uint256)", 1)); assertFalse(ok);
        assertLe(address(factory).code.length, 24576); assertLe(address(factory.cashDeployer()).code.length, 24576);
        assertLe(address(factory.creationDeployer()).code.length, 24576);
    }
    function testNoFactoryLifetimeCapBeyond64DualLaunches() public {
        cash.mint(human, 10000e6);
        vm.startPrank(human); cash.approve(address(factory), type(uint256).max);
        bytes32 last;
        for (uint256 i; i < 71; ++i) {
            (bytes32 created, address treasury) = registry.create(address(uint160(0xf100 + i)), keccak256(abi.encode(i)), keccak256("build"), 5e6, 10e6, "", "");
            factory.launch{value: 0.0002 ether}(created, "Independent", "OWN", NoerraDualLaunchpad.Funding(100e6, 0.1 ether, 0.1 ether, 15e6));
            assertEq(cash.balanceOf(treasury), 15e6); assertEq(address(uint160(0xf100 + i)).balance, 0.0002 ether); last = created;
        }
        vm.stopPrank(); assertEq(factory.count(), 71);
        assertTrue(address(factory.launches(last)) != address(0)); assertTrue(address(factory.cashLaunches(last)) != address(0));
        (, uint256 next) = reader.poolBackingPage(64, 64); assertEq(next, 71);
        wrapper.reconcile(last); assertEq(wrapper.backing(), wrapper.obligations());
    }
    function testStartupGasBoundsAndDeliveryAreAtomic() public {
        uint256 beforeCash = cash.balanceOf(human);
        vm.startPrank(human);
        vm.expectRevert("Bounded startup gas"); factory.launch(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 10 ether, 0.1 ether, 25e6));
        vm.expectRevert("Bounded startup gas"); factory.launch{value: 0.0101 ether}(id, "Dual", "DUAL", NoerraDualLaunchpad.Funding(100e6, 10 ether, 0.1 ether, 25e6));
        vm.stopPrank(); assertEq(cash.balanceOf(human), beforeCash); assertEq(factory.count(), 0);
    }
}
