// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Optional pool sharing actually deposited ETH with NOERRA stakers.
/// @dev A deposit proves ETH was received, not its commercial origin or future yield.
contract NoerraRevenuePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SCALE = 1e27;
    IERC20 public immutable coin;
    address public immutable treasury;
    uint256 public totalStaked;
    uint256 public rewardIndex;
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    uint256 public treasuryCredit;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public credit;
    mapping(address => uint256) private paidIndex;

    error InvalidConfiguration();
    error InvalidAmount();
    error TransferFailed();
    event Staked(address indexed owner, uint256 amount);
    event Unstaked(address indexed owner, uint256 amount);
    event RevenueDeposited(address indexed source, uint256 amount, bytes32 indexed serviceReference);
    event Claimed(address indexed owner, uint256 amount);

    constructor(IERC20 coin_, address treasury_) {
        if (address(coin_).code.length == 0 || treasury_ == address(0)) revert InvalidConfiguration();
        coin = coin_;
        treasury = treasury_;
    }

    function earned(address owner) public view returns (uint256) {
        return credit[owner] + Math.mulDiv(staked[owner], rewardIndex - paidIndex[owner], SCALE);
    }

    function _accrue(address owner) private {
        credit[owner] = earned(owner);
        paidIndex[owner] = rewardIndex;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrue(msg.sender);
        uint256 beforeBalance = coin.balanceOf(address(this));
        coin.safeTransferFrom(msg.sender, address(this), amount);
        if (coin.balanceOf(address(this)) - beforeBalance != amount) revert InvalidAmount();
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > staked[msg.sender]) revert InvalidAmount();
        _accrue(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        coin.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function depositRevenue(bytes32 serviceReference) external payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        totalDeposited += msg.value;
        if (totalStaked == 0) treasuryCredit += msg.value;
        else rewardIndex += Math.mulDiv(msg.value, SCALE, totalStaked);
        emit RevenueDeposited(msg.sender, msg.value, serviceReference);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _accrue(msg.sender);
        amount = credit[msg.sender];
        credit[msg.sender] = 0;
        if (amount != 0) {
            totalClaimed += amount;
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
        emit Claimed(msg.sender, amount);
    }

    function claimTreasury() external nonReentrant returns (uint256 amount) {
        if (msg.sender != treasury) revert InvalidConfiguration();
        amount = treasuryCredit;
        treasuryCredit = 0;
        if (amount != 0) {
            totalClaimed += amount;
            (bool ok,) = payable(treasury).call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
    }
}
