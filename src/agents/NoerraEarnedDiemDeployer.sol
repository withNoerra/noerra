// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {NoerraReserveSetupPermit} from "./NoerraReserveSetupPermit.sol";

/// @notice One-shot CREATE2 envelope; children use predictable CREATE nonces to avoid circular
/// cross-chain constructor addresses. Commits exact reviewed initcodes before atomic deployment.
/// @dev Holds no funds and grants no authority over deployed contracts. Anyone may relay only the
/// committed byte-for-byte bundle. An absent or invalid child rolls the whole bundle back.
contract NoerraEarnedDiemDeployer {
    address public immutable owner;
    bytes32 public immutable agentId;
    uint256 public immutable childCount;
    bytes32 public commitment;
    bool public deployed;
    event BundleCommitted(bytes32 indexed commitment);
    event ChildDeployed(uint256 indexed index, address indexed child, bytes32 initCodeHash);

    constructor(address owner_, bytes32 id_, uint256 count_) {
        require(owner_ != address(0) && id_ != bytes32(0) && (block.chainid == 1 || block.chainid == 8453), "Reviewed deployment identity");
        require(count_ > 0 && count_ <= 4, "Finite reviewed bundle");
        childCount = count_;
        owner = owner_;
        agentId = id_;
    }

    function commit(bytes32 commitment_) external {
        require(msg.sender == owner, "Owner one-shot commitment");
        _commit(commitment_);
    }

    function commitWithPermit(bytes32 commitment_, NoerraReserveSetupPermit.Permit calldata permit) external {
        NoerraReserveSetupPermit.verify(owner, permit.sourceRegistry, agentId,
            abi.encodeCall(this.commit, (commitment_)), permit);
        _commit(commitment_);
    }

    function _commit(bytes32 commitment_) private {
        require(commitment == bytes32(0) && commitment_ != bytes32(0), "Owner one-shot commitment");
        commitment = commitment_;
        emit BundleCommitted(commitment_);
    }

    function deploy(bytes[] calldata initCodes) external returns (address[] memory children) {
        require(!deployed && commitment != bytes32(0) && keccak256(abi.encode(initCodes)) == commitment, "Exact reviewed bundle");
        require(initCodes.length == childCount, "Exact chain bundle");
        deployed = true;
        children = new address[](initCodes.length);
        for (uint256 i; i < initCodes.length; ++i) {
            bytes memory code = initCodes[i];
            address child;
            assembly ("memory-safe") { child := create(0, add(code, 32), mload(code)) }
            require(child != address(0) && child.code.length > 0, "Atomic child deployment");
            children[i] = child;
            emit ChildDeployed(i, child, keccak256(code));
        }
    }
}