// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/// @dev Pinned solc 0.8.26 optimizer-200 constructor hashes; tests compare compiled artifacts.
library NoerraAtomicCodeHashes {
    function expected(uint256 i) internal pure returns(bytes32) {
        if(i==0) return 0x3fffc6d95e44d1195c4ad64083f2774d1cdff82d5063b0781a4676a6c5910855;
        if(i==1) return 0x23ea5c5bd519545b706a55e8e5708d59c6f6238c8bd465ced96aab760052fbe0;
        if(i==2) return 0x764520186484b1fed12e247acc419c91c457196451ee959cc83f9e74ee6a17d2;
        if(i==3) return 0xea0c5ff3cbef90772720d231dc2682997a537514bd8977f6b8810ee84ad202ff;
        revert("Creation index");
    }
}
