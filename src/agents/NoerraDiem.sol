// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentRegistry} from "./NoerraAgents.sol";

interface IVeniceDiem is IERC20 {
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    function stakedInfos(address who) external view returns (uint256 amountStaked, uint256 coolDownEnd, uint256 coolDownAmount);
}

/// @dev A production reader must read the exact locked position; a PoolManager's total token
///      balance is NOT an individual pool's backing. The reader is immutable and deployment-pinned.
interface IAgentPoolBacking {
    function poolBacking(bytes32 agentId) external view returns (uint256);
}

interface IAgentDiemAuthority { function signer() external view returns (address); }

contract NoerraDiemVault {
    using SafeERC20 for IERC20;
    address public immutable wrapper;
    IVeniceDiem public immutable diem;
    bytes32 public immutable agentId;
    IAgentDiemAuthority public immutable account;
    constructor(IVeniceDiem diem_, bytes32 id_, address account_) {
        require(account_.code.length > 0, "Agent account");
        wrapper = msg.sender; diem = diem_; agentId = id_; account = IAgentDiemAuthority(account_);
    }
    /// @notice ERC-1271 authentication follows the account's current runtime signer.
    ///         This grants no DIEM transfer authority; staking remains wrapper-only.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(hash, signature);
        return error == ECDSA.RecoverError.NoError && recovered == account.signer() && recovered != address(0)
            ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
    modifier onlyWrapper() { require(msg.sender == wrapper, "Wrapper only"); _; }
    function stake(uint256 amount) external onlyWrapper { diem.stake(amount); }
    function initiate(uint256 amount) external onlyWrapper { diem.initiateUnstake(amount); }
    function claim() external onlyWrapper {
        diem.unstake(); IERC20(address(diem)).safeTransfer(wrapper, diem.balanceOf(address(this)));
    }
}

/// @notice Flat DIEM wrapper with a liquid buffer, per-agent stake and FIFO redemption debt.
///         No promise about provider availability or a maximum exit time is encoded here.
contract NoerraDiem is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IVeniceDiem public immutable diem;
    IAgentRegistry public immutable registry;
    IAgentPoolBacking public immutable backingReader;
    uint256 public immutable bufferBps;
    mapping(bytes32 => NoerraDiemVault) public vaults;
    mapping(bytes32 => uint256) public lockedTreasury;
    uint256 public totalLocked;
    uint256 public accountedStaked;
    uint256 public accountedCooldown;
    uint256 public queueDebt;
    uint256 public queueTail;
    uint256 public queueHead = 1;
    struct Redemption { address owner; uint256 remaining; uint256 claimable; }
    mapping(uint256 => Redemption) public redemptions;
    mapping(address => uint256) public claimable;
    uint256 public reservedClaims;
    event Wrapped(address indexed payer, address indexed recipient, uint256 amount);
    event Queued(uint256 indexed request, address indexed owner, uint256 amount);
    event QueueFunded(uint256 indexed request, uint256 amount);
    event Locked(bytes32 indexed agentId, uint256 amount);
    event Reconciled(bytes32 indexed agentId, uint256 target, uint256 stake, uint256 cooldown);

    constructor(IVeniceDiem diem_, IAgentRegistry registry_, IAgentPoolBacking reader_, uint256 bufferBps_)
        ERC20("Noerra DIEM", "nDIEM") {
        require(address(diem_) != address(0) && address(registry_) != address(0) && address(reader_) != address(0), "Configuration");
        require(bufferBps_ >= 1000 && bufferBps_ <= 5000, "Buffer policy");
        diem = diem_; registry = registry_; backingReader = reader_; bufferBps = bufferBps_;
    }
    function wrap(uint256 amount, address recipient) external nonReentrant {
        require(amount > 0 && recipient != address(0) && recipient != address(this), "Amount");
        uint256 beforeBalance = diem.balanceOf(address(this)); IERC20(address(diem)).safeTransferFrom(msg.sender, address(this), amount);
        require(diem.balanceOf(address(this)) == beforeBalance + amount, "Exact backing"); _mint(recipient, amount); emit Wrapped(msg.sender, recipient, amount);
    }
    function activate(bytes32 agentId) public returns (NoerraDiemVault vault) {
        require(registry.accounts(agentId) != address(0), "Registered agent only");
        vault = vaults[agentId]; if (address(vault) == address(0)) { vault = new NoerraDiemVault(diem, agentId, registry.accounts(agentId)); vaults[agentId] = vault; }
    }
    function lockFor(bytes32 agentId, uint256 amount) external nonReentrant {
        activate(agentId); require(amount > 0, "Amount"); _transfer(msg.sender, address(this), amount);
        lockedTreasury[agentId] += amount; totalLocked += amount; emit Locked(agentId, amount);
    }
    function liquidAvailable() public view returns (uint256) { return diem.balanceOf(address(this)) - reservedClaims; }
    function backing() external view returns (uint256) { return diem.balanceOf(address(this)) + accountedStaked + accountedCooldown; }
    function obligations() external view returns (uint256) { return totalSupply() + queueDebt + reservedClaims; }
    function redeem(uint256 amount) external nonReentrant returns (uint256 request) {
        require(amount > 0, "Amount"); _burn(msg.sender, amount);
        uint256 liquid = queueDebt == 0 ? liquidAvailable() : 0;
        uint256 immediate = liquid < amount ? liquid : amount;
        if (immediate > 0) IERC20(address(diem)).safeTransfer(msg.sender, immediate);
        if (immediate < amount) {
            request = ++queueTail; redemptions[request] = Redemption(msg.sender, amount - immediate, 0);
            queueDebt += amount - immediate; emit Queued(request, msg.sender, amount - immediate);
        }
    }
    function fundQueue(uint256 maximumRequests) public {
        require(maximumRequests > 0 && maximumRequests <= 64, "Queue batch");
        uint256 liquid = liquidAvailable(); uint256 count;
        while (queueHead <= queueTail && liquid > 0 && count++ < maximumRequests) {
            Redemption storage row = redemptions[queueHead]; uint256 amount = row.remaining < liquid ? row.remaining : liquid;
            row.remaining -= amount; row.claimable += amount; claimable[row.owner] += amount;
            queueDebt -= amount; reservedClaims += amount; liquid -= amount; emit QueueFunded(queueHead, amount);
            if (row.remaining == 0) queueHead++; else break;
        }
    }
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender]; require(amount > 0, "Nothing funded");
        claimable[msg.sender] = 0; reservedClaims -= amount; IERC20(address(diem)).safeTransfer(msg.sender, amount);
    }
    function target(bytes32 agentId) public view returns (uint256) {
        uint256 pool = backingReader.poolBacking(agentId);
        require(pool <= totalSupply() - totalLocked + queueDebt, "Backing reader bounds");
        // Read this exact position only. During a queued exit, conservatively
        // deduct the outstanding debt from each pool before allocating stake.
        // This never allocates more than the former aggregate pro-rata target:
        // pool - debt <= pool * (totalPools - debt) / totalPools.
        // Queue settlement takes priority; locked treasury remains permanent.
        uint256 liquidPool = pool > queueDebt ? pool - queueDebt : 0;
        return lockedTreasury[agentId] + Math.mulDiv(liquidPool, 10000 - bufferBps, 10000);
    }
    /// @notice Mature exits can be collected even if a pool reader is unavailable.
    ///         This path never creates a stake or invokes the backing reader.
    function harvest(bytes32 agentId) external nonReentrant {
        NoerraDiemVault vault = vaults[agentId];
        require(address(vault) != address(0), "Vault unavailable");
        (, uint256 end, uint256 cooling) = diem.stakedInfos(address(vault));
        require(cooling > 0 && end <= block.timestamp, "Not mature");
        vault.claim(); accountedCooldown -= cooling;
        fundQueue(64);
    }
    /// @notice Anyone may reconcile one agent. Cooldown is observed, never assumed or reset.
    function reconcile(bytes32 agentId) external nonReentrant {
        NoerraDiemVault vault = activate(agentId);
        (uint256 staked, uint256 end, uint256 cooling) = diem.stakedInfos(address(vault));
        if (cooling > 0 && end <= block.timestamp) {
            vault.claim(); accountedCooldown -= cooling; cooling = 0;
            (staked, end,) = diem.stakedInfos(address(vault));
        }
        fundQueue(64);
        uint256 desired = target(agentId);
        if (cooling == 0 && staked > desired) {
            uint256 excess = staked - desired; vault.initiate(excess);
            accountedStaked -= excess; accountedCooldown += excess;
        } else if (cooling == 0 && queueDebt == 0 && desired > staked) {
            uint256 amount = desired - staked;
            uint256 liquid = liquidAvailable();
            if (amount > liquid) amount = liquid;
            if (amount > 0) { IERC20(address(diem)).safeTransfer(address(vault), amount); vault.stake(amount); accountedStaked += amount; }
        }
        (staked,, cooling) = diem.stakedInfos(address(vault)); emit Reconciled(agentId, desired, staked, cooling);
    }
}
