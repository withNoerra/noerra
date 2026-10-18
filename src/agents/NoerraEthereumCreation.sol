// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraAgentAccount, NoerraAgentCredits} from "./NoerraAgents.sol";
import {NoerraLockedCreation} from "./NoerraLaunchpad.sol";
import {NoerraEarnedFeeRouting, INoerraRoutedAccount, INoerraBrainEscrowRegistry} from "./NoerraEarnedFeeRouting.sol";
import {NoerraUsdcFeeHook, NOERRA_TRADE_FEE_BPS} from "./NoerraUsdcFeeHook.sol";

interface INoerraFeeRecipientAccount { function feeRecipient() external view returns (address); }

/// @notice Canonical Ethereum cash market: one 2% USDC hook fee, tax-free transfers, no backers.
/// Collected USDC: agent cash 40% (plus rounding dust) to the agent account; brain 20% exactly to the
/// agent's brain escrow (to the account when none, disabled or full); creator 20% to the account's
/// current fee recipient (the account itself in AGENT mode); treasury 15% to operations; NOERRA burn 5% to the
/// deployment's NoerraBurner (bought on NOERRA's market and burned; accumulated until NOERRA is bound).
contract NoerraEthereumCreation is NoerraLockedCreation {
    using SafeERC20 for IERC20;
    uint256 public constant AGENT_BPS = 4000;
    uint256 public constant BRAIN_BPS = 2000;
    uint256 public constant CREATOR_BPS = 2000;
    uint256 public constant TREASURY_BPS = 1500;
    uint256 public constant BURN_BPS = 500;
    address public immutable burner;
    uint256 public constant SWAP_FEE_BPS = NOERRA_TRADE_FEE_BPS;
    event FeeDistribution(uint256 agentAmount, uint256 brainAmount, uint256 brainAllocated,
        address indexed creatorRecipient, uint256 creatorAmount, uint256 treasuryAmount,
        uint256 burnAmount);
    constructor(IPoolManager manager_, NoerraAgentAccount agent_, NoerraAgentCredits credits_, IERC20 quote_,
        address operations_, address burner_, address factory_)
        NoerraLockedCreation(manager_, agent_, credits_, quote_, operations_, operations_, factory_) {
        require(block.chainid == 1 && operations_ != address(0) && operations_ != address(agent_)
            && burner_.code.length > 0 && burner_ != operations_, "Ethereum treasury");
        burner = burner_;
    }
    function FEE() public pure override returns (uint24) {return 0;}
    function _collectFeeClaims() internal override {
        NoerraUsdcFeeHook(address(launchProtectionHook)).withdrawFees(pool);
    }
    function _usesHookFees() internal pure override returns (bool) {return true;}
    /// @dev USDC transfer that reports failure instead of reverting (no return data accepted only from code).
    function _tryTransfer(address to, uint256 value) private returns (bool) {
        (bool ok, bytes memory ret) = address(dollar).call(abi.encodeCall(IERC20.transfer, (to, value)));
        return ok && (ret.length == 0 ? address(dollar).code.length > 0 : ret.length >= 32 && abi.decode(ret, (bool)));
    }
    /// @dev A recipient that would strand or wedge the row (zero, this market, the burner, the treasury, the pool
    /// manager, the hook, or the agent's own brain escrow) resolves to the agent account.
    function _creatorRecipient() private view returns (address recipient) {
        recipient = INoerraFeeRecipientAccount(address(agent)).feeRecipient();
        if (recipient == address(0) || recipient == address(this) || recipient == burner || recipient == protocolTreasury
            || recipient == address(manager) || recipient == address(launchProtectionHook)
            || recipient == INoerraBrainEscrowRegistry(INoerraRoutedAccount(address(agent)).registry())
                .earnedDiemEscrows(INoerraRoutedAccount(address(agent)).agentId())) recipient = address(agent);
    }
    function _distribute(uint256 amount) internal override {
        uint256 brainAmount = Math.mulDiv(amount, BRAIN_BPS, 10000);
        uint256 creatorAmount = Math.mulDiv(amount, CREATOR_BPS, 10000);
        uint256 treasuryAmount = Math.mulDiv(amount, TREASURY_BPS, 10000);
        uint256 burnAmount = Math.mulDiv(amount, BURN_BPS, 10000);
        uint256 agentAmount = amount - brainAmount - creatorAmount - treasuryAmount - burnAmount;
        if (burnAmount > 0) dollar.safeTransfer(burner, burnAmount);
        address recipient = _creatorRecipient();
        // AGENT mode: the creator row joins the account's single cash transfer. A recipient USDC refuses (for
        // example a blacklisted address) cannot freeze collection: its row then goes to the agent account.
        uint256 accountCash = agentAmount;
        if (recipient != address(agent) && creatorAmount > 0 && !_tryTransfer(recipient, creatorAmount)) recipient = address(agent);
        if (recipient == address(agent)) accountCash += creatorAmount;
        if (treasuryAmount > 0) dollar.safeTransfer(protocolTreasury, treasuryAmount);
        uint256 allocated = NoerraEarnedFeeRouting.pay(dollar, address(agent), accountCash, brainAmount);
        emit FeeDistribution(agentAmount, brainAmount, allocated, recipient, creatorAmount, treasuryAmount, burnAmount);
    }
}
