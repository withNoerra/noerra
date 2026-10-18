// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface INoerraStartAccount {
    function recoveryVerifier() external view returns (address);
    function generation() external view returns (uint256);
    function lastPulse() external view returns (uint256);
    function STALE_AFTER() external view returns (uint256);
    function checkpointHash() external view returns (bytes32);
    function buildHash() external view returns (bytes32);
    function automaticActivation() external view returns (bytes32,uint256,uint256,uint256,uint256);
    function paidRecovery() external view returns (bytes32,bytes32,address,address,uint256,uint256,uint256,uint256,bytes32,bytes32);
}

/// @notice Attested, single-action starter claims enforced by the account's verifier.
/// @dev No funds move here. Claiming opts an account into fenced activation/recovery
/// permanently; paid v2 starter handovers must then be rejected by the verifier.
abstract contract NoerraStartClaims {
    error InvalidStartClaim();
    uint256 public constant START_CLAIM_WINDOW = 20 minutes;
    uint256 public constant MAX_START_CLAIM_LIFETIME = 1 hours;
    /// @dev NoerraAgentAccount.FREEZE_TTL: a freeze lapses 72 h after it was reported.
    uint256 private constant ACCOUNT_FREEZE_TTL = 72 hours;
    bytes32 public constant START_CLAIM_DOMAIN = keccak256("NOERRA_START_CLAIM_V3");
    struct StartClaim {
        address starter;
        bytes32 runId;
        uint256 generation;
        uint256 pulse;
        bytes32 checkpoint;
        bytes32 build;
        uint256 expiresAt;
        uint256 maximumUntil;
        bytes32 action;
    }
    mapping(address => StartClaim) public startClaims;
    mapping(address => bool) public startFenceEnabled;
    mapping(address => mapping(bytes32 => bool)) public startRunUsed;
    mapping(address => bytes32) public startBirthApproval;
    /// @notice Slot griefing: a starter whose claim on an account ran out without progress (no bound action, no
    ///         funded start) while that account stayed exactly as it was claimed (same generation and liveness: nothing was
    ///         recovered, activated or revived) may not claim that account again for START_CLAIM_COOLDOWN after the expiry.
    ///         Renewals, other starters and a starter continuing its own funded or bound start are unaffected.
    uint256 public constant START_CLAIM_COOLDOWN = 6 hours;
    mapping(address => mapping(address => uint256)) public startClaimCooldownUntil;
    event StartClaimed(address indexed account, bytes32 indexed runId, address indexed starter, uint256 generation, uint256 expiresAt);
    event StartClaimRenewed(address indexed account, bytes32 indexed runId, uint256 expiresAt);
    event StartActionBound(address indexed account, bytes32 indexed runId, bytes32 action);

    function _verifyStartClaimEvidence(bytes memory evidence, bytes32 commitment) internal view virtual returns (bool);

    function startClaimCommitment(address account, address starter, bytes32 runId, uint256 expectedGeneration,
        uint256 expiresAt) public view returns (bytes32) {
        INoerraStartAccount target = INoerraStartAccount(account);
        return keccak256(abi.encode(START_CLAIM_DOMAIN, block.chainid, address(this), account, starter,
            runId, expectedGeneration, target.lastPulse(), target.checkpointHash(), target.buildHash(), expiresAt,
            expectedGeneration == 1 ? _birthApproval(target) : bytes32(0)));
    }

    function claimStart(address account, bytes32 runId, uint256 expectedGeneration, uint256 expiresAt,
        bytes calldata evidence) external {
        _claimStart(account,msg.sender,runId,expectedGeneration,expiresAt,evidence);
    }

    function _claimStart(address account,address starter,bytes32 runId,uint256 expectedGeneration,uint256 expiresAt,bytes memory evidence) internal {
        INoerraStartAccount target = INoerraStartAccount(account);
        if (account.code.length == 0 || runId == bytes32(0) || startRunUsed[account][runId] ||
            target.recoveryVerifier() != address(this) || target.generation() != expectedGeneration ||
            expiresAt <= block.timestamp || expiresAt > block.timestamp + START_CLAIM_WINDOW ||
            !_eligible(target) || _current(target, startClaims[account]) || _coolingDown(target, starter))
            revert InvalidStartClaim();
        if (!_verifyStartClaimEvidence(evidence, startClaimCommitment(account,starter,runId,expectedGeneration,expiresAt)))
            revert InvalidStartClaim();
        startRunUsed[account][runId] = true;
        startFenceEnabled[account] = true;
        startClaims[account] = StartClaim(starter,runId,expectedGeneration,target.lastPulse(),
            target.checkpointHash(),target.buildHash(),expiresAt,block.timestamp+MAX_START_CLAIM_LIFETIME,bytes32(0));
        startBirthApproval[account] = expectedGeneration == 1 ? _birthApproval(target) : bytes32(0);
        emit StartClaimed(account,runId,starter,expectedGeneration,expiresAt);
    }

    /// @dev B3: records the cooldown of the previous (no longer current) claim's starter when it ran out with the account
    ///      unchanged, then answers whether `starter` is still cooling down on this account.
    function _coolingDown(INoerraStartAccount target, address starter) private returns (bool) {
        address account = address(target);
        StartClaim storage previous = startClaims[account];
        address last = previous.starter; uint256 until = previous.expiresAt + START_CLAIM_COOLDOWN;
        if (last != address(0) && block.timestamp >= previous.expiresAt && previous.generation == target.generation() &&
            previous.pulse == target.lastPulse() && !_startProgressed(account, previous) &&
            startClaimCooldownUntil[account][last] < until)
            startClaimCooldownUntil[account][last] = until;
        return block.timestamp < startClaimCooldownUntil[account][starter];
    }

    /// @dev A claim made progress once its starter bound an action (a funded start counts too, NoerraStartFunding).
    function _startProgressed(address, StartClaim storage claim) internal view virtual returns (bool) {
        return claim.action != bytes32(0);
    }

    function renewStartClaim(address account, bytes32 runId, uint256 expiresAt) external {
        StartClaim storage claim = startClaims[account];
        if (claim.starter != msg.sender || claim.runId != runId || !_current(INoerraStartAccount(account),claim) ||
            expiresAt <= claim.expiresAt || expiresAt > block.timestamp + START_CLAIM_WINDOW ||
            expiresAt > claim.maximumUntil) revert InvalidStartClaim();
        claim.expiresAt = expiresAt;
        emit StartClaimRenewed(account,runId,expiresAt);
    }

    /// @notice Bind exactly one activation/recovery commitment after provisioning.
    /// The ordinary computer's public signer is inside that account commitment.
    function bindStartAction(address account, bytes32 runId, bytes32 action) external {
        StartClaim storage claim = startClaims[account];
        if (claim.starter != msg.sender || claim.runId != runId || action == bytes32(0) ||
            !_current(INoerraStartAccount(account),claim) || claim.action != bytes32(0) && claim.action != action)
            revert InvalidStartClaim();
        claim.action = action;
        emit StartActionBound(account,runId,action);
    }

    function _eligible(INoerraStartAccount target) private view returns (bool) {
        (bytes32 pending,,,,,,,,,) = target.paidRecovery();
        // A frozen account is recoverable even while hibernating.
        if (pending != bytes32(0) || _asleep(address(target)) && !_frozen(address(target))) return false;
        if (target.generation() == 1) {
            (bytes32 intent,,,,) = target.automaticActivation();
            if (intent != bytes32(0)) return true;
        }
        return target.checkpointHash() != bytes32(0) &&
            (block.timestamp > _liveSince(target) + target.STALE_AFTER() || _frozen(address(target)));
    }

    /// @dev The account's own liveness clock (NoerraAgentAccount._checkStaleRecovery).
    /// A lapsed freeze of the current generation counts as a pulse at frozenAt + 72 h, so no claim can be taken (and re-freeze the
    /// account through frozen()'s start-claim extension) inside the stale grace that follows a lapse. Accounts without the freeze
    /// getters keep the raw lastPulse.
    function _liveSince(INoerraStartAccount target) private view returns (uint256 since) {
        since = target.lastPulse();
        (bool ok, bytes memory answer) = address(target).staticcall(abi.encodeWithSignature("frozenGeneration()"));
        if (!ok || answer.length != 32 || abi.decode(answer, (uint256)) != target.generation()) return since;
        (ok, answer) = address(target).staticcall(abi.encodeWithSignature("frozenAt()"));
        if (ok && answer.length == 32) {
            uint256 lapse = abi.decode(answer, (uint256)) + ACCOUNT_FREEZE_TTL;
            if (lapse > since) since = lapse;
        }
    }

    /// @dev Emergency freeze: a frozen account (its signer reported compromised; a freeze lasts at most
    /// 72 h) is recoverable at once, without the stale wait; whether it is paid is the account's rule. Accounts without
    /// the getter never are.
    function _frozen(address target) private view returns (bool) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSignature("frozen()"));
        return ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1;
    }

    /// @dev A hibernating account below its wake threshold refuses every recovery door, so a
    /// claim would only hold the slot. An account is a hibernation account when its non-reverting
    /// hibernating() getter answers one word; only accounts without it (older deployments) count as awake.
    /// For a hibernation account a reverting or malformed recoveryAsleep() counts as asleep.
    function _asleep(address target) private view returns (bool) {
        (bool known, bytes memory flag) = target.staticcall(abi.encodeWithSignature("hibernating()"));
        if (!known || flag.length != 32) return false;
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSignature("recoveryAsleep()"));
        return !ok || answer.length != 32 || abi.decode(answer, (uint256)) != 0;
    }

    function _current(INoerraStartAccount target, StartClaim memory claim) internal view returns (bool) {
        return claim.starter != address(0) && block.timestamp < claim.expiresAt &&
            target.generation() == claim.generation && target.lastPulse() == claim.pulse &&
            target.checkpointHash() == claim.checkpoint && target.buildHash() == claim.build &&
            (claim.generation != 1 || startBirthApproval[address(target)] == _birthApproval(target));
    }

    function startClaimCurrent(address account) external view returns (bool) {
        return _current(INoerraStartAccount(account), startClaims[account]);
    }

    function _birthApproval(INoerraStartAccount target) private view returns (bytes32) {
        (bytes32 intent, uint256 nonce, uint256 minimum, uint256 expiry, uint256 gasLimit) = target.automaticActivation();
        return keccak256(abi.encode(intent, nonce, minimum, expiry, gasLimit));
    }

    function _allowStartAction(address account, bytes32 commitment) internal view returns (bool) {
        if (!startFenceEnabled[account]) return true;
        StartClaim memory claim = startClaims[account];
        return claim.action != bytes32(0) && claim.action == commitment && _current(INoerraStartAccount(account),claim);
    }
}
