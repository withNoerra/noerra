// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraRegistryTokenDeployer, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {NoerraRecoveryVerifier, NoerraPaidRecoveryVerifier} from "../src/agents/NoerraRecoveryVerifier.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";
import {RecoveryDcapFixture} from "./NoerraRecoveryVerifier.t.sol";

/// DCAP fixture checks binding and account policy; it does not verify real Intel signatures.
contract NoerraAutomaticActivationTest is Test {
    AgentTestDollar dollar;
    RecoveryDcapFixture dcap;
    NoerraRecoveryVerifier verifier;
    NoerraAgentRegistry registry;
    NoerraAgentAccount account;
    address human = address(0xA1);
    uint256 nextKey = 0x123456;
    address nextSigner;
    bytes32 intent = keccak256("fixed owner config build funding policy");
    bytes32 destination = keccak256("attested starter destination");
    bytes32 anchorHash = keccak256("fresh Ethereum anchor");
    bytes quote;

    function setUp() public {
        vm.roll(100); vm.warp(1000); vm.setBlockhash(99, anchorHash);
        dollar = new AgentTestDollar(); dcap = new RecoveryDcapFixture();
        verifier = new NoerraRecoveryVerifier(dcap, address(dcap).codehash, keccak256(new bytes(240)));
        registry = new NoerraAgentRegistry(dollar, verifier);
        account = _account(); nextSigner = vm.addr(nextKey); quote = new bytes(632);
    }
    function _account() internal returns (NoerraAgentAccount result) {
        vm.prank(human);
        (, address deployed) = registry.create(human, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        result = NoerraAgentAccount(deployed);
    }
    function _approve() internal {
        vm.prank(human);
        account.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 2 days, 0.001 ether);
    }
    function _signature(bytes32 commitment) internal view returns (bytes memory) {
        return _signatureFor(nextKey, commitment);
    }
    function _signatureFor(uint256 key, bytes32 commitment) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", commitment)));
        return abi.encodePacked(r, s, v);
    }
    function _output(bytes32 commitment) internal view returns (bytes memory result) {
        result = new bytes(597); result[1] = 0x04; result[5] = 0x81;
        bytes32 fresh = verifier.freshness(99, anchorHash);
        assembly { mstore(add(result, 565), commitment) mstore(add(result, 597), fresh) }
    }
    function _register() internal returns (bytes32 commitment, bytes memory signature, bytes memory evidence) {
        commitment = account.automaticActivationCommitment(1, nextSigner, destination);
        signature = _signature(commitment); dcap.set(_output(commitment), true);
        evidence = abi.encodePacked(verifier.register(quote, commitment, 99, anchorHash));
    }
    function _assertCancelled() internal {
        (bytes32 approved,,,,) = account.automaticActivation(); assertEq(approved, bytes32(0));
        vm.expectRevert("Activation approval"); account.automaticActivationCommitment(1, nextSigner, destination);
    }
    function _activate() internal {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register();
        dollar.mint(address(account), 50e6);
        account.activateApproved(1, nextSigner, destination, signature, evidence);
        assertTrue(account.automaticPayer());
    }
    function _handover(uint256 key) internal returns (address receiver) {
        receiver = vm.addr(key);
        uint256 currentGeneration = account.generation();
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(account), account.agentId(),
            currentGeneration, account.buildHash(), receiver, destination));
        bytes memory signature = _signatureFor(key, commitment);
        vm.prank(account.signer()); account.handover(currentGeneration, receiver, destination, signature);
    }
    function _assertFollowing(address prior, address receiver) internal {
        assertEq(account.generation(), 3); assertEq(account.signer(), receiver);
        assertTrue(account.automaticPayer()); assertTrue(account.recipients(receiver));
        assertFalse(account.recipients(prior));
        vm.prank(receiver); vm.expectRevert("Payment policy");
        account.pay(3, keccak256("old recipient"), prior, 1e6);
        vm.prank(prior); vm.expectRevert("Runtime generation");
        account.pay(3, keccak256("old authority"), receiver, 1e6);
        uint256 beforeSpent = account.spentToday();
        vm.prank(receiver); account.pay(3, keccak256("current refill"), receiver, 1e6);
        assertEq(dollar.balanceOf(receiver), 1e6); assertEq(account.spentToday(), beforeSpent + 1e6);
        assertEq(account.dailyLimit(), 10e6); assertEq(account.hostingReserve(), 5e6);
    }

    function testAutomaticPayerFollowsHandoverWithoutResettingLimitsOrOperations() public {
        _activate();
        vm.prank(nextSigner); account.pay(2, keccak256("first runtime refill"), nextSigner, 2e6);
        uint256 nonce = account.activationPolicyNonce();
        address receiver = _handover(0x345678);
        _assertFollowing(nextSigner, receiver);
        assertEq(account.activationPolicyNonce(), nonce);
        assertEq(account.spentToday(), 3e6); assertTrue(account.operations(keccak256("first runtime refill")));
        vm.prank(receiver); vm.expectRevert("Daily limit");
        account.pay(3, keccak256("excess"), receiver, 8e6);
    }
    function testAutomaticPayerFollowsFreshAttestedRecovery() public {
        _activate(); bytes32 checkpoint = keccak256("encrypted checkpoint");
        vm.prank(nextSigner); account.checkpoint(2, checkpoint);
        vm.warp(block.timestamp + account.STALE_AFTER() + 1);
        address receiver = vm.addr(0x345678);
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(account), account.agentId(),
            uint256(2), checkpoint, account.buildHash(), receiver));
        dcap.set(_output(commitment), true); quote[0] = 0x01;
        bytes memory evidence = abi.encodePacked(verifier.register(quote, commitment, 99, anchorHash));
        account.recover(receiver, evidence);
        _assertFollowing(nextSigner, receiver);
        assertEq(account.checkpointHash(), checkpoint);
    }
    function testAutomaticPayerFollowsPaidRecoveryAndReceiverHandoverWithoutChangingEscrow() public {
        bytes memory paidMeasurements = new bytes(240); paidMeasurements[0] = 0x11;
        NoerraPaidRecoveryVerifier paidVerifier = new NoerraPaidRecoveryVerifier(dcap, address(dcap).codehash,
            keccak256(new bytes(240)), keccak256(paidMeasurements));
        verifier = paidVerifier; registry = new NoerraAgentRegistry(dollar, verifier); account = _account();
        vm.prank(human); account.setRecoveryPolicy(1e6, 1e6);
        _activate();
        vm.startPrank(nextSigner); account.allocateRecoveryReserve(2, 2e6);
        account.checkpoint(2, keccak256("encrypted checkpoint")); vm.stopPrank();
        vm.warp(block.timestamp + account.STALE_AFTER() + 1);
        address receiver = vm.addr(0x345678);
        NoerraAgentAccount.PaidRecoveryRequest memory request = NoerraAgentAccount.PaidRecoveryRequest(
            2, receiver, address(0xB1), 1e6, 1e6, keccak256("recovery job"),
            keccak256("approved lease"), block.timestamp + 1 hours);
        bytes32 commitment = account.paidRecoveryCommitment(request);
        bytes memory out = _output(commitment); out[149] = 0x11; dcap.set(out, true); quote[0] = 0x02;
        bytes memory evidence = abi.encodePacked(paidVerifier.registerPaid(quote, commitment, 99, anchorHash));
        account.recoverForOperator(request, evidence);
        _assertFollowing(nextSigner, receiver);
        assertEq(account.recoveryReserve(), 2e6); assertEq(account.recoveryPolicyNonce(), 1);
        assertFalse(account.recipients(request.operator));
        address computer = _handover(0x456789);
        assertEq(account.generation(), 4); assertFalse(account.recipients(receiver));
        assertTrue(account.recipients(computer));
        vm.prank(computer); account.pay(4, keccak256("recovered computer refill"), computer, 1e6);
        assertEq(account.recoveryReserve(), 2e6);
        (bytes32 job,,,,uint256 recoveryGeneration,,,,,bytes32 handoverDestination) = account.paidRecovery();
        assertEq(job, request.jobId); assertEq(recoveryGeneration, 3); assertEq(handoverDestination, destination);
    }
    function testHumanRecipientRevocationDisablesAutomaticFollowing() public {
        _activate(); vm.prank(human); account.setRecipient(nextSigner, false);
        assertFalse(account.automaticPayer());
        address receiver = _handover(0x345678);
        assertFalse(account.recipients(nextSigner)); assertFalse(account.recipients(receiver));
        vm.prank(receiver); vm.expectRevert("Payment policy");
        account.pay(3, keccak256("revocation cannot rotate away"), receiver, 1e6);
    }
    function testHumanExplicitRecipientPermissionsSurviveAutomaticRotation() public {
        _activate(); address receiver = vm.addr(0x345678);
        vm.startPrank(human); account.setRecipient(nextSigner, true); account.setRecipient(receiver, true); vm.stopPrank();
        _handover(0x345678); assertTrue(account.recipients(nextSigner));
        _handover(0x456789); assertTrue(account.recipients(receiver));
        assertTrue(account.automaticPayer());
    }
    function testLegacyHandoverDoesNotEnableAutomaticPayerOrChangeHumanPermissions() public {
        vm.prank(human); account.setRecipient(human, true);
        address receiver = _handover(0x345678);
        assertFalse(account.automaticPayer()); assertTrue(account.recipients(human));
        assertFalse(account.recipients(receiver));
        vm.prank(receiver); vm.expectRevert("Payment policy");
        account.pay(2, keccak256("legacy requires human policy"), receiver, 1e6);
    }

    function testZeroFundApprovalThenPermissionlessAtomicActivationWithCappedGas() public {
        _approve(); assertEq(dollar.balanceOf(address(account)), 0);
        bytes32 commitment = account.automaticActivationCommitment(1, nextSigner, destination);
        dcap.set(_output(commitment), true); bytes memory signature = _signature(commitment);
        vm.expectRevert("Activation funding");
        verifier.registerAndActivate(address(account), 1, nextSigner, destination, signature, quote, 99, anchorHash, 0);
        (bytes32 registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        dollar.mint(address(account), 15e6); vm.deal(address(0xB1), 1 ether);
        vm.prank(address(0xB1));
        verifier.registerAndActivate{value: 0.002 ether}(address(account), 1, nextSigner, destination,
            signature, quote, 99, anchorHash, 0.001 ether);
        assertEq(account.signer(), nextSigner); assertEq(account.generation(), 2);
        assertEq(nextSigner.balance, 0.001 ether); assertEq(address(dcap).balance, 0.001 ether);
        assertEq(dollar.balanceOf(address(account)), 15e6);
        assertTrue(account.recipients(nextSigner)); assertFalse(account.recipients(address(0xB1)));
        (bytes32 approved,,,,) = account.automaticActivation(); assertEq(approved, bytes32(0));
    }
    function testApprovalOnlyInitialHumanAndBounds() public {
        vm.expectRevert("Human only"); account.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 1, 1);
        vm.startPrank(human);
        vm.expectRevert("Initial human authority"); account.approveAutomaticActivation(2, intent, 15e6, block.timestamp + 1, 1);
        vm.expectRevert("Activation configuration"); account.approveAutomaticActivation(1, bytes32(0), 15e6, block.timestamp + 1, 1);
        vm.expectRevert("Activation balance bounds"); account.approveAutomaticActivation(1, intent, 5e6, block.timestamp + 1, 1);
        vm.expectRevert("Activation balance bounds"); account.approveAutomaticActivation(1, intent, 100_000e6 + 1, block.timestamp + 1, 1);
        vm.expectRevert("Activation expiry bounds"); account.approveAutomaticActivation(1, intent, 15e6, block.timestamp, 1);
        vm.expectRevert("Activation expiry bounds"); account.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 30 days + 1, 1);
        vm.expectRevert("Activation gas bounds"); account.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 1, 0);
        vm.expectRevert("Activation gas bounds"); account.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 1, 0.01 ether + 1);
        account.approveAutomaticActivation(1, intent, 5e6 + 1, block.timestamp + 30 days, 0.01 ether);
        vm.stopPrank();
        NoerraAgentRegistry noVerifier = new NoerraAgentRegistry(dollar, IAgentRecoveryVerifier(address(0)));
        vm.prank(human); (, address deployed) = noVerifier.create(human, intent, intent, 1, 1, "", "");
        vm.prank(human); vm.expectRevert("Activation configuration");
        NoerraAgentAccount(deployed).approveAutomaticActivation(1, intent, 2, block.timestamp + 1, 1);
    }
    function testPolicyChangesAndCancellationInvalidateEvidence() public {
        _approve(); uint256 prior = account.activationPolicyNonce();
        vm.prank(human); account.setRecipient(address(0xD1), true); _assertCancelled();
        assertEq(account.activationPolicyNonce(), prior + 1);
        _approve(); vm.prank(human); account.setDailyLimit(11e6); _assertCancelled();
        _approve(); vm.prank(human); account.setRecoveryPolicy(1e6, 1e6); _assertCancelled();
        _approve(); vm.expectRevert("Human only"); account.cancelAutomaticActivation();
        vm.prank(human); account.cancelAutomaticActivation(); _assertCancelled();
        _approve(); vm.prank(human); account.offerHuman(address(0xD1));
        vm.prank(address(0xD1)); account.acceptHuman();
        (bytes32 approved,,,,) = account.automaticActivation(); assertEq(approved, bytes32(0));
        vm.expectRevert("Initial human authority"); account.automaticActivationCommitment(1, nextSigner, destination);
    }
    function testReapprovalCannotReuseOldRegisteredQuote() public {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register();
        dollar.mint(address(account), 15e6); _approve();
        vm.expectRevert("Activation acceptance"); account.activateApproved(1, nextSigner, destination, signature, evidence);
        signature = _signature(account.automaticActivationCommitment(1, nextSigner, destination));
        vm.expectRevert("Activation evidence"); account.activateApproved(1, nextSigner, destination, signature, evidence);
    }
    function testAcceptanceAndAttestationBindExactAccountChainGenerationAndDestination() public {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register(); dollar.mint(address(account), 15e6);
        vm.expectRevert("Initial human authority"); account.activateApproved(2, nextSigner, destination, signature, evidence);
        vm.expectRevert("Activation acceptance"); account.activateApproved(1, nextSigner, keccak256("other destination"), signature, evidence);
        bytes memory correctOtherSignature = _signature(account.automaticActivationCommitment(1, nextSigner, keccak256("other destination")));
        vm.expectRevert("Activation evidence"); account.activateApproved(1, nextSigner, keccak256("other destination"), correctOtherSignature, evidence);
        vm.chainId(8453);
        correctOtherSignature = _signature(account.automaticActivationCommitment(1, nextSigner, destination));
        vm.expectRevert("Activation evidence"); account.activateApproved(1, nextSigner, destination, correctOtherSignature, evidence);
        vm.chainId(1);
        NoerraAgentAccount other = _account(); vm.prank(human);
        other.approveAutomaticActivation(1, intent, 15e6, block.timestamp + 2 days, 0.001 ether);
        dollar.mint(address(other), 15e6);
        correctOtherSignature = _signature(other.automaticActivationCommitment(1, nextSigner, destination));
        vm.expectRevert("Activation evidence"); other.activateApproved(1, nextSigner, destination, correctOtherSignature, evidence);
    }
    function testExpiredOrStaleEvidenceCannotActivate() public {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register(); dollar.mint(address(account), 15e6);
        vm.roll(227); vm.expectRevert("Activation evidence"); account.activateApproved(1, nextSigner, destination, signature, evidence);
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert("Activation expired"); account.activateApproved(1, nextSigner, destination, signature, evidence);
    }
    function testActivationRetainsDailySpendOperationHistoryAndCannotReplay() public {
        dollar.mint(address(account), 50e6); vm.startPrank(human);
        account.setRecipient(address(0xD1), true); account.pay(1, keccak256("prior operation"), address(0xD1), 2e6);
        vm.stopPrank(); _approve(); (, bytes memory signature, bytes memory evidence) = _register();
        account.activateApproved(1, nextSigner, destination, signature, evidence);
        assertEq(account.dailyLimit(), 10e6); assertEq(account.hostingReserve(), 5e6);
        assertEq(account.spentToday(), 2e6); assertTrue(account.operations(keccak256("prior operation")));
        vm.expectRevert("Initial human authority"); account.activateApproved(1, nextSigner, destination, signature, evidence);
        vm.prank(human); vm.expectRevert("Initial human authority");
        account.approveAutomaticActivation(2, intent, 15e6, block.timestamp + 2 days, 1);
        vm.prank(nextSigner); vm.expectRevert("Daily limit"); account.pay(2, keccak256("over limit"), nextSigner, 9e6);
        vm.prank(nextSigner); account.pay(2, keccak256("refill"), nextSigner, 8e6);
        assertEq(dollar.balanceOf(nextSigner), 8e6); assertEq(account.spentToday(), 10e6);
    }
    function testGasCapAndProtectedReserveGrowthDoNotPermitPrematureActivation() public {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register(); dollar.mint(address(account), 15e6);
        vm.deal(address(this), 1 ether);
        vm.expectRevert("Activation signer gas");
        account.activateApproved{value: 0.001 ether + 1}(1, nextSigner, destination, signature, evidence);
        dollar.mint(address(this), 5e6); dollar.approve(address(account), 5e6); account.fundRecoveryReserve(5e6);
        // Approval still requires the stored threshold and the now-protected reserve.
        account.activateApproved(1, nextSigner, destination, signature, evidence);
        assertEq(account.recoveryReserve(), 5e6); assertEq(dollar.balanceOf(address(account)), 20e6);
    }
    function testNewProtectedEscrowCannotBeMistakenForSpendableStartupFunds() public {
        vm.prank(human);
        account.approveAutomaticActivation(1, intent, 5e6 + 1, block.timestamp + 2 days, 0.001 ether);
        (, bytes memory signature, bytes memory evidence) = _register();
        dollar.mint(address(account), 5e6 + 1);
        dollar.mint(address(this), 5e6); dollar.approve(address(account), 5e6); account.fundRecoveryReserve(5e6);
        vm.expectRevert("Activation funding"); account.activateApproved(1, nextSigner, destination, signature, evidence);
        assertEq(account.signer(), human); assertEq(account.generation(), 1);
    }
    function testManualHandoverCannotLeaveExecutableDeferredApproval() public {
        _approve(); (, bytes memory signature, bytes memory evidence) = _register();
        bytes32 normalCommitment = keccak256(abi.encode(block.chainid, address(account), account.agentId(),
            uint256(1), account.buildHash(), nextSigner, destination));
        vm.prank(human); account.handover(1, nextSigner, destination, _signature(normalCommitment));
        vm.expectRevert("Initial human authority"); account.activateApproved(1, nextSigner, destination, signature, evidence);
    }
    function testLegacyTokenBuilderOnlyRegistryAndOriginalAccountAllocation() public {
        assertEq(account.registry(), address(registry));
        NoerraRegistryTokenDeployer builder = registry.creationTokenDeployer();
        assertEq(builder.registry(), address(registry));
        vm.expectRevert("Registry only"); builder.deploy("Forbidden", "BAD", address(this));
        vm.prank(human); (bytes32 id, address deployed) = registry.create(human, intent, intent, 5e6, 10e6, "Legacy", "OLD");
        AgentTestDollar token = AgentTestDollar(registry.tokens(id));
        assertEq(token.totalSupply(), 1_000_000_000 ether); assertEq(token.balanceOf(deployed), token.totalSupply());
    }
    function testChangedVerifierAndInvalidMeasurementRollBackAtomicRegistration() public {
        _approve(); dollar.mint(address(account), 15e6);
        bytes32 commitment = account.automaticActivationCommitment(1, nextSigner, destination);
        bytes memory signature = _signature(commitment);
        bytes memory out = _output(commitment); out[149] = 0x01;
        dcap.set(out, true); vm.expectRevert("Measured application");
        verifier.registerAndActivate(address(account), 1, nextSigner, destination, signature, quote, 99, anchorHash, 0);
        (bytes32 registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        dcap.set(_output(commitment), true); vm.etch(address(dcap), hex"60006000f3");
        vm.expectRevert("Verifier changed");
        verifier.registerAndActivate(address(account), 1, nextSigner, destination, signature, quote, 99, anchorHash, 0);
    }
    function testExistingHandoverAcceptanceCannotAuthorizeAutomaticActivation() public {
        _approve(); (, , bytes memory evidence) = _register(); dollar.mint(address(account), 15e6);
        bytes32 oldCommitment = keccak256(abi.encode(block.chainid, address(account), account.agentId(),
            uint256(1), account.buildHash(), nextSigner, destination));
        vm.expectRevert("Activation acceptance");
        account.activateApproved(1, nextSigner, destination, _signature(oldCommitment), evidence);
    }
}
