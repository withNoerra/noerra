// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {NoerraAgentCredits, IAgentRegistry} from "./NoerraAgents.sol";

/// @notice Expiring agent compute sold through one Buy surface. Current-day capacity
///         and any increase require a statement signed by the deployment-pinned meter.
contract NoerraComputeMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;
    NoerraAgentCredits public immutable credits;
    IERC20 public immutable dollar;
    IAgentRegistry public immutable registry;
    address public immutable meter;
    address public immutable computeTreasury;
    uint256 private constant SCALE = 1e24;
    struct Day { uint256 capacity; uint256 listed; uint256 reserved; uint256 consumed; uint256 price; uint256 earnings; uint256 rewardPerShare; }
    struct Listing { uint256 units; uint256 claimed; uint256 startRewardPerShare; }
    struct Order { address buyer; uint256 epoch; uint256 units; uint256 remaining; uint256 paid; }
    mapping(uint256 => Day) public epochs;
    mapping(uint256 => mapping(bytes32 => Listing)) public listings;
    mapping(bytes32 => Order) public orders;
    mapping(bytes32 => bool) public receipts;
    event Opened(uint256 indexed epoch, uint256 capacity, uint256 price);
    event Listed(uint256 indexed epoch, bytes32 indexed agentId, uint256 units);
    event Bought(bytes32 indexed orderId, address indexed buyer, uint256 epoch, uint256 units);
    event Consumed(bytes32 indexed orderId, bytes32 indexed receiptId, uint256 units, uint256 cashback);

    constructor(IERC20 dollar_, IAgentRegistry registry_, address meter_, address treasury_) {
        require(address(dollar_) != address(0) && address(registry_) != address(0) && meter_ != address(0) && treasury_ != address(0), "Configuration");
        dollar = dollar_; registry = registry_; meter = meter_; computeTreasury = treasury_;
        credits = new NoerraAgentCredits(dollar_, registry_, address(this));
    }
    function accepted(bytes32 hash, bytes calldata signature) private view returns (bool) { return ECDSA.recover(hash.toEthSignedMessageHash(), signature) == meter; }
    function open(uint256 epoch, uint256 capacity, uint256 price, bytes calldata signature) external {
        require(epoch % 1 days == 0 && epoch >= block.timestamp / 1 days * 1 days && epoch <= block.timestamp + 7 days, "Current or future UTC day");
        Day storage d = epochs[epoch];
        require(capacity > d.capacity && capacity <= 1e9 && price > 0 && price <= 1e9 && (d.price == 0 || d.price == price), "Capacity");
        require(accepted(keccak256(abi.encode(block.chainid, address(this), "capacity", epoch, capacity, price)), signature), "Capacity evidence");
        d.capacity = capacity; d.price = price; emit Opened(epoch, capacity, price);
    }
    function list(uint256 epoch, bytes32 agentId, uint256 units, bytes calldata signature) external {
        Day storage d = epochs[epoch]; Listing storage l = listings[epoch][agentId];
        require(registry.accounts(agentId) == msg.sender, "Agent account only");
        require(block.timestamp < epoch + 1 days && d.capacity > 0 && units > 0 && l.units == 0 && d.listed + units <= d.capacity, "Listing");
        require(accepted(keccak256(abi.encode(block.chainid, address(this), "listing", epoch, agentId, units)), signature), "Agent capacity evidence");
        l.units = units; l.startRewardPerShare = d.rewardPerShare; d.listed += units; emit Listed(epoch, agentId, units);
    }
    function buy(uint256 epoch, uint256 units, bytes32 orderId) external nonReentrant {
        Day storage d = epochs[epoch]; require(block.timestamp >= epoch && block.timestamp < epoch + 1 days, "Current day only");
        require(units > 0 && d.reserved + d.consumed + units <= d.listed && orderId != bytes32(0) && orders[orderId].buyer == address(0), "Available units");
        uint256 amount = units * d.price; IERC20(address(credits)).safeTransferFrom(msg.sender, address(this), amount);
        orders[orderId] = Order(msg.sender, epoch, units, units, amount); d.reserved += units; emit Bought(orderId, msg.sender, epoch, units);
    }
    function consume(bytes32 orderId, bytes32 receiptId, uint256 units, bytes calldata signature) external nonReentrant {
        Order storage order = orders[orderId]; Day storage d = epochs[order.epoch];
        require(block.timestamp < order.epoch + 1 days + 1 hours && order.buyer != address(0) && units > 0 && units <= order.remaining, "Order");
        require(receiptId != bytes32(0) && !receipts[receiptId], "Receipt used");
        require(accepted(keccak256(abi.encode(block.chainid, address(this), "consumed", orderId, receiptId, units)), signature), "Consumption evidence");
        receipts[receiptId] = true; order.remaining -= units; d.reserved -= units; d.consumed += units;
        uint256 amount = units * d.price; order.paid -= amount;
        (uint256 sellerAmount,, uint256 cashback) = credits.settleUsage(order.buyer, address(this), computeTreasury, amount);
        d.earnings += sellerAmount; d.rewardPerShare += sellerAmount * SCALE / d.listed;
        emit Consumed(orderId, receiptId, units, cashback);
    }
    function refund(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId]; require(msg.sender == order.buyer && block.timestamp >= order.epoch + 1 days + 1 hours, "Refund time");
        uint256 amount = order.paid; require(amount > 0, "Nothing unused");
        epochs[order.epoch].reserved -= order.remaining; order.remaining = 0; order.paid = 0;
        IERC20(address(credits)).safeTransfer(msg.sender, amount);
    }
    function claim(uint256 epoch, bytes32 agentId) external nonReentrant {
        address account = registry.accounts(agentId); require(account != address(0), "Agent");
        Listing storage l = listings[epoch][agentId]; uint256 earned = l.units * (epochs[epoch].rewardPerShare - l.startRewardPerShare) / SCALE;
        uint256 amount = earned - l.claimed; require(amount > 0, "No earnings"); l.claimed = earned; dollar.safeTransfer(account, amount);
    }
}
