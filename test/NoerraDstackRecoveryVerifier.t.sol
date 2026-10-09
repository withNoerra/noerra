// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoerraDstackPaidRecoveryVerifier, INoerraDcapAttestation} from "../src/agents/NoerraRecoveryVerifier.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";

// DCAP fixture checks policy serialization; it does not verify Intel signatures.
contract DstackRecoveryDcapFixture is INoerraDcapAttestation {
    bytes public output;
    bytes public lastQuote;
    bool public accepted = true;
    function set(bytes memory value, bool success) external { output = value; accepted = success; }
    function verifyAndAttestOnChain(bytes calldata quote) external payable returns (bool, bytes memory) {
        lastQuote = quote;
        return (accepted, output);
    }
}

contract NoerraDstackRecoveryVerifierTest is Test {
    DstackRecoveryDcapFixture dcap;
    NoerraDstackPaidRecoveryVerifier verifier;
    bytes32 anchorHash = keccak256("dstack recovery anchor");
    bytes32 commitment = keccak256("account signer generation commitment");
    bytes32 originalCompose = keccak256("approved original role composition");
    bytes32 paidCompose = keccak256("approved paid role composition");
    bytes kmsIdentity = hex"3059301306072a8648ce3d020106082a8648ce3d03010703420004abcdef";
    bytes20 appId = bytes20(address(0xAA));
    bytes rawQuote;

    function setUp() public {
        vm.roll(100); vm.setBlockhash(99, anchorHash);
        dcap = new DstackRecoveryDcapFixture();
        bytes memory os = new bytes(192);
        os[0] = 0x11;
        verifier = new NoerraDstackPaidRecoveryVerifier(dcap, address(dcap).codehash,
            keccak256(bytes.concat(os, originalCompose, hex"02", kmsIdentity)),
            keccak256(bytes.concat(os, paidCompose, hex"02", kmsIdentity)));
        rawQuote = new bytes(632);
    }

    function evidence(bytes32 compose, bytes20 app, bytes memory kms) internal view returns (bytes memory) {
        return abi.encode(rawQuote, app, compose, kms);
    }

    function output(bytes32 compose, bytes20 app, bytes memory kms) internal view returns (bytes memory result) {
        result = new bytes(597); result[1] = 0x04; result[5] = 0x81; result[149] = 0x11;
        result[197] = 0x02;
        bytes32 config = keccak256(abi.encodePacked(compose, app, bytes1(0x02), kms));
        bytes32 fresh = verifier.freshness(99, anchorHash);
        bytes32 bound = commitment;
        assembly {
            mstore(add(result, 230), config)
            mstore(add(result, 565), bound)
            mstore(add(result, 597), fresh)
        }
    }

    function registerOriginal(bytes memory proof) internal returns (bytes32) {
        return verifier.register(proof, commitment, 99, anchorHash);
    }

    function testFreshInstancesShareApprovedRoleWithoutPinningVariableRtmr3() public {
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        bytes memory out = output(originalCompose, appId, kmsIdentity);
        out[485] = 0x12; dcap.set(out, true);
        bytes32 first = registerOriginal(proof);
        assertTrue(verifier.verify(abi.encodePacked(first), commitment));
        assertEq(dcap.lastQuote(), rawQuote);
        appId = bytes20(address(0xBB)); rawQuote[0] = 0x01;
        out = output(originalCompose, appId, kmsIdentity); out[485] = 0x34; dcap.set(out, true);
        bytes32 second = registerOriginal(evidence(originalCompose, appId, kmsIdentity));
        assertTrue(verifier.verify(abi.encodePacked(second), commitment));
        assertNotEq(first, second);
    }

    function testRejectsTamperedAppIdentityCompositionAndKmsBinding() public {
        dcap.set(output(originalCompose, appId, kmsIdentity), true);
        vm.expectRevert("Dstack configuration");
        registerOriginal(evidence(originalCompose, bytes20(address(0xBB)), kmsIdentity));
        vm.expectRevert("Dstack configuration");
        registerOriginal(evidence(paidCompose, appId, kmsIdentity));
        vm.expectRevert("Dstack configuration");
        registerOriginal(evidence(originalCompose, appId, hex"01"));
        dcap.set(output(paidCompose, appId, kmsIdentity), true);
        vm.expectRevert("Measured application");
        registerOriginal(evidence(paidCompose, appId, kmsIdentity));
        dcap.set(output(originalCompose, appId, hex"01"), true);
        vm.expectRevert("Measured application");
        registerOriginal(evidence(originalCompose, appId, hex"01"));
    }

    function testRejectsZeroLegacyMrconfigAndNonzeroPadding() public {
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        bytes memory out = output(originalCompose, appId, kmsIdentity);
        out[197] = 0; dcap.set(out, true);
        vm.expectRevert("Dstack configuration"); registerOriginal(proof);
        out[197] = 0x01; dcap.set(out, true);
        vm.expectRevert("Dstack configuration"); registerOriginal(proof);
        out[197] = 0x02; out[230] = 0x01; dcap.set(out, true);
        vm.expectRevert("Dstack configuration"); registerOriginal(proof);
    }

    function testRejectsChangedOsDebugTcbAndReportData() public {
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        bytes memory out = output(originalCompose, appId, kmsIdentity);
        out[341] = 0x01; dcap.set(out, true);
        vm.expectRevert("Measured application"); registerOriginal(proof);
        out = output(originalCompose, appId, kmsIdentity); out[133] = 0x01; dcap.set(out, true);
        vm.expectRevert("Debug TDX"); registerOriginal(proof);
        out[133] = 0; out[6] = 0x01; dcap.set(out, true);
        vm.expectRevert("TDX up to date only"); registerOriginal(proof);
        out = output(originalCompose, appId, kmsIdentity); out[533] ^= bytes1(uint8(1)); dcap.set(out, true);
        vm.expectRevert("Recovery binding"); registerOriginal(proof);
        out = output(originalCompose, appId, kmsIdentity); out[565] ^= bytes1(uint8(1)); dcap.set(out, true);
        vm.expectRevert("Recovery binding"); registerOriginal(proof);
    }

    function testPaidRoleCannotAuthorizeOriginalRecoveryOrViceVersa() public {
        bytes memory original = evidence(originalCompose, appId, kmsIdentity);
        dcap.set(output(originalCompose, appId, kmsIdentity), true);
        vm.expectRevert("Measured application");
        verifier.registerPaid(original, commitment, 99, anchorHash);
        bytes32 first = registerOriginal(original);
        assertFalse(verifier.verifyPaid(abi.encodePacked(first), commitment));
        rawQuote[0] = 0x01;
        bytes memory paid = evidence(paidCompose, appId, kmsIdentity);
        dcap.set(output(paidCompose, appId, kmsIdentity), true);
        vm.expectRevert("Measured application"); registerOriginal(paid);
        bytes32 second = verifier.registerPaid(paid, commitment, 99, anchorHash);
        assertTrue(verifier.verifyPaid(abi.encodePacked(second), commitment));
        assertFalse(verifier.verify(abi.encodePacked(second), commitment));
    }

    function testCanonicalEnvelopeAndBoundsPreventAlternateEncodings() public {
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        dcap.set(output(originalCompose, appId, kmsIdentity), true);
        vm.expectRevert("Dstack envelope"); registerOriginal(bytes.concat(proof, bytes32(0)));
        vm.expectRevert("Dstack envelope"); registerOriginal(evidence(originalCompose, bytes20(0), kmsIdentity));
        vm.expectRevert("Dstack envelope"); registerOriginal(evidence(bytes32(0), appId, kmsIdentity));
        vm.expectRevert("Dstack envelope"); registerOriginal(evidence(originalCompose, appId, ""));
        vm.expectRevert("Dstack envelope"); registerOriginal(evidence(originalCompose, appId, new bytes(513)));
        rawQuote = new bytes(631);
        vm.expectRevert("Dstack quote bounds"); registerOriginal(evidence(originalCompose, appId, kmsIdentity));
    }

    function testDuplicateQuoteFreshnessAndFailedDcapStayFailClosed() public {
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        dcap.set(output(originalCompose, appId, kmsIdentity), false);
        vm.expectRevert("DCAP verification"); registerOriginal(proof);
        dcap.set(output(originalCompose, appId, kmsIdentity), true);
        bytes32 hash = registerOriginal(proof);
        vm.expectRevert("Quote registered"); registerOriginal(proof);
        vm.roll(227);
        assertFalse(verifier.verify(abi.encodePacked(hash), commitment));
    }

    function testIdenticalOriginalAndPaidPoliciesCannotDeploy() public {
        bytes32 policy = keccak256("same role");
        vm.expectRevert("Separate dstack roles");
        new NoerraDstackPaidRecoveryVerifier(dcap, address(dcap).codehash, policy, policy);
    }

    function testAtomicActivationRollsBackUnfundedThenAcceptsExactConfigurationAndSigner() public {
        AgentTestDollar dollar = new AgentTestDollar();
        NoerraAgentRegistry registry = new NoerraAgentRegistry(dollar, verifier);
        address human = address(0xA1);
        address nextSigner = vm.addr(0x123456);
        vm.prank(human);
        (, address deployed) = registry.create(human, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        NoerraAgentAccount account = NoerraAgentAccount(deployed);
        vm.prank(human);
        account.approveAutomaticActivation(1, keccak256("approved configuration"), 15e6, block.timestamp + 2 days, 0.001 ether);
        bytes32 destination = keccak256("attested destination");
        commitment = account.automaticActivationCommitment(1, nextSigner, destination);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", commitment)));
        bytes memory proof = evidence(originalCompose, appId, kmsIdentity);
        dcap.set(output(originalCompose, appId, kmsIdentity), true);
        vm.expectRevert("Activation funding");
        verifier.registerAndActivate(deployed, 1, nextSigner, destination, abi.encodePacked(r,s,v), proof, 99, anchorHash, 0);
        (bytes32 registered,) = verifier.registrations(keccak256(proof)); assertEq(registered, bytes32(0));
        dollar.mint(deployed, 50e6);
        verifier.registerAndActivate{value: 0.001 ether}(deployed, 1, nextSigner, destination, abi.encodePacked(r,s,v), proof, 99, anchorHash, 0.001 ether);
        assertEq(account.signer(), nextSigner); assertEq(account.generation(), 2);
        assertTrue(account.automaticPayer()); assertEq(nextSigner.balance, 0.001 ether);
    }
}
