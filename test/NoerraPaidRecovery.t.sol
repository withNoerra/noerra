// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {AgentTestDollar, AgentTestVerifier} from "./NoerraAgents.t.sol";

contract RecoveryDollar is AgentTestDollar {
    address public blocked;
    bool public chargeFee;
    function setBlocked(address value) external { blocked = value; }
    function setFee(bool value) external { chargeFee = value; }
    function _update(address from, address to, uint256 amount) internal override {
        require(to != blocked || to == address(0), "Recipient blocked");
        if (chargeFee && from != address(0) && to != address(0) && amount > 1) {
            super._update(from, address(0), 1);
            super._update(from, to, amount - 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract PaidTestVerifier is AgentTestVerifier {
    function verifyPaid(bytes calldata evidence, bytes32 commitment) external view returns (bool) {
        return commitment == accepted && keccak256(evidence) == keccak256("synthetic attestation");
    }
}

contract NoerraPaidRecoveryTest is Test {
    RecoveryDollar dollar;
    PaidTestVerifier verifier;
    NoerraAgentRegistry registry;
    NoerraAgentAccount account;
    address human = address(0xA1);
    address runtime = address(0xB1);
    address starter = address(0xC1);
    address operator = address(0xD1);
    uint256 receiverKey = 0x123456;
    bytes32 actualLease = keccak256("verified replacement lease");
    bytes32 destination = keccak256("accepted replacement manifest");

    function setUp() public {
        dollar = new RecoveryDollar(); verifier = new PaidTestVerifier();
        registry = new NoerraAgentRegistry(dollar, verifier);
        vm.prank(human);
        (,address deployed) = registry.create(runtime, keccak256("metadata"), keccak256("build"), 50e6, 100e6, "", "");
        account = NoerraAgentAccount(deployed);
        dollar.mint(deployed, 100e6);
        vm.prank(human); account.setRecoveryPolicy(10e6, 2e6);
        vm.prank(human); account.setRecipient(operator, true);
        vm.prank(runtime); account.allocateRecoveryReserve(1, 20e6);
        vm.prank(runtime); account.pulseCheckpoint(1, keccak256("encrypted checkpoint"));
        vm.warp(block.timestamp + 3 hours + 1);
    }
    function request() internal view returns (NoerraAgentAccount.PaidRecoveryRequest memory) {
        return NoerraAgentAccount.PaidRecoveryRequest(1, starter, operator, 10e6, 2e6,
            keccak256("operator job"), keccak256("approved lease plan"), block.timestamp + 1 hours);
    }
    function reserve() internal returns (NoerraAgentAccount.PaidRecoveryRequest memory row) {
        row = request(); verifier.set(account.paidRecoveryCommitment(row));
        account.recoverForOperator(row, "synthetic attestation");
    }
    function handover() internal {
        address receiver = vm.addr(receiverKey);
        bytes32 binding = keccak256(abi.encode(block.chainid, address(account), account.agentId(),
            uint256(2), account.buildHash(), receiver, destination));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(receiverKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", binding)));
        vm.prank(starter); account.handover(2, receiver, destination, abi.encodePacked(r,s,v));
    }
    function complete(bytes32 jobId) internal {
        verifier.set(account.paidRecoveryCompletionCommitment(jobId, actualLease));
        account.completePaidRecovery(jobId, actualLease, "synthetic attestation");
    }
    function testReserveDoesNotPayThenMeasuredHandoverCompletesExactlyOnce() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = reserve();
        assertEq(account.signer(), starter); assertEq(account.generation(), 2);
        assertEq(dollar.balanceOf(operator), 0); assertEq(account.recoveryReserve(), 20e6);
        vm.expectRevert("Recovery handover"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        handover();
        vm.expectRevert("Recovery evidence"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        complete(row.jobId);
        assertEq(account.signer(), vm.addr(receiverKey)); assertEq(account.generation(), 3);
        assertEq(dollar.balanceOf(operator), 12e6); assertEq(dollar.balanceOf(address(account)), 88e6);
        assertEq(account.recoveryReserve(), 8e6); assertTrue(account.recoveryJobsUsed(row.jobId));
        vm.expectRevert("Recovery job"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
    }
    function testEveryRequestFieldAndDomainBoundAgainstFrontRunning() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = request();
        bytes32 original = account.paidRecoveryCommitment(row); verifier.set(original);
        row.operator = address(0xE1);
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.reimbursement--;
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.jobId = keccak256("another job");
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.leaseCommitment = keccak256("another lease plan");
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.deadline++;
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); vm.chainId(block.chainid + 1);
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        assertEq(dollar.balanceOf(operator), 0); assertEq(account.generation(), 1);
    }
    function testChangedPolicyInvalidatesOldQuoteAndPendingPolicyCannotChange() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = request(); verifier.set(account.paidRecoveryCommitment(row));
        vm.prank(human); account.setRecoveryPolicy(10e6, 2e6);
        vm.expectRevert("Recovery evidence"); account.recoverForOperator(row, "synthetic attestation");
        reserve();
        vm.prank(human); vm.expectRevert("Recovery pending"); account.setRecoveryPolicy(1, 0);
    }
    function testReservePreservesHostingFloorAndDoesNotResetSpentToday() public {
        vm.prank(runtime); account.pay(1, keccak256("earlier"), operator, 5e6);
        vm.prank(runtime); account.allocateRecoveryReserve(1, 5e6);
        assertEq(account.spentToday(), 5e6); assertEq(account.recoveryReserve(), 25e6);
        vm.prank(runtime); vm.expectRevert("Hosting reserve"); account.pay(1, keccak256("drain"), operator, 21e6);
        vm.prank(runtime); account.pay(1, keccak256("allowed"), operator, 20e6);
        assertEq(dollar.balanceOf(address(account)), 75e6);
        vm.prank(runtime); vm.expectRevert("Hosting reserve"); account.allocateRecoveryReserve(1, 1);
    }
    function testRecoveryPolicyAndFundingAreFiniteAndHumanControlled() public {
        vm.expectRevert("Human only"); account.setRecoveryPolicy(1, 1);
        vm.prank(human); vm.expectRevert("Recovery cap"); account.setRecoveryPolicy(50e6, 1);
        vm.prank(runtime); vm.expectRevert("Recovery cap"); account.allocateRecoveryReserve(1, 31e6);
        vm.prank(runtime); vm.expectRevert("Runtime generation"); account.allocateRecoveryReserve(2, 1);
        vm.prank(human); account.setRecoveryPolicy(0, 0);
        NoerraAgentAccount.PaidRecoveryRequest memory row = request();
        vm.expectRevert("Recovery policy"); account.recoverForOperator(row, "synthetic attestation");
        dollar.mint(address(this), 30e6); dollar.approve(address(account), 30e6);
        account.fundRecoveryReserve(30e6);
        assertEq(account.recoveryReserve(), 50e6);
        vm.expectRevert("Recovery cap"); account.fundRecoveryReserve(1);
    }
    function testFeeOnTransferRecoveryFundingRejectedAtomically() public {
        dollar.mint(address(this), 10e6); dollar.approve(address(account), 10e6); dollar.setFee(true);
        vm.expectRevert("Exact recovery funding"); account.fundRecoveryReserve(10e6);
        assertEq(account.recoveryReserve(), 20e6); assertEq(dollar.balanceOf(address(this)), 10e6);
    }
    function testExpiryOnlyReleasesReservationAndNeverReusesJob() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = reserve(); handover();
        vm.expectRevert("Recovery not expired"); account.cancelPaidRecovery();
        vm.warp(row.deadline + 1);
        verifier.set(account.paidRecoveryCompletionCommitment(row.jobId, actualLease));
        vm.expectRevert("Recovery expired"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        account.cancelPaidRecovery();
        assertEq(account.recoveryReserve(), 20e6); assertEq(dollar.balanceOf(operator), 0);
        vm.warp(block.timestamp + 3 hours + 1);
        row.expectedGeneration = 3; row.deadline = block.timestamp + 1 hours;
        vm.expectRevert("Recovery job used"); account.recoverForOperator(row, "synthetic attestation");
    }
    function testLeaseAndLatestCheckpointAreBoundAtCompletion() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = reserve(); handover();
        verifier.set(account.paidRecoveryCompletionCommitment(row.jobId, actualLease));
        vm.expectRevert("Recovery evidence"); account.completePaidRecovery(row.jobId, keccak256("substituted lease"), "synthetic attestation");
        vm.prank(vm.addr(receiverKey)); account.checkpoint(3, keccak256("new checkpoint"));
        vm.expectRevert("Recovery evidence"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        complete(row.jobId); assertEq(dollar.balanceOf(operator), 12e6);
    }
    function testUnrelatedLegacyRecoveryCannotStandInForHandover() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = request(); row.deadline = block.timestamp + 1 days;
        verifier.set(account.paidRecoveryCommitment(row)); account.recoverForOperator(row, "synthetic attestation");
        vm.warp(block.timestamp + 3 hours + 1);
        address receiver = vm.addr(receiverKey);
        verifier.set(keccak256(abi.encode(block.chainid,address(account),account.agentId(),uint256(2),
            account.checkpointHash(),account.buildHash(),receiver)));
        account.recover(receiver, "synthetic attestation");
        vm.expectRevert("Recovery handover"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        assertEq(dollar.balanceOf(operator), 0);
    }
    function testBlockedPayoutLeavesReservationAndEscrowIntact() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = reserve(); handover(); dollar.setBlocked(operator);
        verifier.set(account.paidRecoveryCompletionCommitment(row.jobId, actualLease));
        vm.expectRevert("Recipient blocked"); account.completePaidRecovery(row.jobId, actualLease, "synthetic attestation");
        assertEq(account.recoveryReserve(), 20e6); assertEq(dollar.balanceOf(address(account)), 100e6);
        dollar.setBlocked(address(0)); complete(row.jobId); assertEq(dollar.balanceOf(operator), 12e6);
    }
    function testRequestBoundsAndUnfundedRecoveryNeverRotate() public {
        NoerraAgentAccount.PaidRecoveryRequest memory row = request(); row.expectedGeneration = 2;
        vm.expectRevert("Recovery generation"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.deadline = block.timestamp + 1 days + 1;
        vm.expectRevert("Recovery deadline"); account.recoverForOperator(row, "synthetic attestation");
        row = request(); row.reimbursement = 10e6 + 1;
        vm.expectRevert("Recovery policy"); account.recoverForOperator(row, "synthetic attestation");
        vm.prank(human); account.setRecoveryPolicy(30e6, 2e6); row.reimbursement = 30e6;
        vm.expectRevert("Recovery funding"); account.recoverForOperator(row, "synthetic attestation");
        assertEq(account.generation(), 1); assertEq(dollar.balanceOf(operator), 0);
    }
    function testFuzzPaidRewardConservesEscrowAndAccountFunds(uint64 reimbursement) public {
        reimbursement = uint64(bound(reimbursement, 0, 10e6));
        NoerraAgentAccount.PaidRecoveryRequest memory row = request(); row.reimbursement = reimbursement;
        verifier.set(account.paidRecoveryCommitment(row)); account.recoverForOperator(row, "synthetic attestation");
        handover(); complete(row.jobId);
        uint256 paid = uint256(reimbursement) + 2e6;
        assertEq(dollar.balanceOf(operator), paid); assertEq(account.recoveryReserve(), 20e6 - paid);
        assertEq(dollar.balanceOf(address(account)) + paid, 100e6);
        assertGe(dollar.balanceOf(address(account)), account.hostingReserve() + account.recoveryReserve());
    }
}
