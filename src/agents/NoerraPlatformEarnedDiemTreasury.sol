// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoerraAgentMirror} from "./NoerraAgentMirror.sol";
import {NoerraEarnedDiemTreasury} from "./NoerraEarnedDiemTreasury.sol";

/// @notice Disclosed platform custody for recovered earned DIEM and tracked reserve cash.
/// @dev This contract cannot touch permanently locked nDIEM or the agent's operating account.
contract NoerraPlatformEarnedDiemTreasury is NoerraEarnedDiemTreasury {
    using SafeERC20 for IERC20;
    address private immutable recoveryRecipient;

    constructor(NoerraAgentMirror authority_, IERC20 dollar_, IERC20 diem_, bytes32 planHash_, address recipient_)
        NoerraEarnedDiemTreasury(authority_, dollar_, diem_, planHash_, false)
    {
        require(recipient_ != address(0) && recipient_ != address(this)
            && recipient_ != address(authority_) && recipient_ != authority_.sourceAccount(), "Separate platform treasury");
        recoveryRecipient = recipient_;
    }

    function platformRecoveryTreasury() external view override returns (address) { return recoveryRecipient; }

    /// @notice Requires the fixed platform wallet; even that wallet cannot redirect the proceeds.
    /// Mirror liveness is not a withdrawal dependency after principal has been recovered here.
    function withdrawToPlatform(bytes32 operation, IERC20 asset, uint256 amount) external nonReentrant {
        require(msg.sender == recoveryRecipient, "Platform treasury only");
        require(operation != bytes32(0) && !operations[operation], "Unused operation");
        require((asset == dollar || asset == diem) && amount > 0, "Reviewed recovered asset");
        operations[operation] = true;
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransfer(recoveryRecipient, amount);
        require(asset.balanceOf(address(this)) + amount == beforeBalance, "Exact recovered debit");
        emit RecoveredAssetWithdrawn(operation, address(asset), recoveryRecipient, amount);
    }
}
