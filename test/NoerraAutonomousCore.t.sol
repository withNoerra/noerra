// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraRegistryAccountDeployer} from "../src/agents/NoerraAgents.sol";
import {AgentTestDollar, AgentTestVerifier} from "./NoerraAgents.t.sol";

contract AutonomousFactoryFixture {
    address public immutable registry;
    constructor(address registry_) { registry=registry_; }
    function lock(NoerraAgentAccount account) external { account.lockAutonomousCore(); }
}
contract AutonomousVaultFixture {
    address public immutable dollar; address public immutable deployer; address public immutable agentTreasury;
    constructor(address dollar_, address deployer_, address account_) { dollar=dollar_; deployer=deployer_; agentTreasury=account_; }
}

contract NoerraAutonomousCoreTest is Test {
    AgentTestDollar dollar; AgentTestVerifier verifier; NoerraAgentRegistry registry;
    NoerraAgentAccount account; AutonomousFactoryFixture factory;
    address human=address(0xA1); address steward=address(0xB1);
    uint256 runtimeKey=0x123456; bytes32 intent=keccak256("approved mission and startup");
    function setUp() public {
        vm.warp(1000); vm.roll(10);
        dollar=new AgentTestDollar(); verifier=new AgentTestVerifier();
        registry=new NoerraAgentRegistry(dollar,verifier); factory=new AutonomousFactoryFixture(address(registry));
        registry.enrollAutonomousLaunchFactory(address(factory));
        vm.prank(human); (,address created)=registry.createAccount(human,keccak256("identity"),keccak256("build"),50e6,7e6);
        account=NoerraAgentAccount(created);
    }
    function _approve() internal {
        vm.startPrank(human); account.setRecipient(address(0xD1),true); account.setRecoveryPolicy(5e6,1e6);
        account.approveAutomaticActivation(1,intent,51e6,block.timestamp+1 days,0.001 ether); vm.stopPrank();
    }
    function _lock() internal { _approve(); factory.lock(account); }
    function _activate() internal {
        address runtime=vm.addr(runtimeKey); bytes32 destination=keccak256("measured computer");
        bytes32 commitment=account.automaticActivationCommitment(1,runtime,destination); verifier.set(commitment);
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(runtimeKey,keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",commitment)));
        vm.prank(address(0xF1)); account.activateApproved(1,runtime,destination,abi.encodePacked(r,s,v),"synthetic attestation");
    }
    function testLaunchLockRequiresEnrolledAuthorityLiveApprovalAndRecovery() public {
        vm.expectRevert("Autonomous factory"); account.lockAutonomousCore();
        vm.expectRevert("Autonomous approval"); factory.lock(account); assertFalse(account.autonomousCoreLocked());
        _approve(); vm.warp(block.timestamp+2 days);
        vm.expectRevert("Autonomous approval"); factory.lock(account); assertFalse(account.autonomousCoreLocked());
    }
    function testLockedCoreCannotBeCancelledDivertedOrDisabledAndFloorSurvivesTransfer() public {
        _lock(); assertEq(account.startupHuman(),human); assertEq(account.autonomousDailyFloor(),7e6);
        vm.startPrank(human);
        vm.expectRevert("Autonomous policy"); account.cancelAutomaticActivation();
        vm.expectRevert("Autonomous policy"); account.setRecipient(address(0xD1),false);
        vm.expectRevert("Autonomous policy"); account.setRecipient(human,true);
        vm.expectRevert("Autonomous policy"); account.setRecoveryPolicy(0,0);
        vm.expectRevert("Autonomous policy"); account.setDailyLimit(7e6-1);
        account.setDailyLimit(20e6); account.offerHuman(steward); vm.stopPrank();
        vm.prank(steward); account.acceptHuman(); assertEq(account.human(),steward); assertEq(account.startupHuman(),human);
        vm.startPrank(steward); vm.expectRevert("Autonomous policy"); account.cancelAutomaticActivation();
        account.setDailyLimit(7e6); vm.stopPrank();
        (bytes32 approved,,,,)=account.automaticActivation(); assertEq(approved,intent);
    }
    function testCreatorCannotUseRuntimeAuthorityBeforeAttestedActivation() public {
        _lock(); dollar.mint(address(account),100e6); vm.startPrank(human);
        vm.expectRevert("Autonomous startup"); account.pulse(1);
        vm.expectRevert("Autonomous startup"); account.pay(1,keccak256("drain"),address(0xD1),1);
        vm.expectRevert("Autonomous startup"); account.pulseCheckpoint(1,keccak256("fake checkpoint"));
        vm.expectRevert("Autonomous startup"); account.handover(1,address(0xC1),keccak256("fake lease"),"");
        vm.stopPrank(); assertEq(account.generation(),1); assertEq(dollar.balanceOf(address(account)),100e6);
    }
    function testPublicFundedStartupWorksAfterExpiryAndStewardTransferWithoutChangingCommitment() public {
        _approve(); address runtime=vm.addr(runtimeKey); bytes32 destination=keccak256("measured computer");
        bytes32 before=account.automaticActivationCommitment(1,runtime,destination);
        (,, ,uint256 expiry,)=account.automaticActivation(); factory.lock(account);
        assertEq(account.automaticActivationCommitment(1,runtime,destination),before);
        vm.prank(human); account.offerHuman(steward); vm.prank(steward); account.acceptHuman();
        vm.warp(expiry+31 days); assertEq(account.automaticActivationCommitment(1,runtime,destination),before);
        dollar.mint(address(account),100e6); _activate(); assertEq(account.generation(),2); assertEq(account.signer(),runtime);
        assertTrue(account.recipients(runtime)); vm.prank(runtime); account.pay(2,keccak256("work"),runtime,7e6);
        assertEq(dollar.balanceOf(runtime),7e6);
        vm.prank(runtime); vm.expectRevert("Daily limit"); account.pay(2,keccak256("too much"),runtime,1);
        vm.expectRevert("Initial human authority"); account.activateApproved(1,runtime,destination,"","");
    }
    function testDonatedRecoveryReserveCannotInvalidatePermanentApprovalAndProtectedFundsRemain() public {
        _lock(); dollar.mint(address(this),50e6); dollar.approve(address(account),50e6); account.fundRecoveryReserve(50e6);
        dollar.mint(address(account),51e6); _activate(); assertEq(account.recoveryReserve(),50e6);
        vm.prank(vm.addr(runtimeKey)); vm.expectRevert("Hosting reserve"); account.pay(2,keccak256("protected"),vm.addr(runtimeKey),2e6);
    }
    function testRegistryEnrollmentIsOneShotAndHelperCannotBeUsedByOthers() public {
        vm.expectRevert("One deployment binding"); registry.enrollAutonomousLaunchFactory(address(factory));
        NoerraAgentRegistry other=new NoerraAgentRegistry(dollar,verifier);
        vm.expectRevert("Factory registry"); other.enrollAutonomousLaunchFactory(address(factory));
        AutonomousFactoryFixture otherFactory=new AutonomousFactoryFixture(address(other));
        vm.prank(human); vm.expectRevert("One deployment binding"); other.enrollAutonomousLaunchFactory(address(otherFactory));
        NoerraRegistryAccountDeployer helper=registry.accountDeployer();
        vm.expectRevert("Registry only"); helper.deploy(keccak256("foreign"),human,human,keccak256("build"),1,1,keccak256("meta"),true);
        assertEq(account.registry(),address(registry));
        assertLe(address(account).code.length,24576); assertLe(address(registry).code.length,24576);
        assertLe(address(registry.accountDeployer()).code.length,24576);
    }
    function testDeploymentAuthorityCannotReserveAnotherOwnersAccountAsFlagship() public {
        AutonomousVaultFixture target=new AutonomousVaultFixture(address(dollar),address(this),address(account));
        vm.expectRevert("Original flagship authority"); registry.enrollAutonomousFlagshipVault(address(target));
        assertEq(registry.autonomousFlagshipVault(),address(0));
        _lock(); assertTrue(account.autonomousCoreLocked());
    }
    function testPlatformReplacementIsImmediateButCannotChangeLockedRuntimeOrFinancialPolicy() public {
        _lock(); dollar.mint(address(account),100e6); _activate();
        bytes32 id=account.agentId(); address runtime=account.signer(); uint256 generation=account.generation();
        vm.prank(runtime); account.pulseCheckpoint(generation,keccak256("durable operational memory"));
        vm.prank(runtime); account.pay(generation,keccak256("prior work"),runtime,2e6);
        vm.prank(human); account.offerHuman(address(0xC1));
        registry.replaceAgentSteward(id,steward,keccak256("platform approved community stewardship"));
        assertEq(account.human(),steward); assertEq(account.proposedHuman(),address(0));
        assertEq(account.stewardshipRevision(),1); assertEq(account.platformStewardshipRevision(),1);
        assertEq(account.signer(),runtime); assertEq(account.generation(),generation); assertEq(account.spentToday(),2e6);
        assertEq(account.checkpointHash(),keccak256("durable operational memory")); assertEq(dollar.balanceOf(address(account)),98e6);
        assertTrue(account.recipients(runtime)); assertEq(account.dailyLimit(),7e6); assertTrue(account.autonomousCoreLocked());
        vm.prank(address(0xC1)); vm.expectRevert("Proposed human only"); account.acceptHuman();
        vm.prank(steward); vm.expectRevert("Autonomous policy"); account.setRecipient(steward,true);
        vm.prank(runtime); account.pay(generation,keccak256("continued work"),runtime,5e6);
        vm.prank(steward); account.offerHuman(human); vm.prank(human); account.acceptHuman();
        assertEq(account.stewardshipRevision(),2); assertEq(account.platformStewardshipRevision(),1);
        registry.replaceAgentSteward(id,steward,keccak256("platform replacement cannot be blocked by voluntary transfers"));
        assertEq(account.human(),steward); assertEq(account.platformStewardshipRevision(),3);
    }
    function testPlatformReplacementRejectsUnauthorizedZeroAndUnlaunchedAccounts() public {
        bytes32 id=account.agentId(); bytes32 reason=keccak256("platform review");
        vm.prank(human); vm.expectRevert("Deployment authority only"); registry.replaceAgentSteward(id,steward,reason);
        vm.expectRevert("Platform stewardship only"); registry.replaceAgentSteward(id,steward,reason);
        _lock(); vm.expectRevert("Steward replacement"); registry.replaceAgentSteward(id,address(0),reason);
        vm.expectRevert("Steward replacement"); registry.replaceAgentSteward(id,steward,bytes32(0));
        vm.prank(steward); vm.expectRevert("Platform stewardship only"); account.setStewardForPlatform(steward,reason);
        registry.replaceAgentSteward(id,steward,reason);
        address runtime=vm.addr(runtimeKey); bytes32 destination=keccak256("measured computer");
        assertNotEq(account.automaticActivationCommitment(1,runtime,destination),bytes32(0));
        dollar.mint(address(account),100e6); _activate(); assertEq(account.generation(),2);
    }
}
