// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Local interfaces keep NOERRA's pinned creation bytecode independent of the account source.
interface INoerraRoutedAccount {
    function registry() external view returns (address);
    function agentId() external view returns (bytes32);
}
interface INoerraBrainEscrowRegistry { function earnedDiemEscrows(bytes32 id) external view returns (address); }

/// @dev The brain-fund escrow surface fee routing relies on.
interface INoerraBrainEscrow {
    function allocationsEnabled() external view returns (bool);
    function full() external view returns (bool);
    function allocateFromEarnedFees(uint256 amount) external returns (uint256);
}

/// @dev Called only for authenticated earned-fee rows, never deposits or customer principal.
library NoerraEarnedFeeRouting {
    using SafeERC20 for IERC20;

    function _open(INoerraBrainEscrow escrow) private view returns (bool open) {
        try escrow.allocationsEnabled() returns (bool enabled) {
            if (enabled) { try escrow.full() returns (bool isFull) { open = !isFull; } catch {} }
        } catch {}
    }

    /// @notice Pays the agent's cash row to its account and its brain row, exactly, to the agent's
    /// bound brain escrow. With no escrow, a disabled escrow or a full one, the brain row is paid to
    /// the account instead: either way it stays with the agent. Returns the amount the escrow took.
    function pay(IERC20 dollar, address account, uint256 cash, uint256 brain)
        internal returns (uint256 allocated)
    {
        if (brain > 0) {
            address escrow = INoerraBrainEscrowRegistry(INoerraRoutedAccount(account).registry())
                .earnedDiemEscrows(INoerraRoutedAccount(account).agentId());
            if (escrow != address(0) && _open(INoerraBrainEscrow(escrow))) {
                uint256 beforeBalance = dollar.balanceOf(address(this));
                dollar.forceApprove(escrow, brain);
                // A refusing escrow cannot freeze collection: the row then stays with the agent as cash.
                try INoerraBrainEscrow(escrow).allocateFromEarnedFees(brain) returns (uint256 value) { allocated = value; }
                catch { allocated = 0; }
                dollar.forceApprove(escrow, 0);
                require((allocated == brain && dollar.balanceOf(address(this)) + brain == beforeBalance)
                    || (allocated == 0 && dollar.balanceOf(address(this)) == beforeBalance), "Exact brain allocation");
            }
        }
        uint256 rest = cash + brain - allocated;
        if (rest > 0) dollar.safeTransfer(account, rest);
    }
}
