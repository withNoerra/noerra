// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentRecoveryVerifier, NoerraAgentAccount} from "./NoerraAgents.sol";

/// @dev Automata DCAP SDK ABI, revision 3b2aa836f693e10771ba8f5e21da2ba942872bc2.
interface INoerraDcapAttestation {
    function verifyAndAttestOnChain(bytes calldata rawQuote) external payable
        returns (bool success, bytes memory verifiedOutput);
}
interface INoerraRecoverableAccount {
    function recover(address candidate, bytes calldata evidence) external;
}

/// @notice Permissionless registration of a fresh, measured TDX recovery quote.
/// @dev This verifies hardware/software evidence, not confidential model inference.
///      The measured application must derive its own signer before quoting it.
///      Review the upstream verifier and its collateral/upgrade authorities before deployment.
contract NoerraRecoveryVerifier is IAgentRecoveryVerifier, ReentrancyGuard {
    INoerraDcapAttestation public immutable attestation;
    bytes32 public immutable attestationCodeHash;
    bytes32 public immutable measurementsHash;
    uint256 public constant WINDOW = 128;
    struct Registration { bytes32 commitment; uint256 anchor; }
    mapping(bytes32 => Registration) public registrations;
    mapping(bytes32 => bool) public paidRegistrations;
    event Registered(bytes32 indexed quoteHash, bytes32 indexed commitment, uint256 anchor);

    constructor(INoerraDcapAttestation verifier, bytes32 codeHash, bytes32 measurements) {
        require(address(verifier).code.length != 0 && address(verifier).codehash == codeHash, "Verifier code");
        require(measurements != bytes32(0), "Measurements");
        attestation = verifier; attestationCodeHash = codeHash; measurementsHash = measurements;
    }

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

    function registerPaid(bytes calldata quote, bytes32 commitment, uint256 anchor, bytes32 anchorHash)
        external payable nonReentrant returns (bytes32 quoteHash) {
        return _registerPaid(quote, commitment, anchor, anchorHash, msg.value);
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
    function registerAndActivate(address account, uint256 expectedGeneration, address nextSigner,
        bytes32 destination, bytes calldata acceptance, bytes calldata quote, uint256 anchor,
        bytes32 anchorHash, uint256 signerGas) external payable nonReentrant returns (bytes32 quoteHash) {
        require(account.code.length != 0 && msg.value >= signerGas, "Activation account");
        NoerraAgentAccount target = NoerraAgentAccount(account);
        bytes32 commitment = target.automaticActivationCommitment(expectedGeneration, nextSigner, destination);
        quoteHash = _register(quote, commitment, anchor, anchorHash, msg.value - signerGas);
        target.activateApproved{value: signerGas}(expectedGeneration, nextSigner, destination,
            acceptance, abi.encodePacked(quoteHash));
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
        require(commitment != bytes32(0) && quote.length >= 632 && quote.length <= 50000, "Quote bounds");
        require(anchor < block.number && block.number - anchor < WINDOW && blockhash(anchor) == anchorHash, "Fresh anchor");
        require(address(attestation).codehash == attestationCodeHash, "Verifier changed");
        quoteHash = keccak256(quote);
        require(registrations[quoteHash].commitment == bytes32(0), "Quote registered");
        (bool success, bytes memory output) = attestation.verifyAndAttestOnChain{value: fee}(_attestationQuote(quote));
        require(success, "DCAP verification");
        _check(output, commitment, freshness(anchor, anchorHash), measured, quote);
        registrations[quoteHash] = Registration(commitment, anchor);
        paidRegistrations[quoteHash] = paid;
        emit Registered(quoteHash, commitment, anchor);
    }

    function verify(bytes calldata evidence, bytes32 commitment) external view returns (bool) {
        return _verify(evidence, commitment, false);
    }

    function verifyPaid(bytes calldata evidence, bytes32 commitment) external view returns (bool) {
        return operatorMeasurementsHash() != bytes32(0) && _verify(evidence, commitment, true);
    }

    function _verify(bytes calldata evidence, bytes32 commitment, bool paid) private view returns (bool) {
        if (evidence.length != 32 || commitment == bytes32(0) || address(attestation).codehash != attestationCodeHash) return false;
        bytes32 quoteHash; assembly { quoteHash := calldataload(evidence.offset) }
        Registration memory row = registrations[quoteHash];
        return paidRegistrations[quoteHash] == paid && row.commitment == commitment &&
            row.anchor < block.number && block.number - row.anchor < WINDOW;
    }

    function _attestationQuote(bytes calldata quote) internal pure virtual returns (bytes memory) {
        return quote;
    }

    function _word(bytes memory output, uint256 at) internal pure returns (bytes32 value) {
        assembly { value := mload(add(add(output, 32), at)) }
    }

    function _check(bytes memory output, bytes32 commitment, bytes32 fresh, bytes32 approvedMeasurements,
        bytes calldata) internal pure virtual {
        _checkHardwareAndBinding(output, commitment, fresh);
        bytes memory measured = new bytes(240); // MRTD and RTMR0..3, each 48 bytes
        for (uint256 i; i < 48; ++i) measured[i] = output[149 + i];
        for (uint256 i; i < 192; ++i) measured[48 + i] = output[341 + i];
        require(keccak256(measured) == approvedMeasurements, "Measured application");
    }

    function _checkHardwareAndBinding(bytes memory output, bytes32 commitment, bytes32 fresh) internal pure {
        // Official SDK Output serialization: BE version(2), TEE(4), TCB(1),
        // FMSPC(6), TDX body(584), optional ABI-encoded advisory string array.
        require(output.length >= 597 && output.length <= 8192, "Output bounds");
        require(output[0] == 0 && output[1] == 0x04 && output[2] == 0 && output[3] == 0 &&
            output[4] == 0 && output[5] == 0x81 && output[6] == 0, "TDX up to date only");
        require(uint8(output[133]) & 1 == 0, "Debug TDX"); // body TD attributes, little endian
        require(_word(output, 533) == commitment && _word(output, 565) == fresh, "Recovery binding");
        if (output.length > 597) {
            bytes memory tail = new bytes(output.length - 597);
            for (uint256 i; i < tail.length; ++i) tail[i] = output[597 + i];
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
        _checkHardwareAndBinding(output, commitment, fresh);
        (, bytes20 appId, bytes32 composeHash, bytes memory kmsIdentity) = _envelope(evidence);
        bytes memory config = abi.encodePacked(bytes1(0x02),
            keccak256(abi.encodePacked(composeHash, appId, bytes1(0x02), kmsIdentity)), bytes15(0));
        for (uint256 i; i < 48; ++i) require(output[197 + i] == config[i], "Dstack configuration");
        bytes memory os = new bytes(192); // MRTD and RTMR0..2; RTMR3 varies by instance and boot.
        for (uint256 i; i < 48; ++i) os[i] = output[149 + i];
        for (uint256 i; i < 144; ++i) os[48 + i] = output[341 + i];
        require(keccak256(abi.encodePacked(os, composeHash, bytes1(0x02), kmsIdentity)) == approvedPolicy,
            "Measured application");
    }
}
