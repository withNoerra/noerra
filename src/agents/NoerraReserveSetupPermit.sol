// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice One launch authorization for exact zero-value setup calls on Ethereum and Base.
/// @dev Each leaf binds chain, recipient and original calldata. This is not a spending
/// allowance. Consumers must enforce one-shot setup and invalidate it after recovery.
library NoerraReserveSetupPermit {
    struct Permit {
        address sourceRegistry;
        bytes32 root;
        uint256 deadline;
        bytes signature;
        bytes32[] proof;
    }

    bytes32 internal constant TYPEHASH =
        keccak256("ReserveSetup(bytes32 agentId,bytes32 callsRoot,uint256 deadline)");

    function digest(address registry, bytes32 id, bytes32 root, uint256 deadline)
        internal pure returns (bytes32)
    {
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Noerra Reserve Setup"), keccak256("1"), uint256(1), registry
        ));
        return keccak256(abi.encodePacked("\x19\x01", domain,
            keccak256(abi.encode(TYPEHASH, id, root, deadline))));
    }

    function leaf(bytes memory callData) internal view returns (bytes32) {
        // Double hashing prevents a 64-byte leaf from being confused with a tree node.
        return keccak256(bytes.concat(keccak256(abi.encode(
            block.chainid, address(this), uint256(0), keccak256(callData)
        ))));
    }

    function verify(address owner, address registry, bytes32 id, bytes memory callData, Permit calldata permit)
        internal view
    {
        require((block.chainid == 1 || block.chainid == 8453) && registry != address(0)
            && permit.sourceRegistry == registry && id != bytes32(0)
            && permit.root != bytes32(0) && permit.deadline >= block.timestamp
            && permit.proof.length <= 8, "Exact unexpired reserve setup");
        require(MerkleProof.verifyCalldata(permit.proof, permit.root, leaf(callData)),
            "Approved reserve setup call");
        require(SignatureChecker.isValidSignatureNow(owner,
            digest(registry, id, permit.root, permit.deadline), permit.signature),
            "Creator reserve setup signature");
    }
}
