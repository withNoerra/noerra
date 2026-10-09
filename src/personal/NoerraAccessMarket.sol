// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Funded daily access pools. Payments are escrowed until provider-confirmed use.
/// @dev Provider admission and usage reports are trusted; neither proves GPU capacity or private inference.
contract NoerraAccessMarket is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant DAY = 1 days;
    uint256 public constant EXIT_DELAY = 1 days;
    uint256 public constant RECEIPT_GRACE = 1 hours;
    uint256 private constant SCALE = 1e27;
    bytes32 private constant QUOTE_TYPEHASH = keccak256("CapacityQuote(uint256 start,uint256 capacity,uint256 stakePerUnit,uint256 computePrice,uint256 retailPrice,bytes32 policy,uint256 personalCapacity)");
    IERC20 public immutable coin;
    IERC20 public immutable payment;
    address public immutable provider;
    address public immutable treasury;
    uint256 public immutable feeBps;
    uint256 public totalStaked;
    uint256 public paymentLiability;

    struct CapacityQuote { uint256 start; uint256 capacity; uint256 stakePerUnit; uint256 computePrice; uint256 retailPrice; bytes32 policy; uint256 personalCapacity; }
    struct Epoch {
        address sponsor;
        uint256 capacity;
        uint256 granted;
        uint256 stakePerUnit;
        uint256 computePrice;
        uint256 retailPrice;
        uint256 listed;
        uint256 sold;
        uint256 used;
        uint256 ownerUsed;
        uint256 sellerIndex;
        uint256 sponsorCredit;
        bytes32 policy;
        bool closed;
        uint256 personalCapacity;
        uint256 personalGranted;
    }
    struct Position { uint256 owned; uint256 listed; uint256 claimed; bool registered; }
    struct Order { address buyer; uint256 epoch; uint256 units; uint256 used; bool refunded; }
    struct Charge { uint256 order; uint256 epoch; address owner; uint256 units; bytes32 receipt; }
    struct Recurring { uint256 owned; uint256 listed; uint256 until; bytes32 policy; }
    mapping(address => Recurring) public recurring;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public lockedUntil;
    mapping(address => uint256) public exitAt;
    mapping(uint256 => Epoch) private pools;
    mapping(uint256 => mapping(address => Position)) public positions;
    mapping(uint256 => Order) public orders;
    mapping(bytes32 => bool) public receipts;
    mapping(bytes32 => bytes32) public receiptRecords;
    mapping(address => uint256) public balances;
    uint256 public computeEarnings;
    uint256 public nextOrder = 1;

    error Invalid(); error Unauthorized(); error Unavailable(); error Locked();
    event Staked(address indexed owner, uint256 amount);
    event ExitRequested(address indexed owner, uint256 availableAt);
    event Withdrawn(address indexed owner, uint256 amount);
    event Funded(uint256 indexed epoch, address indexed sponsor, uint256 capacity, bytes32 policy);
    event Registered(uint256 indexed epoch, address indexed owner, uint256 owned, uint256 listed);
    event Bought(uint256 indexed order, uint256 indexed epoch, address indexed buyer, uint256 units, uint256 cost);
    event Used(uint256 indexed order, bytes32 indexed receipt, uint256 units);
    event OwnerUsed(uint256 indexed epoch, address indexed owner, bytes32 indexed receipt, uint256 units);
    event Refunded(uint256 indexed order, uint256 amount);
    event Claimed(address indexed owner, uint256 amount);
    event RecurringConfigured(address indexed owner, uint256 owned, uint256 listed, uint256 until, bytes32 policy);

    constructor(IERC20 coin_, IERC20 payment_, address provider_, address treasury_, uint256 feeBps_)
        EIP712("NoerraAccessMarket", "1") {
        if (address(coin_).code.length == 0 || address(payment_).code.length == 0 || address(coin_) == address(payment_) || provider_ == address(0) || treasury_ == address(0) || feeBps_ > 1000) revert Invalid();
        coin = coin_; payment = payment_; provider = provider_; treasury = treasury_; feeBps = feeBps_;
    }
    function epochState(uint256 epoch) external view returns (Epoch memory) { return pools[epoch]; }
    function quoteDigest(CapacityQuote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, q.start, q.capacity, q.stakePerUnit, q.computePrice, q.retailPrice, q.policy, q.personalCapacity)));
    }
    function _take(IERC20 asset, uint256 amount) private {
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - beforeBalance != amount) revert Invalid();
    }
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0 || exitAt[msg.sender] != 0) revert Invalid();
        _take(coin, amount); staked[msg.sender] += amount; totalStaked += amount;
        emit Staked(msg.sender, amount);
    }
    function requestExit() external {
        if (staked[msg.sender] == 0 || exitAt[msg.sender] != 0) revert Invalid();
        exitAt[msg.sender] = Math.max(block.timestamp + EXIT_DELAY, lockedUntil[msg.sender] + RECEIPT_GRACE);
        delete recurring[msg.sender];
        emit ExitRequested(msg.sender, exitAt[msg.sender]);
    }
    function withdraw() external nonReentrant {
        if (exitAt[msg.sender] == 0 || block.timestamp < exitAt[msg.sender]) revert Locked();
        uint256 amount = staked[msg.sender]; staked[msg.sender] = 0; exitAt[msg.sender] = 0; totalStaked -= amount;
        coin.safeTransfer(msg.sender, amount); emit Withdrawn(msg.sender, amount);
    }
    function fund(CapacityQuote calldata q, bytes calldata signature) external nonReentrant {
        if (q.start % DAY != 0 || q.start <= block.timestamp || q.start > block.timestamp + 31 days || q.capacity == 0 || q.capacity > 1e12 || q.personalCapacity > q.capacity || q.stakePerUnit == 0 || q.computePrice == 0 || q.retailPrice > 1e12 || q.retailPrice <= q.computePrice + Math.mulDiv(q.retailPrice, feeBps, 10000) || q.policy == bytes32(0) || pools[q.start].sponsor != address(0)) revert Invalid();
        if (ECDSA.recover(quoteDigest(q), signature) != provider) revert Unauthorized();
        uint256 funding = q.capacity * q.computePrice; _take(payment, funding); paymentLiability += funding;
        Epoch storage e = pools[q.start]; e.sponsor = msg.sender; e.capacity = q.capacity; e.stakePerUnit = q.stakePerUnit; e.computePrice = q.computePrice; e.retailPrice = q.retailPrice; e.policy = q.policy;
        e.personalCapacity = q.personalCapacity;
        emit Funded(q.start, msg.sender, q.capacity, q.policy);
    }
    function register(uint256 epoch, uint256 ownedUnits, uint256 listedUnits) external {
        _register(epoch, msg.sender, ownedUnits, listedUnits);
    }
    function _register(uint256 epoch, address owner, uint256 ownedUnits, uint256 listedUnits) private {
        Epoch storage e = pools[epoch]; Position storage p = positions[epoch][owner];
        uint256 grant = ownedUnits + listedUnits;
        if (e.sponsor == address(0) || block.timestamp >= epoch || exitAt[owner] != 0 || p.registered || grant == 0 || grant > staked[owner] / e.stakePerUnit || e.granted + grant > e.capacity || e.personalGranted + ownedUnits > e.personalCapacity) revert Invalid();
        p.registered = true; p.owned = ownedUnits; p.listed = listedUnits;
        e.granted += grant; e.listed += listedUnits; e.personalGranted += ownedUnits; lockedUntil[owner] = Math.max(lockedUntil[owner], epoch + DAY);
        emit Registered(epoch, owner, ownedUnits, listedUnits);
    }
    function configureRecurring(uint256 owned, uint256 listed, uint256 until, bytes32 policy) external {
        if (exitAt[msg.sender] != 0 || staked[msg.sender] == 0 || owned + listed == 0 || until <= block.timestamp || until > block.timestamp + 31 days || policy == bytes32(0)) revert Invalid();
        recurring[msg.sender] = Recurring(owned, listed, until, policy);
        emit RecurringConfigured(msg.sender, owned, listed, until, policy);
    }
    function cancelRecurring() external {
        delete recurring[msg.sender];
        emit RecurringConfigured(msg.sender, 0, 0, 0, bytes32(0));
    }
    function activateRecurring(address owner, uint256 epoch) public {
        Recurring storage r = recurring[owner];
        if (epoch != (block.timestamp / DAY + 1) * DAY || r.until < epoch + DAY || r.policy != pools[epoch].policy) revert Invalid();
        _register(epoch, owner, r.owned, r.listed);
    }
    function activateRecurringBatch(address[] calldata owners, uint256 epoch) external {
        if (owners.length == 0 || owners.length > 50) revert Invalid();
        for (uint256 i; i < owners.length; ++i) activateRecurring(owners[i], epoch);
    }
    function buy(uint256 epoch, uint256 units, uint256 maxCost, uint256 deadline) external nonReentrant returns (uint256 id) {
        Epoch storage e = pools[epoch];
        if (block.timestamp < epoch || block.timestamp >= epoch + DAY || e.sponsor == address(0) || units == 0 || units > e.listed - e.sold || block.timestamp > deadline) revert Unavailable();
        uint256 cost = units * e.retailPrice; if (cost > maxCost) revert Invalid();
        _take(payment, cost); paymentLiability += cost; e.sold += units;
        id = nextOrder++; orders[id] = Order(msg.sender, epoch, units, 0, false);
        emit Bought(id, epoch, msg.sender, units, cost);
    }
    function consume(uint256 id, uint256 units, bytes32 receipt) external {
        if (msg.sender != provider) revert Unauthorized();
        _consume(id, units, receipt);
    }
    function _consume(uint256 id, uint256 units, bytes32 receipt) private {
        Order storage o = orders[id]; Epoch storage e = pools[o.epoch];
        if (o.buyer == address(0) || o.refunded || units == 0 || units > o.units - o.used || block.timestamp >= o.epoch + DAY + RECEIPT_GRACE || receipt == bytes32(0) || receipts[receipt]) revert Invalid();
        receipts[receipt] = true; receiptRecords[receipt] = keccak256(abi.encode(id, units)); o.used += units; e.used += units;
        uint256 gross = units * e.retailPrice;
        uint256 compute = units * e.computePrice;
        uint256 fee = Math.mulDiv(gross, feeBps, 10000);
        balances[provider] += compute; balances[treasury] += fee; e.sponsorCredit += compute;
        computeEarnings += compute;
        e.sellerIndex += Math.mulDiv(gross - compute - fee, SCALE, e.listed);
        emit Used(id, receipt, units);
    }
    function consumeOwned(uint256 epoch, address owner, uint256 units, bytes32 receipt) external {
        if (msg.sender != provider) revert Unauthorized();
        _consumeOwned(epoch, owner, units, receipt);
    }
    function _consumeOwned(uint256 epoch, address owner, uint256 units, bytes32 receipt) private {
        Epoch storage e = pools[epoch]; Position storage p = positions[epoch][owner];
        if (block.timestamp < epoch || block.timestamp >= epoch + DAY + RECEIPT_GRACE || units == 0 || units > p.owned || receipt == bytes32(0) || receipts[receipt]) revert Invalid();
        receipts[receipt] = true; receiptRecords[receipt] = keccak256(abi.encode(epoch, owner, units)); p.owned -= units; e.ownerUsed += units; balances[provider] += units * e.computePrice;
        computeEarnings += units * e.computePrice;
        emit OwnerUsed(epoch, owner, receipt, units);
    }
    function consumeBatch(Charge[] calldata charges) external {
        if (msg.sender != provider) revert Unauthorized();
        if (charges.length == 0 || charges.length > 50) revert Invalid();
        for (uint256 i; i < charges.length; ++i) {
            Charge calldata c = charges[i];
            if (c.order == 0) _consumeOwned(c.epoch, c.owner, c.units, c.receipt);
            else {
                Order storage o = orders[c.order];
                if (o.epoch != c.epoch || o.buyer != c.owner) revert Invalid();
                _consume(c.order, c.units, c.receipt);
            }
        }
    }
    function refund(uint256 id) external {
        Order storage o = orders[id];
        if (o.buyer != msg.sender) revert Unauthorized();
        if (o.refunded || block.timestamp < o.epoch + DAY + RECEIPT_GRACE) revert Locked();
        o.refunded = true; uint256 value = (o.units - o.used) * pools[o.epoch].retailPrice;
        balances[msg.sender] += value; emit Refunded(id, value);
    }
    function earned(uint256 epoch, address owner) public view returns (uint256) {
        Position storage p = positions[epoch][owner];
        return Math.mulDiv(p.listed, pools[epoch].sellerIndex, SCALE) - p.claimed;
    }
    function collectEarnings(uint256 epoch) external {
        uint256 amount = earned(epoch, msg.sender); positions[epoch][msg.sender].claimed += amount; balances[msg.sender] += amount;
    }
    function close(uint256 epoch) external {
        Epoch storage e = pools[epoch];
        if (e.sponsor == address(0) || e.closed || block.timestamp < epoch + DAY + RECEIPT_GRACE) revert Locked();
        e.closed = true; balances[e.sponsor] += e.sponsorCredit + (e.capacity - e.used - e.ownerUsed) * e.computePrice; e.sponsorCredit = 0;
    }
    function claim() external nonReentrant {
        _claim(msg.sender);
    }
    function claimCompute() external nonReentrant {
        if (msg.sender != provider) revert Unauthorized();
        uint256 amount = computeEarnings; computeEarnings = 0;
        balances[provider] -= amount; paymentLiability -= amount;
        if (amount != 0) payment.safeTransfer(provider, amount);
        emit Claimed(provider, amount);
    }
    function collectAndClaim(uint256[] calldata epochs) external nonReentrant {
        if (epochs.length == 0 || epochs.length > 31) revert Invalid();
        for (uint256 i; i < epochs.length; ++i) {
            uint256 amount = earned(epochs[i], msg.sender);
            positions[epochs[i]][msg.sender].claimed += amount;
            balances[msg.sender] += amount;
        }
        _claim(msg.sender);
    }
    function _claim(address owner) private {
        if (owner == provider) computeEarnings = 0;
        uint256 amount = balances[owner]; balances[owner] = 0; paymentLiability -= amount;
        if (amount != 0) payment.safeTransfer(owner, amount);
        emit Claimed(owner, amount);
    }
}
