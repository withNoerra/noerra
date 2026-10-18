// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoerraAgentMirror} from "./NoerraAgentMirror.sol";

/// @notice Same-agent custody for recovered earned-reserve principal, separate from locked nDIEM.
/// @dev The creator may withdraw only the two immutable assets. No operator spend, arbitrary call,
/// approval or upgrade exists. Clients must compare the mirror with finalized Ethereum authority.
contract NoerraEarnedDiemTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentMirror public immutable authority;
    bytes32 public immutable agentId;
    address public immutable sourceAccount;
    address public immutable sourceRegistry;
    IERC20 public immutable dollar;
    IERC20 public immutable diem;
    bytes32 public immutable reviewedPlanHash;
    bool public immutable creatorWithdrawalsEnabled;
    mapping(bytes32 => bool) public operations;
    event RecoveredAssetWithdrawn(bytes32 indexed operation, address indexed asset, address indexed recipient, uint256 amount);

    constructor(NoerraAgentMirror authority_, IERC20 dollar_, IERC20 diem_, bytes32 planHash_, bool creatorWithdrawals_) {
        require(block.chainid == 8453 && address(authority_).code.length > 0 && address(dollar_).code.length > 0 && address(diem_).code.length > 0, "Base treasury infrastructure");
        require(authority_.sourceChainId() == 1 && authority_.agentId() != bytes32(0) && authority_.sourceRegistry() != address(0) && authority_.sourceAccount() != address(0) && planHash_ != bytes32(0), "Reviewed same agent");
        require(address(dollar_) != address(diem_), "Separate assets");
        authority = authority_;
        agentId = authority_.agentId();
        sourceAccount = authority_.sourceAccount();
        sourceRegistry = authority_.sourceRegistry();
        dollar = dollar_;
        diem = diem_;
        reviewedPlanHash = planHash_;
        creatorWithdrawalsEnabled = creatorWithdrawals_;
    }

    /// @notice Zero for the legacy creator-controlled custody policy.
    function platformRecoveryTreasury() external view virtual returns (address) { return address(0); }

    function withdrawRecovered(bytes32 operation, uint256 expectedGeneration, IERC20 asset, address recipient, uint256 amount) external nonReentrant {
        require(creatorWithdrawalsEnabled && msg.sender == authority.human() && expectedGeneration > 0 && authority.generation() == expectedGeneration, "Current creator only");
        require(operation != bytes32(0) && !operations[operation], "Unused operation");
        require((asset == dollar || asset == diem) && recipient != address(0) && recipient != address(this) && amount > 0, "Reviewed recovered asset");
        operations[operation] = true;
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransfer(recipient, amount);
        require(asset.balanceOf(address(this)) + amount == beforeBalance, "Exact recovered debit");
        emit RecoveredAssetWithdrawn(operation, address(asset), recipient, amount);
    }
}