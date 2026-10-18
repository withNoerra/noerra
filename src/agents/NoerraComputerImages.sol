// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Governed computer releases under an unchanged account/KMS lineage.
/// @dev Image admission never changes account authority, allowances or keys.
contract NoerraComputerImages {
    error ImagePolicy();
    address public immutable governor;
    struct Release { bytes32 image; uint256 readyAt; bool revoked; }
    mapping(bytes32 => mapping(uint256 => Release)) public releases;
    mapping(bytes32 => uint256) public latestVersion;
    mapping(bytes32 => mapping(bytes32 => bool)) public imageUsed;
    event ImageScheduled(bytes32 indexed lineage, uint256 indexed version, bytes32 image, uint256 readyAt);
    event ImageRevoked(bytes32 indexed lineage, uint256 indexed version);
    constructor(address governor_) {
        if (governor_ == address(0)) revert ImagePolicy();
        governor = governor_;
    }
    function schedule(bytes32 lineage, bytes32 image) external returns (uint256 version) {
        if (msg.sender != governor || lineage == bytes32(0) || image == bytes32(0) || imageUsed[lineage][image]) revert ImagePolicy();
        imageUsed[lineage][image] = true;
        version = ++latestVersion[lineage];
        releases[lineage][version] = Release(image, block.timestamp, false);
        emit ImageScheduled(lineage, version, image, block.timestamp);
    }
    function revoke(bytes32 lineage, uint256 version) external {
        Release storage release = releases[lineage][version];
        if (msg.sender != governor || release.readyAt == 0 || release.revoked) revert ImagePolicy();
        release.revoked = true;
        emit ImageRevoked(lineage, version);
    }
    function admitted(bytes32 lineage, uint256 version, bytes32 image) external view returns (bool) {
        Release memory release = releases[lineage][version];
        return image != bytes32(0) && release.image == image && release.readyAt != 0 &&
            !release.revoked;
    }
}
