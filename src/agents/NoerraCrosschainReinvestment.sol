// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentRegistry} from "./NoerraAgents.sol";

interface INoerraEarnedComputeMarket {
    function dollar() external view returns (IERC20);
    function registry() external view returns (IAgentRegistry);
    function computeTreasury() external view returns (address);
}

/// @notice Ethereum earned-compute cash: 70% to a dedicated bridge executor, 30% to its agent.
/// @dev Transfers are not evidence of a bridge, DIEM purchase or stake. The dedicated executor
/// is trusted with its received funds; durable off-chain reconciliation must verify each Base step.
/// Customer NCC redemption backing remains in the credits contract, never in this treasury.
contract NoerraCrosschainReinvestment is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable dollar;
    IAgentRegistry public immutable registry;
    INoerraEarnedComputeMarket public immutable computeMarket;
    bytes32 public immutable agentId;
    address public immutable hostingTreasury;
    address public immutable sourceSigner;
    uint256 public immutable reserve;
    uint256 public immutable maximumBatch;
    uint256 public immutable dailyLimit;
    uint256 public constant providerChainId = 8453;
    uint256 public spentDay;
    uint256 public spentToday;
    uint256 public batchNonce;
    event Spent(
        uint256 indexed batchNonce,
        bytes32 indexed agentId,
        uint256 dollars,
        uint256 bridgeDollars,
        uint256 hostingDollars
    );

    constructor(
        IERC20 dollar_,
        IAgentRegistry registry_,
        INoerraEarnedComputeMarket market_,
        bytes32 id_,
        address hosting_,
        address signer_,
        uint256 reserve_,
        uint256 batch_,
        uint256 daily_
    ) {
        require(
            address(dollar_).code.length > 0 && address(registry_).code.length > 0 && address(market_) != address(0),
            "Ethereum wiring"
        );
        require(
            id_ != bytes32(0) && hosting_.code.length > 0 && registry_.accounts(id_) == hosting_,
            "Registered capacity agent"
        );
        require(signer_ != address(0) && signer_ != hosting_ && signer_ != address(this), "Dedicated bridge executor");
        require(
            reserve_ > 0 && batch_ >= 1e6 && batch_ <= 1000e6 && daily_ >= batch_ && daily_ <= 10000e6,
            "Finite purchase limits"
        );
        dollar = dollar_;
        registry = registry_;
        computeMarket = market_;
        agentId = id_;
        hostingTreasury = hosting_;
        sourceSigner = signer_;
        reserve = reserve_;
        maximumBatch = batch_;
        dailyLimit = daily_;
    }

    function bridgeWallet() external view returns (address) {
        return sourceSigner;
    }

    function payment() external view returns (address) {
        return address(dollar);
    }

    function provider() external view returns (address) {
        return sourceSigner;
    }

    function computeEarnings() external view returns (uint256) {
        return dollar.balanceOf(address(this));
    }

    function disburseBatch(uint256 amount)
        external
        nonReentrant
        returns (uint256 nonce, uint256 bridgeAmount, uint256 hostingAmount)
    {
        require(msg.sender == sourceSigner, "Dedicated keeper only");
        require(
            address(computeMarket).code.length > 0 && computeMarket.computeTreasury() == address(this)
                && address(computeMarket.dollar()) == address(dollar)
                && address(computeMarket.registry()) == address(registry),
            "Earned market wiring"
        );
        require(registry.accounts(agentId) == hostingTreasury, "Capacity agent changed");
        require(
            amount >= 1e6 && amount <= maximumBatch && dollar.balanceOf(address(this)) >= reserve + amount,
            "Funded batch"
        );
        uint256 today = block.timestamp / 1 days;
        if (today != spentDay) {
            spentDay = today;
            spentToday = 0;
        }
        require(spentToday + amount <= dailyLimit, "Daily purchase limit");
        spentToday += amount;
        nonce = ++batchNonce;
        hostingAmount = amount * 30 / 100;
        bridgeAmount = amount - hostingAmount;
        dollar.safeTransfer(hostingTreasury, hostingAmount);
        dollar.safeTransfer(sourceSigner, bridgeAmount);
        emit Spent(nonce, agentId, amount, bridgeAmount, hostingAmount);
    }
}
