// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {NoerraStartFunding} from "./NoerraStartFunding.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentRecoveryVerifier, NoerraAgentAccount} from "./NoerraAgents.sol";

/// @dev Automata DCAP byte-quote ABI; V4 TD10 output formats v1.0 and v1.1+.
interface INoerraDcapAttestation {
    function verifyAndAttestOnChain(bytes calldata rawQuote) external payable
        returns (bool success, bytes memory verifiedOutput);
}
interface INoerraRecoverableAccount {
    function recover(address candidate, bytes calldata evidence) external;
}

/// @notice Permissionless registration of a fresh, measured TDX recovery quote.
/// @dev This verifies hardware/software evidence, not confidential model inference.
///      The measured application must authenticate the candidate key and scoped action before quoting it.
///      Review the upstream verifier and its collateral/upgrade authorities before deployment.
abstract contract NoerraEvidenceRegistration is IAgentRecoveryVerifier, ReentrancyGuard, NoerraStartFunding {
    bytes32 public immutable measurementsHash;
    uint256 public constant WINDOW = 128;
    struct Registration { bytes32 commitment; uint256 anchor; }
    mapping(bytes32 => Registration) public registrations;
    mapping(bytes32 => bool) public paidRegistrations;
    mapping(bytes32 => address) public registrationStarter;
    event Registered(bytes32 indexed quoteHash, bytes32 indexed commitment, uint256 anchor);

    constructor(bytes32 measurements) {
        require(measurements != bytes32(0), "Measurements");
        measurementsHash = measurements;
    }

    function _authorityValid() internal view virtual returns (bool);
    function _authenticate(bytes calldata evidence, bytes32 commitment, bytes32 fresh,
        bytes32 policy, uint256 fee) internal virtual;
    function _evidenceBounds(bytes calldata evidence) internal pure virtual returns (bool);

    function freshness(uint256 anchor, bytes32 anchorHash) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), anchor, anchorHash));
    }

    /// @notice Legacy deployments cannot opt into paid operators after deployment.
    function operatorMeasurementsHash() public view virtual returns (bytes32) { return bytes32(0); }

    /// @notice The caller pays the DCAP fee. Reusing a quote never extends its lifetime.
    function register(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        return _register(quote, commitment, anchor, anchorHash, msg.value);
    }

    /// @notice Register a fresh starter claim and acquire its fence atomically.
    function registerAndClaimStart(address account, bytes32 runId, uint256 expectedGeneration,
        uint256 expiresAt, bytes calldata quote, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        bytes32 commitment = startClaimCommitment(account,msg.sender,runId,expectedGeneration,expiresAt);
        quoteHash = _register(quote,commitment,anchor,anchorHash,msg.value);
        _claimStart(account,msg.sender,runId,expectedGeneration,expiresAt,abi.encodePacked(quoteHash));
    }
    function registerPaid(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        return _registerPaid(quote, commitment, anchor, anchorHash, msg.value);
    }

    function registerAndClaimPaidStart(address account, bytes32 runId, uint256 expectedGeneration,
        uint256 expiresAt, bytes calldata quote, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        bytes32 commitment = startClaimCommitment(account,msg.sender,runId,expectedGeneration,expiresAt);
        quoteHash = _registerPaid(quote,commitment,anchor,anchorHash,msg.value);
        _claimStart(account,msg.sender,runId,expectedGeneration,expiresAt,abi.encodePacked(quoteHash));
    }

    function registerAndFundStart(address account, bytes32 runId, address cash, address operator,
        uint256 reimbursement, uint256 bounty, bytes calldata quote, uint256 anchor, bytes32 anchorHash,
        bool paid, uint256 cashGas) external payable nonReentrant returns (bytes32 quoteHash) {
        _checkStarterCashGas(account, cashGas);
        bytes32 commitment = startFundingCommitment(account,runId,cash,operator,reimbursement,bounty);
        quoteHash = paid ? _registerPaid(quote,commitment,anchor,anchorHash,msg.value-cashGas) :
            _register(quote,commitment,anchor,anchorHash,msg.value-cashGas);
        _fundStart(account,runId,cash,operator,reimbursement,bounty,abi.encodePacked(quoteHash));
        if (cashGas != 0) {
            (bool sent,) = payable(cash).call{value:cashGas}(""); require(sent,"Gas delivery");
        }
    }

    function _checkStarterCashGas(address account, uint256 cashGas) private view {
        require(msg.value >= cashGas && (cashGas == 0 ||
            startFunding[account][startClaims[account].generation].cash == address(0)), "Starter cash gas");
    }

    function registerAndCompleteStart(address account, uint256 generation, bytes32 runId, bytes32 lease,
        bytes32 destination, bytes calldata quote, uint256 anchor, bytes32 anchorHash, bool paid)
        external payable nonReentrant returns (bytes32 quoteHash) {
        bytes32 commitment = startCompletionCommitment(account,generation,runId,lease,destination);
        quoteHash = paid ? _registerPaid(quote,commitment,anchor,anchorHash,msg.value) :
            _register(quote,commitment,anchor,anchorHash,msg.value);
        _completeStart(account,generation,runId,lease,destination,abi.encodePacked(quoteHash));
    }

    function registerAndRecoverDirectPaid(address account, address candidate, bytes calldata quote,
        bytes32 commitment, uint256 anchor, bytes32 anchorHash, uint256 signerGas)
        external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0 && candidate != address(0) && candidate.code.length == 0 &&
            msg.value >= signerGas && startFenceEnabled[account], "Direct recovery");
        quoteHash = _registerPaid(quote,commitment,anchor,anchorHash,msg.value-signerGas);
        INoerraRecoverableAccount(account).recover(candidate,abi.encodePacked(quoteHash));
        if (signerGas != 0) {
            (bool sent,) = payable(candidate).call{value:signerGas}(""); require(sent,"Gas delivery");
        }
    }

    /// @notice Register and rotate atomically, without waiting through the short
    ///         quote lifetime between two separately finalized transactions.
    ///         The account independently checks its exact generation commitment.
    function registerAndRecover(address account, address candidate, bytes calldata quote,
        bytes32 commitment, uint256 anchor, bytes32 anchorHash, uint256 signerGas)
        external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0 && candidate != address(0) && candidate.code.length == 0, "Recovery account");
        require(msg.value >= signerGas, "Signer gas");
        quoteHash = _register(quote, commitment, anchor, anchorHash, msg.value - signerGas);
        INoerraRecoverableAccount(account).recover(candidate, abi.encodePacked(quoteHash));
        if (signerGas != 0) {
            (bool sent,) = payable(candidate).call{value: signerGas}(""); require(sent, "Gas delivery");
        }
    }

    /// @notice Register a fresh starter quote and consume the human's deferred approval atomically.
    /// Registration, authority rotation and capped native gas delivery all roll back on failure.
    /// `birthCheckpoint` (the sealed birth archive's hash) is bound in the commitment and becomes the account's
    /// checkpointHash, so an agent lost before its first pulseCheckpoint stays recoverable.
    function registerAndActivate(address account, uint256 expectedGeneration, address nextSigner,
        bytes32 destination, bytes32 birthCheckpoint, bytes memory acceptance, bytes calldata quote, uint256 anchor,
        bytes32 anchorHash, uint256 signerGas) external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0 && msg.value >= signerGas, "Activation account");
        quoteHash = _register(quote, NoerraAgentAccount(account).automaticActivationCommitment(expectedGeneration, nextSigner,
            destination, birthCheckpoint), anchor, anchorHash, msg.value - signerGas);
        NoerraAgentAccount(account).activateApproved{value: signerGas}(expectedGeneration, nextSigner, destination,
            birthCheckpoint, acceptance, abi.encodePacked(quoteHash));
    }

    /// @notice An admitted operator may consume the same owner-approved birth intent.
    function registerAndActivatePaid(address account, uint256 expectedGeneration, address nextSigner,
        bytes32 destination, bytes32 birthCheckpoint, bytes memory acceptance, bytes calldata quote, uint256 anchor,
        bytes32 anchorHash, uint256 signerGas) external payable nonReentrant returns (bytes32 quoteHash) {
        require(startFenceEnabled[account] && account.code.length != 0 && msg.value >= signerGas, "Activation account");
        quoteHash = _registerPaid(quote, NoerraAgentAccount(account).automaticActivationCommitment(expectedGeneration, nextSigner,
            destination, birthCheckpoint), anchor, anchorHash, msg.value - signerGas);
        NoerraAgentAccount(account).activateApproved{value: signerGas}(expectedGeneration, nextSigner, destination,
            birthCheckpoint, acceptance, abi.encodePacked(quoteHash));
    }

    /// @notice Register the starter quote and reserve its reward atomically. No dollar
    ///         payment occurs until a separate attested replacement-computer completion.
    function registerAndRecoverForOperator(address account, NoerraAgentAccount.PaidRecoveryRequest calldata request,
        bytes calldata quote, uint256 anchor, bytes32 anchorHash, uint256 signerGas)
        external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0 && request.nextSigner != address(0) &&
            request.nextSigner.code.length == 0, "Recovery account");
        require(msg.value >= signerGas, "Signer gas");
        NoerraAgentAccount target = NoerraAgentAccount(account);
        quoteHash = _registerPaid(quote, target.paidRecoveryCommitment(request), anchor, anchorHash, msg.value - signerGas);
        target.recoverForOperator(request, abi.encodePacked(quoteHash));
        if (signerGas != 0) {
            (bool sent,) = payable(request.nextSigner).call{value: signerGas}(""); require(sent, "Gas delivery");
        }
    }

    /// @notice Register the receiver-completion quote and pay only its already reserved
    ///         operator. A failed handover, expired job or failed transfer rolls back both.
    function registerAndCompletePaidRecovery(address account, bytes32 jobId, bytes32 actualLease,
        bytes calldata quote, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0, "Recovery account");
        NoerraAgentAccount target = NoerraAgentAccount(account);
        quoteHash = _registerPaid(quote, target.paidRecoveryCompletionCommitment(jobId, actualLease), anchor, anchorHash, msg.value);
        target.completePaidRecovery(jobId, actualLease, abi.encodePacked(quoteHash));
    }

    function _register(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash, uint256 fee)
        private returns (bytes32 quoteHash) {
        return _registerMeasured(quote, commitment, anchor, anchorHash, fee, measurementsHash, false);
    }

    function _registerPaid(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash, uint256 fee)
        private returns (bytes32 quoteHash) {
        bytes32 measured = operatorMeasurementsHash();
        require(measured != bytes32(0), "Paid recovery disabled");
        return _registerMeasured(quote, commitment, anchor, anchorHash, fee, measured, true);
    }

    function _registerMeasured(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash,
        uint256 fee, bytes32 measured, bool paid) private returns (bytes32 quoteHash) {
        require(commitment != bytes32(0) && _evidenceBounds(quote), "Quote bounds");
        require(anchor < block.number && block.number - anchor < WINDOW && blockhash(anchor) == anchorHash, "Fresh anchor");
        require(_authorityValid(), "Verifier changed");
        quoteHash = keccak256(quote);
        require(registrations[quoteHash].commitment == bytes32(0), "Quote registered");
        _authenticate(quote, commitment, freshness(anchor, anchorHash), measured, fee);
        registrations[quoteHash] = Registration(commitment, anchor);
        paidRegistrations[quoteHash] = paid;
        registrationStarter[quoteHash] = msg.sender;
        emit Registered(quoteHash, commitment, anchor);
    }

    function verify(bytes calldata evidence, bytes32 commitment) external view returns (bool) {
        if (startFenceEnabled[msg.sender]) {
            if (evidence.length != 32) return false;
            bytes32 quoteHash;
            assembly { quoteHash := calldataload(evidence.offset) }
            if (registrationStarter[quoteHash] != startClaims[msg.sender].starter) return false;
        }
        return _allowStartAction(msg.sender, commitment) && (_verify(evidence, commitment, false) ||
            startFenceEnabled[msg.sender] && _verify(evidence, commitment, true));
    }

    function verifyPaid(bytes calldata evidence, bytes32 commitment) external view returns (bool) {
        return !startFenceEnabled[msg.sender] && operatorMeasurementsHash() != bytes32(0) && _verify(evidence, commitment, true);
    }

    function _verifyStartClaimEvidence(bytes memory evidence, bytes32 commitment) internal view override returns (bool) {
        return _verify(evidence, commitment, false) || _verify(evidence, commitment, true);
    }

    function _verifyStartFundingEvidence(bytes memory evidence, bytes32 commitment) internal view override returns (bool) {
        return _verify(evidence, commitment, false) || _verify(evidence, commitment, true);
    }

    function _verify(bytes memory evidence, bytes32 commitment, bool paid) private view returns (bool) {
        if (evidence.length != 32 || commitment == bytes32(0) || !_authorityValid()) return false;
        bytes32 quoteHash; assembly { quoteHash := mload(add(evidence, 32)) }
        Registration memory row = registrations[quoteHash];
        return paidRegistrations[quoteHash] == paid && row.commitment == commitment &&
            row.anchor < block.number && block.number - row.anchor < WINDOW;
    }

}

/// @notice Direct verification of measured TDX evidence through the pinned DCAP verifier.
contract NoerraRecoveryVerifier is NoerraEvidenceRegistration {
    INoerraDcapAttestation public immutable attestation;
    bytes32 public immutable attestationCodeHash;

    constructor(INoerraDcapAttestation verifier, bytes32 codeHash, bytes32 measurements)
        NoerraEvidenceRegistration(measurements) {
        require(address(verifier).code.length != 0 && address(verifier).codehash == codeHash, "Verifier code");
        attestation = verifier; attestationCodeHash = codeHash;
    }

    function _authorityValid() internal view override returns (bool) {
        return address(attestation).codehash == attestationCodeHash;
    }
    function _evidenceBounds(bytes calldata quote) internal pure override returns (bool) {
        return quote.length >= 632 && quote.length <= 50000;
    }
    function _authenticate(bytes calldata quote, bytes32 commitment, bytes32 fresh,
        bytes32 policy, uint256 fee) internal override {
        (bool success, bytes memory output) = attestation.verifyAndAttestOnChain{value: fee}(_attestationQuote(quote));
        require(success, "DCAP verification");
        _check(output, commitment, fresh, policy, quote);
    }

    function _attestationQuote(bytes calldata quote) internal pure virtual returns (bytes memory) {
        return quote;
    }

    function _word(bytes memory output, uint256 at) internal pure returns (bytes32 value) {
        assembly { value := mload(add(add(output, 32), at)) }
    }

    function _check(bytes memory output, bytes32 commitment, bytes32 fresh, bytes32 approvedMeasurements,
        bytes calldata) internal pure virtual {
        uint256 body = _checkHardwareAndBinding(output, commitment, fresh);
        bytes memory measured = new bytes(240); // MRTD and RTMR0..3, each 48 bytes
        for (uint256 i; i < 48; ++i) measured[i] = output[body + 136 + i];
        for (uint256 i; i < 192; ++i) measured[48 + i] = output[body + 328 + i];
        require(keccak256(measured) == approvedMeasurements, "Measured application");
    }

    function _checkHardwareAndBinding(bytes memory output, bytes32 commitment, bytes32 fresh)
        internal pure returns (uint256 body) {
        require(output.length >= 595 && output.length <= 8192, "Output bounds");
        require(output[0] == 0 && output[1] == 0x04, "TDX up to date only");
        // v1.0: BE version(2), TEE(4), TCB(1), FMSPC(6).
        // v1.1+: BE version(2), body type(2), TCB(1), FMSPC(6).
        // Accept only V4 TD10, never SGX, TD15 or an unknown layout.
        if (output[2] == 0 && output[3] == 0x02) {
            body = 11;
            require(output[4] == 0, "TDX up to date only");
        } else {
            body = 13;
            require(output[2] == 0 && output[3] == 0 && output[4] == 0 &&
                output[5] == 0x81 && output[6] == 0, "TDX up to date only");
            require(output.length >= 597, "Output bounds");
        }
        require(uint8(output[body + 120]) & 1 == 0, "Debug TDX");
        require(_word(output, body + 520) == commitment && _word(output, body + 552) == fresh,
            "Recovery binding");
        uint256 end = body + 584;
        if (output.length > end) {
            bytes memory tail = new bytes(output.length - end);
            for (uint256 i; i < tail.length; ++i) tail[i] = output[end + i];
            require(abi.decode(tail, (string[])).length == 0, "TCB advisories");
        }
    }
}

/// @notice Separate immutable software authority for paid recovery. Operator quotes
///         cannot authorize the legacy unpaid path, and legacy quotes cannot earn rewards.
contract NoerraPaidRecoveryVerifier is NoerraRecoveryVerifier {
    bytes32 private immutable operatorHash;
    constructor(INoerraDcapAttestation verifier, bytes32 codeHash, bytes32 originalMeasurements,
        bytes32 operatorMeasurements) NoerraRecoveryVerifier(verifier, codeHash, originalMeasurements) {
        require(operatorMeasurements != bytes32(0), "Operator measurements");
        operatorHash = operatorMeasurements;
    }
    function operatorMeasurementsHash() public view override returns (bytes32) { return operatorHash; }
}

/// @notice Recovery authority for dstack V2 configuration-bound KMS applications.
/// @dev Immutable policy hashes bind MRTD+RTMR0..2, the exact role composition and
///      the KMS root identity. Quoted MRCONFIGID authenticates each fresh app ID.
///      Runtime verification must additionally replay RTMR3 for instance identity.
///      Format: dstack v0.5.9, commit 282eeb27d22d8f091ad0fa5a90e638f85cf68751.
contract NoerraDstackPaidRecoveryVerifier is NoerraPaidRecoveryVerifier {
    uint256 public constant DSTACK_POLICY_VERSION = 1;

    constructor(INoerraDcapAttestation verifier, bytes32 codeHash, bytes32 originalPolicy,
        bytes32 operatorPolicy) NoerraPaidRecoveryVerifier(verifier, codeHash, originalPolicy, operatorPolicy) {
        require(originalPolicy != operatorPolicy, "Separate dstack roles");
    }

    function _envelope(bytes calldata evidence) private pure returns
        (bytes memory quote, bytes20 appId, bytes32 composeHash, bytes memory kmsIdentity) {
        (quote, appId, composeHash, kmsIdentity) = abi.decode(evidence, (bytes, bytes20, bytes32, bytes));
        require(quote.length >= 632 && quote.length <= 50000, "Dstack quote bounds");
        require(appId != bytes20(0) && composeHash != bytes32(0) && kmsIdentity.length > 0 &&
            kmsIdentity.length <= 512 && keccak256(evidence) == keccak256(abi.encode(quote, appId, composeHash, kmsIdentity)),
            "Dstack envelope");
    }

    function _attestationQuote(bytes calldata evidence) internal pure override returns (bytes memory quote) {
        (quote,,,) = _envelope(evidence);
    }

    function _check(bytes memory output, bytes32 commitment, bytes32 fresh, bytes32 approvedPolicy,
        bytes calldata evidence) internal pure override {
        uint256 body = _checkHardwareAndBinding(output, commitment, fresh);
        (, bytes20 appId, bytes32 composeHash, bytes memory kmsIdentity) = _envelope(evidence);
        bytes memory config = abi.encodePacked(bytes1(0x02),
            keccak256(abi.encodePacked(composeHash, appId, bytes1(0x02), kmsIdentity)), bytes15(0));
        for (uint256 i; i < 48; ++i) require(output[body + 184 + i] == config[i], "Dstack configuration");
        bytes memory os = new bytes(192); // MRTD and RTMR0..2; RTMR3 varies by instance and boot.
        for (uint256 i; i < 48; ++i) os[i] = output[body + 136 + i];
        for (uint256 i; i < 144; ++i) os[48 + i] = output[body + 328 + i];
        require(keccak256(abi.encodePacked(os, composeHash, bytes1(0x02), kmsIdentity)) == approvedPolicy,
            "Measured application");
    }
}
