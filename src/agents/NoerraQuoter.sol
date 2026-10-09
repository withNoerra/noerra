// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deployment artifact for Uniswap's pinned, unmodified v4 quote logic.
contract NoerraQuoter is V4Quoter {
    constructor(IPoolManager manager) V4Quoter(manager) {}
}
