// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
/// @dev Pinned solc 0.8.26 optimizer-200 constructor hashes; tests compare compiled artifacts.
/// NOERRA creation sources import no account source, so account edits do not move these pins.
/// The hook pin covers NoerraUsdcFeeHook.sol (decaying launch fee; launch access window; locker-only beforeAddLiquidity, flags 0x28cc); the vault
/// and market pins also cover the constructor access list / NoerraLaunchPrice sources through their metadata.
library NoerraAtomicCodeHashes {
    function expected(uint256 i) internal pure returns(bytes32) {
        if(i==0) return 0xb9f2d0d4a85992c5a9adf2067da3ccf18afad4b0fa8c1a8c7747f3168cdf6401;
        if(i==1) return 0x73d7639e7a698f68e9e3cb1550efaecd8c46c95c8489bfa9496ac6d0d4e96c45;
        if(i==2) return 0xfb2d631217b46ef29b7889dc3ca392dde789a582eafc97b8a640d6aa1375ea0a;
        if(i==3) return 0xbdb61c65292f2d6971b1b8bffdcab5fd2b80c491b9826fe36bed00db1c92d82e;
        revert("Creation index");
    }
}
