// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INativeComputeRouter {
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256);
    function refundETH() external payable;
}

/// @notice Converts ETH already paid out by the private vault into provider USDC.
/// @dev No vault deposits, NOERRA stake or customer escrow are held here.
contract NativeComputeTreasury is ReentrancyGuard {
    address public constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint24 public constant POOL_FEE = 500;
    address public immutable vault;
    address public immutable operator;
    uint256 public immutable reserveWei;
    uint256 public earnedWei;
    uint256 public convertedWei;
    event RevenueReceived(uint256 amount);
    event ComputeConverted(address indexed recipient, uint256 spentWei, uint256 amountMicros);
    error InvalidFunding();

    constructor(address vault_, address operator_, uint256 reserveWei_) {
        if (vault_ == address(0) || operator_ == address(0) || vault_ == operator_ || reserveWei_ == 0) revert InvalidFunding();
        vault = vault_; operator = operator_; reserveWei = reserveWei_;
    }

    receive() external payable {
        if (msg.sender == vault) {
            earnedWei += msg.value;
            emit RevenueReceived(msg.value);
        } else if (msg.sender != ROUTER) revert InvalidFunding();
    }

    function convertCompute(uint256 amountMicros, uint256 maximumInputWei, uint256 deadline) external nonReentrant {
        if (msg.sender != operator || amountMicros == 0 || maximumInputWei == 0 ||
            deadline < block.timestamp || deadline > block.timestamp + 5 minutes ||
            earnedWei < maximumInputWei + reserveWei || address(this).balance < maximumInputWei + reserveWei) revert InvalidFunding();
        uint256 beforeEth = address(this).balance;
        uint256 beforeUsdc = USDC.balanceOf(operator);
        uint256 spent = INativeComputeRouter(ROUTER).exactOutputSingle{value: maximumInputWei}(
            INativeComputeRouter.ExactOutputSingleParams(WETH, address(USDC), POOL_FEE, operator, deadline, amountMicros, maximumInputWei, 0)
        );
        INativeComputeRouter(ROUTER).refundETH();
        if (spent == 0 || spent > maximumInputWei || address(this).balance < beforeEth - spent ||
            USDC.balanceOf(operator) != beforeUsdc + amountMicros) revert InvalidFunding();
        earnedWei -= spent;
        convertedWei += spent;
        emit ComputeConverted(operator, spent, amountMicros);
    }
}
