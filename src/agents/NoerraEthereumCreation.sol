// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraAgentAccount, NoerraAgentCredits} from "./NoerraAgents.sol";
import {NoerraLockedCreation} from "./NoerraLaunchpad.sol";
import {NoerraEcosystemVault} from "./NoerraEcosystem.sol";
import {NoerraUsdcFeeHook} from "./NoerraUsdcFeeHook.sol";

/// @notice Canonical Ethereum cash market: one 1.75% USDC hook fee, tax-free transfers.
/// Collected USDC funds the agent, creator, backers and the pinned ecosystem receiver.
contract NoerraEthereumCreation is NoerraLockedCreation {
    using SafeERC20 for IERC20;
    NoerraEcosystemVault public immutable ecosystem;
    uint256 public constant AGENT_BPS = 5000;
    uint256 public constant CREATOR_BPS = 2000;
    uint256 public constant BACKERS_BPS = 1000;
    uint256 public constant ECOSYSTEM_BPS = 2000;
    event FeeDistribution(uint256 agentAmount, uint256 creatorAmount, uint256 backerAmount, uint256 ecosystemAmount);
    constructor(IPoolManager manager_, NoerraAgentAccount agent_, NoerraAgentCredits credits_, IERC20 quote_,
        address operations_, address ecosystem_, address factory_)
        NoerraLockedCreation(manager_, agent_, credits_, quote_, operations_, ecosystem_, factory_) {
        require(block.chainid == 1 && ecosystem_.code.length > 0, "Ethereum ecosystem");
        ecosystem = NoerraEcosystemVault(ecosystem_);
        require(address(ecosystem.dollar()) == address(quote_) && address(ecosystem.manager()) == address(manager_)
            && ecosystem.operationsTreasury() == operations_ && address(ecosystem.market()) != address(0), "Ecosystem policy");
    }
    uint256 public constant SWAP_FEE_BPS = 175;
    function FEE() public pure override returns (uint24) {return 0;}
    function _collectFeeClaims() internal override {
        NoerraUsdcFeeHook(address(launchProtectionHook)).withdrawFees(pool);
    }
    function _usesHookFees() internal pure override returns (bool) {return true;}
    function _distribute(uint256 amount) internal override {
        require(address(backers.credits()) == address(dollar), "Cash backer rewards");
        uint256 creatorAmount = Math.mulDiv(amount, CREATOR_BPS, 10000);
        uint256 ecosystemAmount = Math.mulDiv(amount, ECOSYSTEM_BPS, 10000);
        uint256 backerAmount = backers.totalSupply() > 0 ? Math.mulDiv(amount, BACKERS_BPS, 10000) : 0;
        uint256 agentAmount = amount - creatorAmount - ecosystemAmount - backerAmount;
        if (agentAmount > 0) dollar.safeTransfer(address(agent), agentAmount);
        if (creatorAmount > 0) dollar.safeTransfer(creator, creatorAmount);
        if (backerAmount > 0) {dollar.safeTransfer(address(backers), backerAmount); backers.distribute(backerAmount);}
        if (ecosystemAmount > 0) {
            dollar.forceApprove(address(ecosystem), ecosystemAmount); ecosystem.receiveRevenue(ecosystemAmount);
            dollar.forceApprove(address(ecosystem), 0);
        }
        emit FeeDistribution(agentAmount, creatorAmount, backerAmount, ecosystemAmount);
    }
}
