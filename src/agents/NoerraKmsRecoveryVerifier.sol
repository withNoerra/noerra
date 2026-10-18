// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NoerraEvidenceRegistration} from "./NoerraRecoveryVerifier.sol";
import {NoerraKmsApplicationFactory} from "./NoerraKmsApplicationPolicy.sol";

/// @notice KMS-certified application keys authorize fresh, account-bound wallet actions.
/// @dev Phala KMS verifies hardware before key release; Ethereum verifies certificates and action signatures.
///      This trusts the pinned KMS root and protected application-policy approver, rather than L1 DCAP execution.
contract NoerraKmsRecoveryVerifier is NoerraEvidenceRegistration {
    uint256 public constant KMS_CERTIFICATE_VERSION = 1;
    bytes32 public constant POLICY_DOMAIN = keccak256("NOERRA_KMS_POLICY_V1");
    bytes32 public constant ACTION_DOMAIN = keccak256("NOERRA_KMS_RECOVERY_ACTION_V1");
    string public constant KEY_PURPOSE = "noerra-recovery-proof-v1";
    address public immutable kmsRoot;
    NoerraKmsApplicationFactory public immutable applicationFactory;
    bytes32 public immutable factoryCodeHash;
    struct Certificate {
        address app; bytes keyPublic; bytes appPublic;
        bytes keySignature; bytes kmsSignature; bytes actionSignature;
    }
    constructor(address root, NoerraKmsApplicationFactory factory, bytes32 codeHash)
        NoerraEvidenceRegistration(keccak256(abi.encode(POLICY_DOMAIN, root, address(factory), uint8(1)))) {
        require(root != address(0) && address(factory).code.length != 0 && address(factory).codehash == codeHash, "KMS authority");
        kmsRoot = root; applicationFactory = factory; factoryCodeHash = codeHash;
    }
    function operatorMeasurementsHash() public view override returns (bytes32) {
        return keccak256(abi.encode(POLICY_DOMAIN, kmsRoot, address(applicationFactory), uint8(2)));
    }
    function _authorityValid() internal view override returns (bool) {
        return address(applicationFactory).codehash == factoryCodeHash;
    }
    function _evidenceBounds(bytes calldata evidence) internal pure override returns (bool) {
        return evidence.length >= 600 && evidence.length <= 1200;
    }
    function _authenticate(bytes calldata evidence, bytes32 commitment, bytes32 fresh, bytes32 policy, uint256 fee)
        internal view override {
        require(fee == 0, "No certificate fee");
        Certificate memory c = abi.decode(evidence, (Certificate));
        require(keccak256(evidence) == keccak256(abi.encode(c)), "Certificate encoding");
        (bytes32 compose, bytes32 osImage, bytes32 configuration, uint8 role) = applicationFactory.applications(c.app);
        require(compose != bytes32(0) && osImage != bytes32(0) && configuration != bytes32(0) && c.app.code.length != 0 &&
            keccak256(abi.encode(POLICY_DOMAIN, kmsRoot, address(applicationFactory), role)) == policy, "Application authority");
        (address keyAddress, bytes memory keyCompressed) = _publicKey(c.keyPublic);
        (address appAddress, bytes memory appCompressed) = _publicKey(c.appPublic);
        require(ECDSA.recover(keccak256(abi.encodePacked(KEY_PURPOSE, ":", _hex(keyCompressed))), c.keySignature) == appAddress,
            "Derived key certificate");
        require(ECDSA.recover(keccak256(abi.encodePacked("dstack-kms-issued:", bytes20(c.app), appCompressed)), c.kmsSignature) == kmsRoot,
            "KMS certificate");
        require(ECDSA.recover(keccak256(abi.encode(ACTION_DOMAIN, commitment, fresh, c.app, keccak256(keyCompressed))), c.actionSignature) == keyAddress,
            "Recovery action signature");
    }
    function _publicKey(bytes memory key) private pure returns (address account, bytes memory compressed) {
        require(key.length == 65 && key[0] == 0x04, "Public key encoding");
        uint256 x; uint256 y;
        assembly { x := mload(add(key, 33)) y := mload(add(key, 65)) }
        uint256 prime = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
        require(x < prime && y < prime && mulmod(y,y,prime) == addmod(mulmod(mulmod(x,x,prime),x,prime),7,prime), "Public key curve");
        bytes32 digest;
        assembly { digest := keccak256(add(key, 33), 64) }
        account = address(uint160(uint256(digest)));
        compressed = new bytes(33); compressed[0] = bytes1(uint8(2 + (y & 1)));
        for (uint256 i; i < 32; ++i) compressed[i+1] = key[i+1];
    }
    function _hex(bytes memory value) private pure returns (bytes memory encoded) {
        bytes memory alphabet = "0123456789abcdef"; encoded = new bytes(value.length * 2);
        for (uint256 i; i < value.length; ++i) {
            encoded[2*i] = alphabet[uint8(value[i]) >> 4]; encoded[2*i+1] = alphabet[uint8(value[i]) & 15];
        }
    }
}
