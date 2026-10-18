// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface INoerraKmsAppAuth {
    struct AppBootInfo {
        address appId; bytes32 composeHash; address instanceId; bytes32 deviceId;
        bytes32 mrAggregated; bytes32 mrSystem; bytes32 osImageHash;
        string tcbStatus; string[] advisoryIds;
    }
    function isAppAllowed(AppBootInfo calldata boot) external view returns (bool, string memory);
}

/// @notice One application identity, one approved manifest and OS. No management or upgrade path.
contract NoerraKmsApplicationPolicy is INoerraKmsAppAuth {
    address public immutable factory = msg.sender;
    bytes32 public composeHash;
    bytes32 public osImageHash;
    bytes32 public configurationHash;
    function initialize(bytes32 compose, bytes32 osImage, bytes32 configuration) external {
        require(msg.sender == factory && composeHash == bytes32(0), "Immutable application");
        require(compose != bytes32(0) && osImage != bytes32(0) && configuration != bytes32(0), "Application policy");
        composeHash = compose; osImageHash = osImage; configurationHash = configuration;
    }
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x1e079198;
    }
    function isAppAllowed(AppBootInfo calldata boot) external view returns (bool, string memory) {
        if (boot.appId != address(this) || boot.instanceId == address(0)) return (false, "Application identity");
        if (boot.composeHash != composeHash || boot.osImageHash != osImageHash) return (false, "Application code");
        if (keccak256(bytes(boot.tcbStatus)) != keccak256("UpToDate") || boot.advisoryIds.length != 0)
            return (false, "Hardware status");
        return (true, "");
    }
}

/// @notice The protected launcher approves exact policies; anyone can pay to create them.
/// @dev Deployment must authenticate the immutable approver's actual protected runtime identity.
contract NoerraKmsApplicationFactory {
    address public immutable approver;
    bytes32 public constant APPROVAL_DOMAIN = keccak256("NOERRA_KMS_APPLICATION_V1");
    struct Application { bytes32 composeHash; bytes32 osImageHash; bytes32 configurationHash; uint8 role; }
    mapping(address => Application) public applications; // role 1: starter, 2: paid recovery.
    event ApplicationCreated(address indexed app, bytes32 indexed salt, uint8 role, bytes32 composeHash, bytes32 osImageHash, bytes32 configurationHash);
    constructor(address protectedApprover) {
        require(protectedApprover != address(0), "Policy approver"); approver = protectedApprover;
    }
    function approvalCommitment(bytes32 compose, bytes32 osImage, bytes32 configuration, uint8 role, bytes32 salt)
        public view returns (bytes32) {
        return keccak256(abi.encode(APPROVAL_DOMAIN, block.chainid, address(this), compose, osImage, configuration, role, salt));
    }
    function applicationSalt(uint8 role, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(role, salt));
    }
    function predictApplication(uint8 role, bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), applicationSalt(role, salt),
            keccak256(type(NoerraKmsApplicationPolicy).creationCode))))));
    }
    function createApplication(bytes32 compose, bytes32 osImage, bytes32 configuration, uint8 role, bytes32 salt, bytes calldata approval)
        external returns (address app) {
        require(compose != bytes32(0) && osImage != bytes32(0) && configuration != bytes32(0) && (role == 1 || role == 2), "Application policy");
        require(ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(approvalCommitment(compose, osImage, configuration, role, salt)), approval) == approver,
            "Policy approval");
        app = predictApplication(role, salt);
        Application memory existing = applications[app];
        if (existing.role != 0) {
            require(existing.composeHash == compose && existing.osImageHash == osImage && existing.configurationHash == configuration && existing.role == role,
                "Application already bound");
            return app;
        }
        require(app.code.length == 0, "Application occupied");
        NoerraKmsApplicationPolicy deployed = new NoerraKmsApplicationPolicy{salt: applicationSalt(role, salt)}();
        require(address(deployed) == app, "Application prediction");
        deployed.initialize(compose, osImage, configuration);
        applications[app] = Application(compose, osImage, configuration, role);
        emit ApplicationCreated(app, salt, role, compose, osImage, configuration);
    }
}
