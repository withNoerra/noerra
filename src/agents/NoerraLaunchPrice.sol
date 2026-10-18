// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Launch spot price as a Q64.96 square root, overflow-free at every oracle price.
/// @dev sqrt(mulDiv(n, 2^192, d)) overflows once n / d >= 2^64, which a token sorting after USDC
/// (n = 1e27 token units, d = the oracle USDC value of 1 ETH) reaches at ETH <= $54.21 and the launch reverted. Below that
/// ratio the result is bit-identical to the former formula; at or above it the square root is taken at 2^128 scale and
/// shifted, which loses less than 2^-96 relative precision. Callers keep n / d below 2^128 (1e27 / 1 micro is ~2^90).
library NoerraLaunchPrice {
    function sqrtRatioX96(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator / denominator < (1 << 64)) return Math.sqrt(Math.mulDiv(numerator, 1 << 192, denominator));
        return Math.sqrt(Math.mulDiv(numerator, 1 << 128, denominator)) << 32;
    }
}
