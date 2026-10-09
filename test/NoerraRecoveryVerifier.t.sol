// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraRecoveryVerifier, NoerraPaidRecoveryVerifier, INoerraDcapAttestation} from "../src/agents/NoerraRecoveryVerifier.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";

// Explicit DCAP fixture: these tests validate policy, not Intel signatures.
contract RecoveryDcapFixture is INoerraDcapAttestation {
    bytes public output; bool public success = true;
    function set(bytes memory value, bool accepted) external { output = value; success = accepted; }
    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) { return (success, output); }
}

contract NoerraPaidRecoveryVerifierTest is Test {
    RecoveryDcapFixture dcap;
    NoerraPaidRecoveryVerifier verifier;
    bytes32 anchorHash = keccak256("paid recovery anchor");
    bytes quote;
    function setUp() public {
        vm.roll(100); vm.setBlockhash(99, anchorHash);
        dcap = new RecoveryDcapFixture(); bytes memory measurements = new bytes(240); measurements[0] = 0x11;
        verifier = new NoerraPaidRecoveryVerifier(dcap, address(dcap).codehash,
            keccak256(new bytes(240)), keccak256(measurements));
        quote = new bytes(632);
    }
    function output(bytes32 binding, bool paid) internal view returns (bytes memory result) {
        result = new bytes(597); result[1] = 0x04; result[5] = 0x81;
        if (paid) result[149] = 0x11;
        bytes32 fresh = verifier.freshness(99, anchorHash);
        assembly { mstore(add(result, 565), binding) mstore(add(result, 597), fresh) }
    }
    function testOriginalMeasurementsCannotClaimPaidOperatorRewardOrViceVersa() public {
        bytes32 commitment = keccak256("paid bound commitment");
        dcap.set(output(commitment, false), true);
        bytes32 original = verifier.register(quote, commitment, 99, anchorHash);
        assertTrue(verifier.verify(abi.encodePacked(original), commitment));
        assertFalse(verifier.verifyPaid(abi.encodePacked(original), commitment));
        quote[0] = 0x01;
        vm.expectRevert("Measured application"); verifier.registerPaid(quote, commitment, 99, anchorHash);
        dcap.set(output(commitment, true), true);
        vm.expectRevert("Measured application"); verifier.register(quote, commitment, 99, anchorHash);
        bytes32 paid = verifier.registerPaid(quote, commitment, 99, anchorHash);
        assertTrue(verifier.verifyPaid(abi.encodePacked(paid), commitment));
        assertFalse(verifier.verify(abi.encodePacked(paid), commitment));
    }
    function testLegacyVerifierPaidModeCannotBeEnabled() public {
        NoerraRecoveryVerifier legacy = new NoerraRecoveryVerifier(dcap, address(dcap).codehash, keccak256(new bytes(240)));
        vm.expectRevert("Paid recovery disabled"); legacy.registerPaid(quote, keccak256("commitment"), 99, anchorHash);
        assertFalse(legacy.verifyPaid(abi.encodePacked(keccak256(quote)), keccak256("commitment")));
    }
    function testAtomicTwoPhaseRegistrationRecoveryHandoverAndPayout() public {
        (NoerraAgentAccount account, AgentTestDollar dollar) = createAccount();
        NoerraAgentAccount.PaidRecoveryRequest memory row = request();
        dcap.set(output(account.paidRecoveryCommitment(row), true), true);
        vm.expectRevert("Runtime alive"); verifier.registerAndRecoverForOperator(address(account), row, quote, 99, anchorHash, 0);
        (bytes32 registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        vm.warp(block.timestamp + 3 hours + 1); row.deadline = block.timestamp + 1 hours;
        dcap.set(output(account.paidRecoveryCommitment(row), true), true);
        verifier.registerAndRecoverForOperator{value: 0.01 ether}(address(account), row, quote, 99, anchorHash, 0.001 ether);
        assertEq(row.nextSigner.balance, 0.001 ether); assertEq(dollar.balanceOf(row.operator), 0);
        handover(account);
        quote[0] = 0x01; bytes32 lease = keccak256("actual live replacement lease");
        dcap.set(output(account.paidRecoveryCompletionCommitment(row.jobId, lease), true), true);
        verifier.registerAndCompletePaidRecovery(address(account), row.jobId, lease, quote, 99, anchorHash);
        assertEq(dollar.balanceOf(row.operator), 12e6); assertEq(account.recoveryReserve(), 8e6);
        assertEq(account.signer(), vm.addr(0x123456)); assertEq(account.generation(), 3);
        vm.expectRevert("Recovery job"); verifier.registerAndCompletePaidRecovery(address(account), row.jobId, lease, quote, 99, anchorHash);
    }
    function testExpiredAtomicCompletionRollsBackQuoteRegistration() public {
        (NoerraAgentAccount account, AgentTestDollar dollar) = createAccount();
        vm.warp(block.timestamp + 3 hours + 1);
        NoerraAgentAccount.PaidRecoveryRequest memory row = request();
        dcap.set(output(account.paidRecoveryCommitment(row), true), true);
        verifier.registerAndRecoverForOperator(address(account), row, quote, 99, anchorHash, 0);
        handover(account); quote[0] = 0x01;
        bytes32 lease = keccak256("actual live replacement lease");
        dcap.set(output(account.paidRecoveryCompletionCommitment(row.jobId, lease), true), true);
        vm.warp(row.deadline + 1);
        vm.expectRevert("Recovery expired"); verifier.registerAndCompletePaidRecovery(address(account), row.jobId, lease, quote, 99, anchorHash);
        (bytes32 registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        assertFalse(verifier.paidRegistrations(keccak256(quote))); assertEq(dollar.balanceOf(row.operator), 0);
    }
    function createAccount() internal returns (NoerraAgentAccount account, AgentTestDollar dollar) {
        dollar = new AgentTestDollar(); NoerraAgentRegistry registry = new NoerraAgentRegistry(dollar, verifier);
        (, address deployed) = registry.create(address(0xA1), keccak256("metadata"), keccak256("build"), 50e6, 100e6, "", "");
        account = NoerraAgentAccount(deployed); dollar.mint(deployed, 100e6);
        account.setRecoveryPolicy(10e6, 2e6);
        vm.prank(address(0xA1)); account.allocateRecoveryReserve(1, 20e6);
        vm.prank(address(0xA1)); account.checkpoint(1, keccak256("checkpoint"));
    }
    function request() internal view returns (NoerraAgentAccount.PaidRecoveryRequest memory) {
        return NoerraAgentAccount.PaidRecoveryRequest(1, address(0xA2), address(0xA3), 10e6, 2e6,
            keccak256("job"), keccak256("lease plan"), block.timestamp + 1 hours);
    }
    function handover(NoerraAgentAccount account) internal {
        bytes32 destination = keccak256("accepted receiver manifest"); address receiver = vm.addr(0x123456);
        bytes32 binding = keccak256(abi.encode(block.chainid, address(account), account.agentId(), uint256(2), account.buildHash(), receiver, destination));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", binding)));
        vm.prank(address(0xA2)); account.handover(2, receiver, destination, abi.encodePacked(r,s,v));
    }
}
contract NoerraRecoveryVerifierTest is Test {
    RecoveryDcapFixture dcap;
    NoerraRecoveryVerifier verifier;
    bytes32 anchorHash = keccak256("confirmed anchor");
    bytes32 commitment = keccak256("account generation checkpoint build signer");
    bytes quote;
    function setUp() public {
        vm.roll(100); vm.setBlockhash(99, anchorHash);
        dcap = new RecoveryDcapFixture();
        verifier = new NoerraRecoveryVerifier(dcap, address(dcap).codehash, keccak256(new bytes(240)));
        quote = new bytes(632); dcap.set(output(commitment), true);
    }
    function output(bytes32 binding) internal view returns (bytes memory result) {
        result = new bytes(597); result[1] = 0x04; result[5] = 0x81;
        bytes32 fresh = verifier.freshness(99, anchorHash);
        assembly { mstore(add(result, 565), binding) mstore(add(result, 597), fresh) }
    }
    function register() internal returns (bytes32) { return verifier.register(quote, commitment, 99, anchorHash); }
    function testFreshQuoteOnlyMatchesExactCommitmentAndExpires() public {
        bytes32 q = register(); assertTrue(verifier.verify(abi.encodePacked(q), commitment));
        assertFalse(verifier.verify(abi.encodePacked(q), bytes32(uint256(1))));
        assertFalse(verifier.verify("", commitment));
        vm.expectRevert("Quote registered"); register();
        vm.roll(227); assertFalse(verifier.verify(abi.encodePacked(q), commitment));
    }
    function testRejectsDebugTCBMeasurementBindingAndFailedVerification() public {
        bytes memory out = output(commitment); out[133] = 0x01; dcap.set(out, true);
        vm.expectRevert("Debug TDX"); register();
        out = output(commitment); out[6] = 0x01; dcap.set(out, true);
        vm.expectRevert("TDX up to date only"); register();
        out = output(commitment); out[149] = 0x01; dcap.set(out, true);
        vm.expectRevert("Measured application"); register();
        dcap.set(output(bytes32(uint256(1))), true); vm.expectRevert("Recovery binding"); register();
        out = output(commitment); out[596] = bytes1(uint8(out[596]) ^ 1); dcap.set(out, true);
        vm.expectRevert("Recovery binding"); register();
        dcap.set(output(commitment), false); vm.expectRevert("DCAP verification"); register();
    }
    function testRejectsAdvisoriesStaleAnchorAndChangedVerifier() public {
        string[] memory advisory = new string[](1); advisory[0] = "INTEL-SA-fixture";
        dcap.set(bytes.concat(output(commitment), abi.encode(advisory)), true);
        vm.expectRevert("TCB advisories"); register();
        vm.expectRevert("Fresh anchor"); verifier.register(quote, commitment, 99, bytes32(uint256(1)));
        vm.etch(address(dcap), hex"60006000f3"); vm.expectRevert("Verifier changed"); register();
    }
    function testFuzzWrongCommitmentCannotRecover(bytes32 wrong) public {
        vm.assume(wrong != commitment); bytes32 q = register(); assertFalse(verifier.verify(abi.encodePacked(q), wrong));
    }
    function testRegisteredQuoteRotatesOnlyStaleExactAccountGeneration() public {
        AgentTestDollar dollar = new AgentTestDollar(); NoerraAgentRegistry registry = new NoerraAgentRegistry(dollar, verifier);
        (bytes32 id, address deployed) = registry.create(address(0xA1), keccak256("metadata"), keccak256("build"), 1, 1, "", "");
        NoerraAgentAccount account = NoerraAgentAccount(deployed); bytes32 checkpoint = keccak256("encrypted checkpoint");
        vm.prank(address(0xA1)); account.checkpoint(1, checkpoint);
        commitment = keccak256(abi.encode(block.chainid, deployed, id, uint256(1), checkpoint, keccak256("build"), address(0xA2)));
        dcap.set(output(commitment), true); bytes32 q = register();
        vm.expectRevert("Runtime alive"); account.recover(address(0xA2), abi.encodePacked(q));
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert("Recovery evidence"); account.recover(address(0xA3), abi.encodePacked(q));
        account.recover(address(0xA2), abi.encodePacked(q)); assertEq(account.generation(), 2);
        vm.prank(address(0xA1)); vm.expectRevert("Runtime generation"); account.pulse(1);
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert("Recovery evidence"); account.recover(address(0xA3), abi.encodePacked(q));
    }

    function testAtomicRecoveryCannotLeaveRegistrationAfterFailedRotation() public {
        AgentTestDollar dollar = new AgentTestDollar(); NoerraAgentRegistry registry = new NoerraAgentRegistry(dollar, verifier);
        (bytes32 id, address deployed) = registry.create(address(0xA1), keccak256("metadata"), keccak256("build"), 1, 1, "", "");
        NoerraAgentAccount account = NoerraAgentAccount(deployed); bytes32 checkpoint = keccak256("encrypted checkpoint");
        vm.prank(address(0xA1)); account.checkpoint(1, checkpoint);
        commitment = keccak256(abi.encode(block.chainid, deployed, id, uint256(1), checkpoint, keccak256("build"), address(0xA2)));
        dcap.set(output(commitment), true);
        vm.expectRevert("Runtime alive"); verifier.registerAndRecover(deployed, address(0xA2), quote, commitment, 99, anchorHash, 0);
        (bytes32 registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert("Recovery evidence"); verifier.registerAndRecover(deployed, address(0xA3), quote, commitment, 99, anchorHash, 0);
        (registered,) = verifier.registrations(keccak256(quote)); assertEq(registered, bytes32(0));
        verifier.registerAndRecover{value: 1 ether}(deployed, address(0xA2), quote, commitment, 99, anchorHash, 0.1 ether);
        assertEq(address(dcap).balance, 0.9 ether); assertEq(address(0xA2).balance, 0.1 ether);
        assertEq(account.generation(), 2); assertEq(account.signer(), address(0xA2));
        vm.prank(address(0xA1)); vm.expectRevert("Runtime generation"); account.pulse(1);
    }
}
