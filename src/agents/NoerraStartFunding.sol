// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {NoerraStartClaims, INoerraStartAccount} from "./NoerraStartClaims.sol";

interface INoerraStartFundingAccount is INoerraStartAccount {
    function signer() external view returns (address);
    function recoveryReserve() external view returns (uint256);
    function maxRecoveryReimbursement() external view returns (uint256);
    function recoveryBounty() external view returns (uint256);
    function recoveryPolicyNonce() external view returns (uint256);
    function releaseStarterFunds(uint256 generation, address recipient, uint256 amount) external;
}

/// @notice A stopped account funds its measured starter once per generation.
/// The grant goes to the persistent agent cash wallet; the bounty is paid only
/// after a second attestation binds the delivered, running replacement.
abstract contract NoerraStartFunding is NoerraStartClaims {
    error InvalidStartFunding();
    bytes32 public constant START_FUNDING_DOMAIN = keccak256("NOERRA_START_FUNDING_V3");
    bytes32 public constant START_COMPLETION_DOMAIN = keccak256("NOERRA_START_COMPLETION_V3");
    struct StartFunding {
        address cash;
        address operator;
        uint256 reimbursement;
        uint256 bounty;
        uint256 policyNonce;
        bytes32 runId;
        uint256 deadline;
        bool completed;
    }
    mapping(address => mapping(uint256 => StartFunding)) public startFunding;
    event StartFunded(address indexed account, uint256 indexed generation, bytes32 indexed runId,
        address cash, address operator, uint256 reimbursement, uint256 bounty, bool reused);
    event StartCompleted(address indexed account, uint256 indexed generation, bytes32 indexed runId,
        address receiver, address operator, bytes32 lease, bytes32 destination, uint256 bounty);

    function _verifyStartFundingEvidence(bytes memory evidence, bytes32 commitment)
        internal view virtual returns (bool);

    /// @dev A claim whose run funded (or continued) the generation's start made progress: no claim cooldown.
    function _startProgressed(address account, StartClaim storage claim) internal view override returns (bool) {
        return super._startProgressed(account, claim) || startFunding[account][claim.generation].runId == claim.runId;
    }

    function startFundingCommitment(address account, bytes32 runId, address cash, address operator,
        uint256 reimbursement, uint256 bounty) public view returns (bytes32) {
        StartClaim memory claim = startClaims[account];
        bytes memory prefix = abi.encode(START_FUNDING_DOMAIN, block.chainid, address(this), account,
            claim.starter, runId, claim.generation, claim.pulse);
        return keccak256(bytes.concat(prefix, abi.encode(claim.checkpoint, claim.build,
            INoerraStartFundingAccount(account).recoveryPolicyNonce(), cash, operator, reimbursement, bounty)));
    }

    function _fundStart(address account, bytes32 runId, address cash, address operator,
        uint256 reimbursement, uint256 bounty, bytes memory evidence) internal {
        INoerraStartFundingAccount target = INoerraStartFundingAccount(account);
        StartClaim memory claim = startClaims[account];
        if (msg.sender != claim.starter || claim.runId != runId || !_current(target, claim) ||
            cash == address(0) || cash == account || cash == claim.starter || cash == target.signer() ||
            operator == address(0) || operator == account || reimbursement == 0 ||
            !_verifyStartFundingEvidence(evidence,
                startFundingCommitment(account, runId, cash, operator, reimbursement, bounty)))
            revert InvalidStartFunding();
        StartFunding storage row = startFunding[account][claim.generation];
        bool reused = row.cash != address(0);
        if (reused) {
            // A failed starter never authorizes another draw. A newly admitted
            // starter continues the same cash and can earn the unpaid bounty.
            if (row.completed || row.cash != cash || row.reimbursement != reimbursement ||
                row.bounty != bounty || row.policyNonce != target.recoveryPolicyNonce())
                revert InvalidStartFunding();
        } else {
            // The account's caps are read once, here, when the grant is first funded (a continuing starter reuses the record).
            if (reimbursement > target.maxRecoveryReimbursement() || bounty < target.recoveryBounty() ||
                bounty > _maxBounty(account) || target.recoveryReserve() < reimbursement + bounty) revert InvalidStartFunding();
            row.cash = cash;
            row.reimbursement = reimbursement;
            row.bounty = bounty;
            row.policyNonce = target.recoveryPolicyNonce();
        }
        // Reimbursement and bounty are checked against the account's gas-bounded caps once, at first funding, and
        // recorded; the grant, any continuing starter and the completion bounty use these recorded values (the account bounds
        // the releases by its escrow), so a later base-fee or price move can neither strand nor raise them.
        row.operator = operator;
        row.runId = runId;
        row.deadline = claim.maximumUntil + START_CLAIM_WINDOW;
        if (!reused) target.releaseStarterFunds(claim.generation, cash, reimbursement);
        emit StartFunded(account, claim.generation, runId, cash, operator, reimbursement, bounty, reused);
    }

    /// @dev The account's gas-bounded bounty cap (maxRecoveryBounty); accounts without it keep the exact bounty.
    function _maxBounty(address account) private view returns (uint256) {
        (bool ok, bytes memory answer) = account.staticcall(abi.encodeWithSignature("maxRecoveryBounty()"));
        return ok && answer.length == 32 ? abi.decode(answer, (uint256)) : INoerraStartFundingAccount(account).recoveryBounty();
    }

    function startCompletionCommitment(address account, uint256 generation, bytes32 runId,
        bytes32 lease, bytes32 destination) public view returns (bytes32) {
        INoerraStartFundingAccount target = INoerraStartFundingAccount(account);
        StartFunding memory row = startFunding[account][generation];
        // All fields are static ABI words, so concatenation preserves the original commitment.
        bytes memory prefix = abi.encode(START_COMPLETION_DOMAIN, block.chainid, address(this), account,
            generation, runId, row.cash, row.operator);
        return keccak256(bytes.concat(prefix, abi.encode(row.reimbursement, row.bounty, row.policyNonce,
            target.generation(), target.signer(), target.buildHash(), lease, destination)));
    }

    function _completeStart(address account, uint256 generation, bytes32 runId, bytes32 lease,
        bytes32 destination, bytes memory evidence) internal {
        INoerraStartFundingAccount target = INoerraStartFundingAccount(account);
        StartFunding storage row = startFunding[account][generation];
        StartClaim memory claim = startClaims[account];
        if (row.cash == address(0) || row.completed || row.runId != runId || block.timestamp > row.deadline ||
            claim.runId != runId || claim.generation != generation || claim.starter != msg.sender ||
            claim.action == bytes32(0) || claim.build != target.buildHash() || target.generation() != generation + 1 ||
            target.signer() == claim.starter || row.policyNonce != target.recoveryPolicyNonce() ||
            lease == bytes32(0) || destination == bytes32(0) ||
            !_verifyStartFundingEvidence(evidence,
                startCompletionCommitment(account, generation, runId, lease, destination)))
            revert InvalidStartFunding();
        row.completed = true;
        // C-7: the recovered generation (one below the account's) marks the completion bounty, never a new grant.
        if (row.bounty != 0) target.releaseStarterFunds(generation, row.operator, row.bounty);
        emit StartCompleted(account, generation + 1, runId, target.signer(), row.operator,
            lease, destination, row.bounty);
    }
}
