// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraCreationToken} from "../src/agents/NoerraAgents.sol";

contract ProtectionRoleFixture {}

contract ProtectionFactoryFixture {
    NoerraCreationToken public token;
    constructor() { token = new NoerraCreationToken("Protected", "PROT", address(this)); }
    function initialize(address manager, address locker, address reserve, address bridge) external {
        token.initializeLaunchProtection(manager, locker, reserve, bridge);
    }
    function distribute(address to, uint256 amount) external { token.transfer(to, amount); }
}

contract NoerraCreationProtectionTest is Test {
    ProtectionFactoryFixture factory;
    NoerraCreationToken token;
    address manager;
    address locker;
    address reserve;
    address bridge;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant CAP = 20_000_000 ether;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        factory = new ProtectionFactoryFixture(); token = factory.token();
        manager = address(new ProtectionRoleFixture()); locker = address(new ProtectionRoleFixture());
        reserve = address(new ProtectionRoleFixture()); bridge = address(new ProtectionRoleFixture());
        factory.initialize(manager, locker, reserve, bridge);
        factory.distribute(manager, 500_000_000 ether); factory.distribute(reserve, 500_000_000 ether);
    }

    function testMaxBuyAndRepeatedWalletAccumulation() public {
        vm.prank(manager); vm.expectRevert("Launch max buy"); token.transfer(alice, CAP + 1);
        vm.prank(manager); token.transfer(alice, 11_000_000 ether);
        vm.prank(manager); token.transfer(alice, 9_000_000 ether);
        assertEq(token.balanceOf(alice), CAP);
        vm.prank(manager); vm.expectRevert("Launch max wallet"); token.transfer(alice, 1);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testTransfersSelfTransferAndSellDoNotBypassOrDoubleCountWallet() public {
        vm.prank(manager); token.transfer(alice, CAP);
        vm.prank(manager); token.transfer(bob, CAP);
        vm.prank(alice); assertTrue(token.transfer(alice, CAP)); assertEq(token.balanceOf(alice), CAP);
        vm.prank(bob); vm.expectRevert("Launch max wallet"); token.transfer(alice, 1);
        vm.prank(alice); token.transfer(manager, CAP);
        vm.prank(bob); token.transfer(alice, CAP);
        assertEq(token.balanceOf(alice), CAP); assertEq(token.balanceOf(bob), 0);
        vm.prank(alice); token.approve(bob, 1);
        vm.prank(bob); token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), CAP - 1); assertEq(token.balanceOf(bob), 1);
    }

    function testOnlyFixedInfrastructureRecipientsAreExemptAndBridgePreservesSupply() public {
        assertTrue(token.launchExempt(address(factory))); assertTrue(token.launchExempt(manager));
        assertTrue(token.launchExempt(locker)); assertTrue(token.launchExempt(reserve)); assertTrue(token.launchExempt(bridge));
        assertFalse(token.launchExempt(alice)); assertFalse(token.launchExempt(bob));
        vm.prank(reserve); token.transfer(bridge, 500_000_000 ether);
        vm.prank(bridge); vm.expectRevert("Launch max wallet"); token.transfer(alice, CAP + 1);
        vm.prank(bridge); token.transfer(alice, CAP);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(manager) + token.balanceOf(bridge) + token.balanceOf(alice), token.totalSupply());
    }

    function testTenBlockWindowIncludesLaunchThroughBlockNineThenExpiresForever() public {
        assertEq(token.protectionStartBlock(), 100); assertEq(token.protectionEndBlock(), 110);
        vm.roll(109); assertTrue(token.launchProtectionActive());
        vm.prank(manager); vm.expectRevert("Launch max buy"); token.transfer(alice, CAP + 1);
        vm.roll(110); assertFalse(token.launchProtectionActive());
        vm.prank(manager); token.transfer(alice, CAP + 1);
        vm.prank(manager); token.transfer(alice, CAP + 1);
        vm.expectRevert("Launch protection fixed"); factory.initialize(manager, locker, reserve, bridge);
        vm.roll(10_000); assertFalse(token.launchProtectionActive());
        assertEq(token.protectionEndBlock(), 110);
    }

    function testProtectionCannotBeInitializedByCreatorOrAfterDistribution() public {
        NoerraCreationToken legacy = new NoerraCreationToken("Legacy", "OLD", alice);
        vm.prank(alice); vm.expectRevert("Launch factory only");
        legacy.initializeLaunchProtection(manager, locker, reserve, bridge);
        ProtectionFactoryFixture late = new ProtectionFactoryFixture(); late.distribute(alice, 1);
        vm.expectRevert("Launch protection fixed"); late.initialize(manager, locker, reserve, bridge);
        assertFalse(late.token().protectionInitialized());
    }

    function testProtectionRequiresEthereumAndDeployedInfrastructure() public {
        ProtectionFactoryFixture fresh = new ProtectionFactoryFixture();
        vm.chainId(8453); vm.expectRevert("Launch factory only"); fresh.initialize(manager, locker, reserve, bridge);
        vm.chainId(1); vm.expectRevert("Launch protection pins"); fresh.initialize(manager, locker, reserve, alice);
        assertFalse(fresh.token().protectionInitialized());
    }

    function testLegacyConstructorSupplyAndTransfersRemainCompatible() public {
        NoerraCreationToken legacy = new NoerraCreationToken("Legacy", "OLD", alice);
        assertFalse(legacy.protectionInitialized());
        vm.prank(alice); legacy.transfer(bob, 300_000_000 ether);
        assertEq(legacy.balanceOf(bob), 300_000_000 ether); assertEq(legacy.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzzRecipientCapPreservesSupply(uint256 first, uint256 second) public {
        first = bound(first, 0, CAP); second = bound(second, 0, CAP);
        vm.prank(manager); token.transfer(alice, first);
        if (first + second > CAP) { vm.prank(manager); vm.expectRevert("Launch max wallet"); token.transfer(alice, second); }
        else { vm.prank(manager); token.transfer(alice, second); }
        assertLe(token.balanceOf(alice), CAP);
        assertEq(token.balanceOf(manager) + token.balanceOf(reserve) + token.balanceOf(alice), token.totalSupply());
    }
}
