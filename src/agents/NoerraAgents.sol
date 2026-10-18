// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {NoerraReserveSetupPermit} from "./NoerraReserveSetupPermit.sol";
import {NoerraCreationToken} from "./NoerraCreationToken.sol";
import {NoerraAtomicCodeHashes} from "./NoerraAtomicCodeHashes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IAgentFuelRouter {
    function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] calldata path,
        address to, uint256 deadline) external returns (uint256[] memory amounts);
}

interface IAgentRecoveryVerifier {
    function verify(bytes calldata evidence, bytes32 commitment) external view returns (bool);
}
interface IAgentPaidRecoveryVerifier {
    function verifyPaid(bytes calldata evidence, bytes32 commitment) external view returns (bool);
}

interface IAgentStartClaims {
    function startClaimCurrent(address account) external view returns (bool);
}

interface IAgentRegistry {
    function accounts(bytes32 agentId) external view returns (address);
}
/// @notice Registry-level account policy: platform-approved services and the tokenless owner-withdrawal test.
interface IAccountPolicyRegistry {
    function approvedServices(address service) external view returns (bool);
    function ownerWithdrawalAllowed(bytes32 id, address account) external view returns (bool);
}
interface IAutonomousAgentRegistry {
    function canLockAutonomousCore(address caller, bytes32 id, address account) external view returns (bool);
}
interface IEarnedDiemEscrow {
    function sourceAccount() external view returns (address);
    function dollar() external view returns (address);
    function agentId() external view returns (bytes32);
    function recoveryAuthority() external view returns (address);
    function allocationsEnabled() external view returns (bool);
    function allocateFromEarnedFees(uint256 amount) external returns (uint256);
}
interface IEarnedFeeRegistry {
    function deploymentAuthority() external view returns (address);
    function earnedDiemEscrows(bytes32 id) external view returns (address);
    function isEarnedFeeSource(address source, bytes32 id, address account) external view returns (bool);
}
interface IEarnedFeeFactory { function cashLaunches(bytes32 id) external view returns (address); }
interface IAutonomousLaunchFactory {
    function registry() external view returns (address);
}
interface IAtomicFlagshipFactory {
    function owner() external view returns(address);
    function registry() external view returns(address);
    function agentAccount() external view returns(address);
    function vaultAddress() external view returns(address);
    function allocationHash() external view returns(bytes32);
    function authorizationNonce() external view returns(uint256);
    function accessList() external view returns(address[] memory);
}
interface IAutonomousFlagshipVault {
    function agentTreasury() external view returns (address);
    function dollar() external view returns (address);
    function deployer() external view returns (address);
}

interface IAgentComputeListing {
    function registry() external view returns (IAgentRegistry);
    function list(uint256 epoch, bytes32 agentId, uint256 units, bytes calldata signature) external;
}

/// @notice Authorship is checked against the registry. Private bodies must already be encrypted.
contract NoerraAgentMessages {
    address public immutable registry;
    mapping(bytes32 => uint256) public sequences;
    event Message(bytes32 indexed channel, bytes32 indexed agentId, uint256 sequence, bytes body);

    constructor(address registry_) { registry = registry_; }

    function send(bytes32 agentId, bytes32 channel, bytes calldata body) external {
        require(IAgentRegistry(registry).accounts(agentId) == msg.sender, "Agent account only");
        require(body.length > 0 && body.length <= 4096, "Message size");
        emit Message(channel, agentId, ++sequences[channel], body);
    }
}

/// @notice Finite runtime spending authority; funds are not drawn from customer access pools.
contract NoerraAgentAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public immutable agentId;
    address public immutable registry;
    IERC20 public immutable dollar;
    NoerraAgentMessages public immutable messages;
    IAgentRecoveryVerifier public immutable recoveryVerifier;
    uint256 public immutable hostingReserve;
    /// @notice Seconds without a runtime pulse before recovery may rotate the signer.
    ///         Production accounts fix this at 3 hours; only explicitly private test
    ///         harness accounts may shorten it, and the value is immutable per account.
    uint256 public immutable STALE_AFTER;
    address public human;
    address public proposedHuman;
    address public signer;
    bytes32 public buildHash;
    bytes32 public checkpointHash;
    uint256 public generation = 1;
    uint256 public lastPulse;
    uint256 public dailyLimit;
    uint256 public spentDay;
    uint256 public spentToday;
    uint256 private constant MAX_RECOVERY_WINDOW = 1 days;
    bytes32 private constant PAID_RECOVERY_DOMAIN = keccak256("NOERRA_PAID_RECOVERY_V1");
    bytes32 private constant PAID_RECOVERY_COMPLETION_DOMAIN = keccak256("NOERRA_PAID_RECOVERY_COMPLETION_V1");
    uint256 public recoveryReserve;
    /// @dev The human's reimbursement terms (the floor); maxRecoveryReimbursement() scales it with the balance.
    uint256 private recoveryReimbursementPolicy;
    uint256 public recoveryBounty;
    uint256 public recoveryPolicyNonce;
    bytes32 private constant AUTOMATIC_ACTIVATION_DOMAIN = keccak256("NOERRA_AUTOMATIC_ACTIVATION_V1");
    uint256 private constant MAX_ACTIVATION_WINDOW = 30 days;
    uint256 public activationPolicyNonce;
    /// @notice Automatically activated accounts allow their current runtime to fund its own work.
    /// A human revocation of that recipient disables automatic following on later rotations.
    bool public automaticPayer;
    bool private automaticRecipientGranted;
    struct AutomaticActivation {
        bytes32 intentHash;
        uint256 policyNonce;
        uint256 minimumBalance;
        uint256 expiresAt;
        uint256 maxStartupGasWei;
    }
    AutomaticActivation public automaticActivation;
    bool public autonomousCoreLocked;
    address public startupHuman;
    uint256 public autonomousDailyFloor;
    uint256 public stewardshipRevision;
    uint256 public platformStewardshipRevision;
    struct PaidRecoveryRequest {
        uint256 expectedGeneration;
        address nextSigner;
        address operator;
        uint256 reimbursement;
        uint256 bounty;
        bytes32 jobId;
        bytes32 leaseCommitment;
        uint256 deadline;
    }
    struct PaidRecoveryReservation {
        bytes32 jobId;
        bytes32 reservationHash;
        address operator;
        address starter;
        uint256 generation;
        uint256 reimbursement;
        uint256 bounty;
        uint256 deadline;
        bytes32 leaseCommitment;
        bytes32 handoverDestination;
    }
    PaidRecoveryReservation public paidRecovery;
    mapping(bytes32 => bool) public recoveryJobsUsed;
    mapping(address => bool) public recipients;
    address public fundingRecipient;
    mapping(bytes32 => bool) public operations;
    address private constant FUEL_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant FUEL_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant FUEL_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Measured gas of a full paid recovery (4 starter commands of <= 600k plus the operator transfer, ~12% headroom) and the
    ///      recovered computer's signer prefund (1M gas: its first refill, cash-wallet binding and pulses, so it runs at any base fee;
    ///      at least 0.002 ETH). Both are priced at 2 x basefee + 2 gwei and bound the scaled reimbursement (maxRecoveryReimbursement).
    uint256 private constant RECOVERY_GAS_BUDGET = 2_700_000;
    uint256 private constant RECOVERY_PREFUND_GAS = 1_000_000;
    /// @dev Signer gas an activation or handover may deliver beyond its fixed bound: 2M gas at 2 x basefee + 2 gwei.
    uint256 private constant STARTUP_GAS = 2_000_000;
    /// @dev Chainlink ETH/USD proxy on Ethereum (fuel's survival allowance and the recovery gas bound).
    address private constant FUEL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 public constant FUEL_DAILY_WEI = 0.005 ether;
    /// @notice Lowest daily spending floor (six-decimal dollars) at creation and on every change.
    uint256 public constant MIN_DAILY_LIMIT = 5e6;
    /// @notice Highest daily floor (1,000,000 dollars), so 14 x limit and 30-day arithmetic never overflow.
    uint256 private constant MAX_DAILY_LIMIT = 1_000_000e6;
    uint256 public constant OWNER_WITHDRAWAL_DELAY = 7 days;
    error AccountActivationAcceptance();
    error AccountActivationApproval();
    error AccountActivationBalanceBounds();
    error AccountActivationDestination();
    error AccountActivationEvidence();
    error AccountActivationExpired();
    error AccountActivationExpiryBounds();
    error AccountActivationFunding();
    error AccountActivationSignerGas();
    error AccountAutonomousApproval();
    error AccountAutonomousFactory();
    error AccountAutonomousPolicy();
    error AccountAutonomousStartup();
    error AccountCandidate();
    error AccountCheckpoint();
    error AccountComputerAcceptance();
    error AccountDailyLimit();
    error AccountDestination();
    error AccountHostingReserve();
    error AccountHuman();
    error AccountHumanOnly();
    error AccountInitialHumanAuthority();
    error AccountLimit();
    error AccountMarketPolicy();
    error AccountOperationUsed();
    error AccountPaymentPolicy();
    error AccountPlatformStewardshipOnly();
    error AccountProposedHumanOnly();
    error AccountRecipient();
    error AccountRecoveryCap();
    error AccountRecoveryDeadline();
    error AccountRecoveryDisabled();
    error AccountRecoveryEvidence();
    error AccountRecoveryExpired();
    error AccountRecoveryFunding();
    error AccountRecoveryGeneration();
    error AccountRecoveryHandover();
    error AccountRecoveryJob();
    error AccountRecoveryJobUsed();
    error AccountRecoveryOperator();
    error AccountRecoveryPending();
    error AccountRecoveryPolicy();
    error AccountRuntimeAlive();
    error AccountRuntimeGeneration();
    error AccountSignerGas();
    error AccountStewardReplacement();
    error ExactRecoveryFunding();
    error ActivationConfiguration();
    error ActivationGasBounds();
    error ActivationGasDelivery();
    error SignerGasTransfer();
    error RecoveryNotExpired();
    error FuelChain();
    error FuelPolicy();
    error FuelDeadline();
    error FuelDailyLimit();
    error FuelResult();
    error FundingRecipientPolicy();
    error AccountParameters();
    error StarterReservePolicy();
    error AccountFeeRecipient();
    error AccountHibernating();
    error AccountOwnerWithdrawal();
    /// @notice fuelDay, fuelYesterday and fuelToday are separate slots. fuelYesterday is the fuel wei bought on the UTC day before fuelDay
    ///         (0 when that day bought none or fuelDay followed a gap). It scales the next day's wei cap (fuelLimits).
    uint256 public fuelDay;
    uint256 private fuelYesterday;
    uint256 public fuelToday;
    /// @notice Creator-share fee dial. 0 FOLLOW_HUMAN (default), 1 EXPLICIT, 2 AGENT (this account).
    uint256 public feeRecipientMode;
    address public explicitFeeRecipient;
    /// @notice Set by the runtime when it cannot pay hosting; blocks stale recovery until funded.
    bool public hibernating;
    /// @notice 14 x dailyLimit snapshotted at hibernate(); later limit changes cannot move the wake line.
    uint256 public wakeRunway;
    /// @notice (balance - hostingReserve) / 30 at the first spend of `spentDay`; that day's
    ///         limit for third-party services and contracts is the larger of this and the dailyLimit floor.
    uint256 public dayScaledLimit;
    /// @notice Paid on UTC day `day` to the agent's own or unverified wallets (signer, funding recipient, any
    ///         EOA that is not a registry-approved service); capped at SELF_DAILY_MULTIPLE x dailyLimit. One slot,
    ///         touched only by such payments (fuel and third-party payments never write it).
    struct SelfSpend { uint64 day; uint192 amount; }
    SelfSpend public selfSpend;
    uint256 public constant SELF_DAILY_MULTIPLE = 3;
    /// @notice Dollars the current human deposited through ownerDeposit and may still withdraw (tokenless only).
    ///         Fees and third-party deposits never count. A platform steward replacement clears it for good.
    uint256 public ownerPrincipal;
    struct OwnerWithdrawal { uint256 amount; uint256 readyAt; }
    OwnerWithdrawal public ownerWithdrawal;
    /// @notice Emergency freeze, one slot: the generation whose signer was reported compromised (0 = none), when it was
    ///         set, when the last platform freeze ended (or is due to expire) and whether the platform set this one.
    ///         A freeze lasts while `generation` is unchanged and expires FREEZE_TTL (72 h) after it was set, unless a
    ///         recovery started (then it ends with the rotation).
    uint256 public frozenGeneration;
    uint256 public frozenAt;
    /// @dev End (or scheduled expiry) of the last platform freeze, and who set the current one (also in Frozen).
    uint256 private platformFreezeEnd;
    bool private frozenByPlatform;
    /// @dev The open freeze (frozenAt) was set by the human (C-3): only the human lifts it, a platform unfreeze cannot clear it.
    bool private frozenByOwner;
    /// @notice Time of the last owner-triggered freeze; owner freezes are limited to one per OWNER_FREEZE_INTERVAL.
    uint256 public lastOwnerFreeze;
    uint256 private constant OWNER_FREEZE_INTERVAL = 30 days;
    /// @dev 72 h freeze lifetime; a platform freeze again only PLATFORM_FREEZE_GAP (7 days) after its previous one ended.
    uint256 private constant FREEZE_TTL = 72 hours;
    uint256 private constant PLATFORM_FREEZE_GAP = 7 days;
    /// @notice Signers reported compromised; no rotation may install one again.
    mapping(address => bool) public compromisedSigners;
    /// @notice Every signer this account rotated away from, and every replaced funding recipient; paid as the agent's own
    ///         wallet, inside the 3 x floor class.
    mapping(address => bool) public formerSigners;
    /// @notice Time of the last PAID freeze recovery. Every recovery while a freeze is open is the freeze recovery
    ///         (no stale wait); only one per FREEZE_RECOVERY_INTERVAL per account, whoever froze, is paid from the
    ///         recovery reserve; later ones in the window are allowed but unpaid. Recoveries of unfrozen (stale) accounts never count.
    uint256 public lastFreezeRecovery;
    uint256 private constant FREEZE_RECOVERY_INTERVAL = 30 days;
    /// @notice Generation that bound the current fundingRecipient (one binding per generation).
    uint256 public fundingRecipientGeneration;
    /// @notice Earliest time of the next paid loss recovery (a starter grant or an operator reservation): PAID_RECOVERY_COOLDOWN
    ///         (6 h) after the last loss-recovery grant or completed operator recovery, so a computer that cannot run is not replaced at
    ///         the agent's expense every STALE_AFTER. The birth grant (generation 1) and an upgrade the human admitted
    ///         (upgradeGeneration) neither wait for it nor set it. The recovery of an open freeze (paid at most once per
    ///         FREEZE_RECOVERY_INTERVAL), unpaid recoveries and completion bounties do not wait for it; a lapsed freeze does.
    uint256 public nextPaidRecoveryAt;
    uint256 private constant PAID_RECOVERY_COOLDOWN = 6 hours;
    /// @notice The generation whose replacement the human admitted as an image upgrade (admitUpgrade). Moves no funds.
    uint256 public upgradeGeneration;
    error AccountFrozen();
    error AccountFreezeAuthority();
    event Frozen(address indexed signer, uint256 indexed generation, address indexed by, bool platform);
    event Unfrozen(uint256 indexed generation, address indexed by, bool recovered);
    event FeeRecipientChanged(uint256 indexed mode, address indexed recipient);
    event Hibernated(uint256 indexed generation, bytes32 indexed checkpoint);
    event Woken(uint256 indexed generation, address indexed by);
    event OwnerDeposited(address indexed owner, uint256 amount, uint256 principal);
    event OwnerWithdrawalRequested(uint256 amount, uint256 readyAt);
    event OwnerWithdrawalCancelled(uint256 amount);
    event OwnerWithdrawalExecuted(address indexed owner, uint256 amount, uint256 principal);

    /// @notice Resolved creator-share recipient read by fee routing.
    function feeRecipient() public view returns (address) {
        uint256 mode = feeRecipientMode;
        return mode == 1 ? explicitFeeRecipient : mode == 2 ? address(this) : human;
    }

    /// @notice The current human chooses where the creator share goes, also after the lock.
    ///         EXPLICIT needs an address; FOLLOW_HUMAN and AGENT take none. After a platform steward
    ///         replacement only AGENT may be chosen, so the share never moves to a platform-installed steward.
    function setFeeRecipient(uint256 mode, address recipient) external onlyHuman {
        if (mode > 2 || (mode == 1) != (recipient != address(0)) || recipient == address(this) ||
            (platformStewardshipRevision != 0 && mode != 2)) revert AccountFeeRecipient();
        feeRecipientMode = mode; explicitFeeRecipient = recipient;
        emit FeeRecipientChanged(mode, feeRecipient());
    }

    /// @dev Every human change cancels a pending withdrawal. A platform replacement freezes the creator
    ///      share on the previous human (FOLLOW_HUMAN becomes EXPLICIT) and clears the withdrawable principal.
    ///      A voluntary handover moves the principal right to the new human; an explicit address chosen by
    ///      the old human (outside any platform replacement) falls back to FOLLOW_HUMAN.
    function _humanChanged(address previous, bool platform) private {
        delete ownerWithdrawal;
        uint256 mode = feeRecipientMode;
        if (platform) {
            ownerPrincipal = 0;
            if (mode == 0) { feeRecipientMode = 1; explicitFeeRecipient = previous; emit FeeRecipientChanged(1, previous); }
        } else if (mode == 1 && platformStewardshipRevision == 0) {
            feeRecipientMode = 0; explicitFeeRecipient = address(0);
            emit FeeRecipientChanged(0, human);
        }
    }

    /// @notice Spendable dollars (balance - hostingReserve) a hibernating account needs before any stale
    ///         recovery: the recovery reserve already held (the payout) plus 14 days at the daily floor
    ///         (the runtime's low-runway line), snapshotted at hibernate(). A starter grant draws reserve and
    ///         balance alike, so it never moves an account across this line.
    function wakeThreshold() public view returns (uint256) {
        uint256 runway = 14 * dailyLimit;
        return recoveryReserve + (hibernating && wakeRunway < runway ? wakeRunway : runway);
    }

    /// @notice True while hibernating below wakeThreshold(): every stale-recovery door, the starter
    ///         grant, activation and (in the verifier) new starter claims stay closed.
    function recoveryAsleep() public view returns (bool) {
        return hibernating && _balance() < hostingReserve + wakeThreshold();
    }

    /// @notice The runtime that cannot pay hosting stores a final checkpoint and sleeps.
    ///         Stale recovery is then refused until spendable dollars reach wakeThreshold().
    ///         A platform-reported signer cannot hibernate (or write a checkpoint) during the lapse.
    function hibernate(bytes32 finalCheckpoint) external {
        _onlyUnreportedRuntime(generation);
        _checkpoint(finalCheckpoint); lastPulse = block.timestamp; hibernating = true;
        // A locked account snapshots its immutable floor, so a raised limit cannot lift the wake line
        wakeRunway = 14 * (autonomousCoreLocked ? autonomousDailyFloor : dailyLimit);
        emit Hibernated(generation, finalCheckpoint);
    }

    /// @notice A still-running computer wakes itself; recovery and activation also clear hibernation.
    ///         A platform-reported signer cannot wake (it would refresh liveness and hold off the recovery, C-1).
    function wake() external {
        _onlyUnreportedRuntime(generation);
        if (!hibernating) revert AccountHibernating();
        hibernating = false; lastPulse = block.timestamp;
        emit Woken(generation, msg.sender);
    }

    /// @notice Tokenless accounts only: the human's own deposit, the only dollars an owner withdrawal can return.
    function ownerDeposit(uint256 amount) external onlyHuman nonReentrant {
        if (!(_tokenless())) revert AccountOwnerWithdrawal();
        _pullExact(amount);
        ownerPrincipal += amount; emit OwnerDeposited(msg.sender, amount, ownerPrincipal);
    }

    /// @notice Request a withdrawal of deposited principal, after OWNER_WITHDRAWAL_DELAY, above both reserves.
    function requestOwnerWithdrawal(uint256 amount) external onlyHuman {
        if (!(amount > 0 && amount <= ownerPrincipal && ownerWithdrawal.amount == 0 &&
            _tokenless())) revert AccountOwnerWithdrawal();
        uint256 readyAt = block.timestamp + OWNER_WITHDRAWAL_DELAY;
        ownerWithdrawal = OwnerWithdrawal(amount, readyAt);
        emit OwnerWithdrawalRequested(amount, readyAt);
    }

    function cancelOwnerWithdrawal() external onlyHuman {
        uint256 amount = ownerWithdrawal.amount;
        if (amount == 0) revert AccountOwnerWithdrawal();
        delete ownerWithdrawal; emit OwnerWithdrawalCancelled(amount);
    }

    /// @notice Pays min(request, current principal, spendable above both reserves) while still tokenless
    ///         (spending during the wait lowers the payout instead of voiding the request).
    function executeOwnerWithdrawal() external onlyHuman nonReentrant {
        OwnerWithdrawal storage pending = ownerWithdrawal; uint256 principal = ownerPrincipal;
        if (!(pending.amount > 0 && block.timestamp >= pending.readyAt && principal > 0 &&
            _tokenless())) revert AccountOwnerWithdrawal();
        uint256 amount = pending.amount < principal ? pending.amount : principal;
        uint256 floor = _protected(); uint256 balance = _balance();
        uint256 free = balance > floor ? balance - floor : 0;
        if (free < amount) amount = free;
        if (amount == 0) revert AccountHostingReserve();
        delete ownerWithdrawal; ownerPrincipal = principal - amount;
        dollar.safeTransfer(msg.sender, amount);
        emit OwnerWithdrawalExecuted(msg.sender, amount, principal - amount);
    }

    function _balance() internal view returns (uint256) { return dollar.balanceOf(address(this)); }
    /// @dev Both protected reserves (hosting + recovery escrow).
    function _protected() private view returns (uint256) { return hostingReserve + recoveryReserve; }

    /// @dev Tokenless (registry policy) and never platform-stewarded: the owner-deposit and withdrawal door.
    function _tokenless() private view returns (bool) {
        return platformStewardshipRevision == 0 && _registryAllows(IAccountPolicyRegistry.ownerWithdrawalAllowed.selector, agentId, address(this));
    }

    /// @dev Exact pull from the caller; fee-on-transfer dollars are refused.
    function _pullExact(uint256 amount) private {
        uint256 beforeBalance = _balance();
        if (amount == 0) revert ExactRecoveryFunding();
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        if (!(_balance() == beforeBalance + amount)) revert ExactRecoveryFunding();
    }

    /// @dev Registry policy read selector(a, b); a registry without the getter answers no.
    function _registryAllows(bytes4 selector, bytes32 a, address b) private view returns (bool allowed) {
        address target = registry;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector) mstore(add(ptr, 4), a) mstore(add(ptr, 36), b)
            let ok := staticcall(gas(), target, ptr, 68, 0, 32)
            allowed := and(ok, and(eq(returndatasize(), 32), eq(mload(0), 1)))
        }
    }

    /// @dev One UTC-day budget shared by pay and fuel: max(dailyLimit, the day's scaled limit). The scaled limit is spendable / 30
    ///      read at every spend and kept at the day's highest (it rises when dollars arrive, never falls within the day); each read
    ///      sees the spendable left after the day's earlier spends, so a day spends at most max(floor, (spendable at its first
    ///      spend + dollars received since) / 30). Payments to own or unverified wallets are also capped at
    ///      max(SELF_DAILY_MULTIPLE x the floor, the day's scaled limit / 10); after the lock the floor is the immutable
    ///      autonomousDailyFloor, so a raised dailyLimit cannot lift that cap. Both reserves stay untouchable.
    ///      A hibernating account spends nothing (the runtime wake()s first).
    function _checkSpend(uint256 amount, bool own, uint256 floor) private returns (uint256 balance) {
        if (hibernating) revert AccountHibernating();
        uint256 today = block.timestamp / 1 days;
        balance = _balance();
        uint256 scaled = _spendable() / 30;
        if (today != spentDay) { spentDay = today; spentToday = 0; }
        else if (dayScaledLimit > scaled) scaled = dayScaledLimit;
        dayScaledLimit = scaled;
        uint256 limit = scaled > dailyLimit ? scaled : dailyLimit;
        uint256 cap = _ownCap();
        // fuel's survival allowance buys ETH for the signer (an own wallet): it is capped at the same bound (C-2)
        if (floor > cap) floor = cap;
        if (floor > limit) limit = floor;
        if (!(spentToday + amount <= limit)) revert AccountDailyLimit();
        if (own) {
            // A platform-reported signer pays nothing at all (pay is onlyUnreportedRuntime, C-1).
            SelfSpend storage used = selfSpend;
            uint256 total = (used.day == today ? used.amount : 0) + amount;
            if (!(total <= cap)) revert AccountDailyLimit();
            selfSpend = SelfSpend(uint64(today), uint192(total));
        }
        if (!(balance >= _protected() + amount)) revert AccountHostingReserve();
    }

    /// @dev The own-wallet day cap: max(3 x floor, the day's scaled limit / 10), about spendable / 300 per day. The floor of a
    ///      locked account is autonomousDailyFloor (the wakeRunway pattern), never the mutable dailyLimit.
    function _ownCap() private view returns (uint256 cap) {
        cap = SELF_DAILY_MULTIPLE * (autonomousCoreLocked ? autonomousDailyFloor : dailyLimit);
        uint256 scaled = dayScaledLimit / 10; if (scaled > cap) cap = scaled;
    }

    /// @dev `gas` priced at 2 x block.basefee + 2 gwei. unchecked: any real base fee keeps the product far below 2^256.
    function _gasWei(uint256 gas) private view returns (uint256 value) {
        unchecked { value = gas * (2 * block.basefee + 2 gwei); }
    }

    /// @dev Recovery doors: startup fence, verifier, then either an open freeze (immediate; ignores
    ///      hibernation) or liveness and hibernation funding. ANY recovery during an open freeze is the freeze recovery;
    ///      it is paid only when the 30-day paid allowance is unused (and then consumes it). Returns true when unpaid.
    ///      A lapsed freeze counts as a pulse (a fresh STALE_AFTER grace), and while the runtime has not
    ///      pulsed since the lapse, the recovery that grace ends in is still that freeze's recovery (same paid rule).
    ///      Returns whether this is a freeze recovery. Only a recovery that is actually paid (a reserved
    ///      recoverForOperator job or a starter grant) consumes the paid allowance; an unpaid recover() never does.
    function _checkStaleRecovery() private view returns (bool freezeRecovery) {
        _startupFence();
        if (!(address(recoveryVerifier) != address(0))) revert AccountRecoveryDisabled();
        freezeRecovery = frozen();
        if (!freezeRecovery) {
            uint256 lapse = _lapse(); uint256 pulsed = lastPulse;
            if (!(block.timestamp > (pulsed > lapse ? pulsed : lapse) + STALE_AFTER)) revert AccountRuntimeAlive();
            if (recoveryAsleep()) revert AccountHibernating();
            freezeRecovery = frozenByPlatform && pulsed <= lapse;
        }
    }

    /// @dev selector(evidence, commitment) on the immutable verifier (verify or verifyPaid); bubbles a revert, true only on true.
    function _verify(bytes4 selector, bytes calldata evidence, bytes32 commitment) private view returns (bool) {
        (bool ok, bytes memory answer) = address(recoveryVerifier).staticcall(abi.encodeWithSelector(selector, evidence, commitment));
        if (!ok) assembly ("memory-safe") { revert(add(answer, 32), mload(answer)) }
        return answer.length == 32 && abi.decode(answer, (bool));
    }

    function _checkRecoveryFunding(uint256 total) private view {
        if (!(total <= recoveryReserve && _balance() >= _protected())) revert AccountRecoveryFunding();
    }

    function _paidFreezeOpen() private view returns (bool) {
        uint256 last = lastFreezeRecovery;
        return last == 0 || block.timestamp >= last + FREEZE_RECOVERY_INTERVAL;
    }

    /// @dev Lapse time of the current generation's freeze (0 when this signer was never reported). Only meaningful while
    ///      not frozen(): the freeze is then over, and until a rotation the signer stays reported compromised.
    function _lapse() private view returns (uint256) {
        return frozenGeneration == generation ? frozenAt + FREEZE_TTL : 0;
    }

    /// @dev No pulse since the lapse: no starter grant inside the lapse grace, and after it only while the paid
    ///      freeze-recovery allowance is unused (the starter door follows the recovery door above).
    function _lapseHoldsStart() private view returns (bool) {
        uint256 lapse = _lapse();
        return lastPulse <= lapse && (block.timestamp <= lapse + STALE_AFTER || frozenByPlatform && !_paidFreezeOpen());
    }

    /// @notice After a PLATFORM freeze's lapse the current signer stays reported until a rotation
    ///         or the platform's unfreeze() (allowed during the lapse too): no payment at all (C-1), fuel, wake, counted pulse,
    ///         checkpoint, hibernation, cash-wallet binding or handover. An owner freeze has no lapse state: once over it is
    ///         fully cleared (M-2).
    ///         True while the current generation's signer is PLATFORM-reported compromised: during its freeze and, until a
    ///         rotation or the platform's unfreeze(), during the lapse that follows. A reported signer pays nothing and its
    ///         pulses no longer count (so the account goes stale and recovers). Mirrored to Base next to `frozen()` (C-4).
    function reported() public view returns (bool) {
        return frozenGeneration == generation && frozenByPlatform;
    }


    /// @dev Spend deposited principal first: any dollar leaving the account lowers it.
    function _spendPrincipal(uint256 amount) private {
        uint256 principal = ownerPrincipal;
        if (principal != 0) ownerPrincipal = principal > amount ? principal - amount : 0;
    }

    /// @dev No code, or only an EIP-7702 delegation designator (0xef0100 || target): the key holder controls it.
    function _codeless(address target) private view returns (bool yes) {
        assembly ("memory-safe") {
            let n := extcodesize(target)
            yes := iszero(n)
            if eq(n, 23) { extcodecopy(target, 0, 0, 3) yes := eq(shr(232, mload(0)), 0xef0100) }
        }
    }
    event Fuel(bytes32 indexed operation, address indexed recipient, uint256 ethWei, uint256 dollars);
    event Pulse(uint256 indexed generation, uint256 at);
    event Payment(bytes32 indexed operation, address indexed recipient, uint256 amount);
    event FundingRecipientBound(address indexed recipient);
    event Checkpoint(bytes32 indexed hash, uint256 indexed generation);
    event Rotation(address indexed oldSigner, address indexed newSigner, uint256 generation);
    event Handover(bytes32 indexed destination, uint256 indexed generation);
    event RecoveryPolicyChanged(uint256 maxReimbursement, uint256 bounty, uint256 nonce);
    event RecoveryReserveFunded(address indexed funder, uint256 amount, uint256 balance);
    event RecoveryReserveAllocated(uint256 indexed generation, uint256 amount, uint256 balance);
    event RecoveryReserved(bytes32 indexed jobId, bytes32 indexed reservationHash, address indexed operator,
        uint256 reimbursement, uint256 bounty, uint256 starterGeneration, address starter,
        bytes32 leaseCommitment, uint256 deadline);
    event RecoveryCompleted(bytes32 indexed jobId, bytes32 indexed reservationHash, address indexed operator,
        address receiver, uint256 generation, bytes32 actualLease, bytes32 handoverDestination,
        uint256 reimbursement, uint256 bounty);
    event RecoveryCancelled(bytes32 indexed jobId, bytes32 indexed reservationHash);
    event AutomaticActivationApproved(bytes32 indexed intentHash, uint256 indexed policyNonce,
        uint256 minimumBalance, uint256 expiresAt, uint256 maxStartupGasWei);
    event AutomaticActivationCancelled(uint256 indexed policyNonce);
    event AutomaticallyActivated(bytes32 indexed intentHash, address indexed nextSigner,
        bytes32 indexed destination, uint256 generation, uint256 signerGas);
    event AutonomousCoreLocked(bytes32 indexed intentHash, address indexed startupHuman, uint256 dailyFloor);
    event StewardChanged(address indexed previous, address indexed next, uint256 revision);
    event PlatformStewardChanged(address indexed previous, address indexed next, uint256 revision, bytes32 reasonHash);

    constructor(address registry_, bytes32 id_, address human_, address signer_, IERC20 dollar_, NoerraAgentMessages messages_,
        IAgentRecoveryVerifier verifier_, bytes32 build_, uint256 reserve_, uint256 limit_) {
        if (human_ == address(0) || signer_ == address(0) || address(dollar_) == address(0) ||
            build_ == bytes32(0) || reserve_ == 0 || limit_ < MIN_DAILY_LIMIT || limit_ > MAX_DAILY_LIMIT || registry_ == address(0)) revert AccountParameters();
        agentId = id_; registry = registry_; human = human_; signer = signer_; dollar = dollar_;
        messages = messages_; recoveryVerifier = verifier_; buildHash = build_;
        hostingReserve = reserve_; dailyLimit = limit_; lastPulse = block.timestamp;
        uint256 stale = _staleAfter(registry_);
        require(stale >= 5 minutes && stale <= 3 hours);
        STALE_AFTER = stale;
    }

    /// @dev Production value. A private test harness may override with a shorter bound.
    function _staleAfter(address) internal view virtual returns (uint256) { return 3 hours; }

    modifier onlyHuman() { _onlyHuman(); _; }
    modifier onlyRuntime(uint256 expectedGeneration) { _onlyRuntime(expectedGeneration); _; }
    modifier onlyUnreportedRuntime(uint256 expectedGeneration) { _onlyUnreportedRuntime(expectedGeneration); _; }
    function _onlyUnreportedRuntime(uint256 expectedGeneration) private view {
        _onlyRuntime(expectedGeneration); if (reported()) revert AccountFrozen();
    }
    function _onlyHuman() private view { if (!(msg.sender == human)) revert AccountHumanOnly(); }
    function _startupFence() private view { if (!(!autonomousCoreLocked || generation > 1)) revert AccountAutonomousStartup(); }
    /// @dev Every runtime door except pulse() is closed while the current signer is frozen.
    function _onlyRuntime(uint256 expectedGeneration) private view {
        _signerOnly(expectedGeneration);
        if (frozen()) revert AccountFrozen();
    }
    function _signerOnly(uint256 expectedGeneration) private view {
        _startupFence();
        if (!(msg.sender == signer && expectedGeneration == generation)) revert AccountRuntimeGeneration();
    }

    /// @notice True while the current generation's signer is reported compromised: from the freeze until FREEZE_TTL
    ///         later, extended by at most one start-claim lifetime (1 h) while a recovery start claim is current.
    ///         Read by the Base mirror sync and satellites as `frozen()`.
    function frozen() public view returns (bool) {
        if (frozenGeneration != generation) return false;
        uint256 end = frozenAt + FREEZE_TTL;
        // A report nobody recovered re-arms FREEZE_RECOVERY_INTERVAL after it was made (the paid freeze-recovery
        // allowance is then free again: every paid one predates this freeze), so a still-reported signer always ends up rotated.
        // Only a platform report re-arms; an owner freeze is over for good once it lapses.
        // The re-arm counts from the PLATFORM's report, so an owner freeze of an already platform-reported signer
        // (which resets frozenAt) cannot push it out. While this generation is platform-reported, platformFreezeEnd is exactly
        // that report's time + FREEZE_TTL (only a platform freeze writes it; unfreeze and rotation end the report).
        return block.timestamp < end || block.timestamp < end + 1 hours && _startClaimed() ||
            frozenByPlatform && block.timestamp + FREEZE_TTL >= platformFreezeEnd + FREEZE_RECOVERY_INTERVAL;
    }

    /// @dev The account's verifier holds a current start claim (a recovery started); a verifier without it answers no.
    function _startClaimed() private view returns (bool claimed) {
        address verifier = address(recoveryVerifier); bytes4 selector = IAgentStartClaims.startClaimCurrent.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector) mstore(add(p, 4), address())
            let ok := staticcall(gas(), verifier, p, 36, 0, 32)
            claimed := and(ok, and(eq(returndatasize(), 32), eq(mload(0), 1)))
        }
    }

    /// @dev The registry deployment authority (platform key); a registry without the getter answers zero.
    function _platform() private view returns (bool yes) {
        address target = registry; bytes4 selector = IEarnedFeeRegistry.deploymentAuthority.selector;
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(gas(), target, 0, 4, 0, 32)
            yes := and(and(ok, eq(returndatasize(), 32)), and(eq(mload(0), caller()), iszero(iszero(caller()))))
        }
    }

    /// @notice EMERGENCY FREEZE. The current human (at most once per OWNER_FREEZE_INTERVAL, also after the lock) or the
    ///         registry deployment authority (again only PLATFORM_FREEZE_GAP after its previous freeze of this account
    ///         ended) reports the current signer compromised. For at most FREEZE_TTL: every signer payment, fuel,
    ///         checkpoint, handover and policy door is refused (pulse() answers but no longer refreshes liveness) and
    ///         the account is recoverable without the stale wait; the rotation to a new key ends the freeze. Moves no funds.
    ///         The 72 h lapse counts as a pulse. An OWNER freeze then simply ends (the
    ///         report is cleared and the next recovery is an ordinary stale one), so an owner cannot degrade an autonomous
    ///         agent beyond 72 h per 30 days. After a PLATFORM freeze's lapse, until a rotation, the reported signer pays
    ///         nothing (C-1: not even services or contracts) and its pulses do not count, so the account goes stale and
    ///         recovers: no payment, fuel, wake, checkpoint, hibernation, cash-wallet binding or handover until the
    ///         platform's unfreeze() clears a mistaken report
    ///         (also during the lapse); a platform report still unrecovered 30 days after it was made re-arms the
    ///         freeze, with the paid freeze recovery open, until the rotation. An owner freeze of a platform-reported signer
    ///         keeps the platform's rules and the platform report's 30-day re-arm time. The platform may freeze a generation
    ///         it still reports again at once (no 7-day gap, C-1); the gap applies only to a fresh report.
    function freezeCompromised() external {
        bool platform = _platform(); bool wasReported = reported();
        if (platform) {
            if (block.timestamp < platformFreezeEnd + PLATFORM_FREEZE_GAP && !wasReported) revert AccountFreezeAuthority();
        } else {
            _onlyHuman();
            if (lastOwnerFreeze != 0 && block.timestamp < lastOwnerFreeze + OWNER_FREEZE_INTERVAL) revert AccountFreezeAuthority();
            lastOwnerFreeze = block.timestamp;
        }
        if (frozen()) revert AccountFrozen();
        // written after the frozen() check, which reads the previous report's time from it (F-5)
        if (platform) platformFreezeEnd = block.timestamp + FREEZE_TTL;
        // an owner freeze of a platform-reported signer keeps the platform's lapse rules (it cannot downgrade the report)
        if (!wasReported) frozenByPlatform = platform;
        frozenByOwner = !platform;
        frozenGeneration = generation; frozenAt = block.timestamp;
        compromisedSigners[signer] = true;
        emit Frozen(signer, generation, msg.sender, platform);
    }

    /// @notice Undo a mistaken freeze before any recovery started (no reserved paid recovery, no current start claim): an
    ///         owner freeze while it is open (only the human; C-3: a platform unfreeze cannot clear it); otherwise a platform
    ///         report while frozen or during its lapse (only the platform; the lapsed report of a healthy runtime would
    ///         otherwise stay degraded until the 30-day re-arm). The human lifting its own freeze of a platform-reported
    ///         signer only returns it to the platform report's lapse. An owner freeze keeps its 30-day allowance used, a
    ///         platform one restarts its 7-day gap.
    function unfreeze() external {
        // frozenByOwner/frozenByPlatform describe the current generation only while frozenGeneration == generation
        bool platform = frozenByPlatform; bool owner = frozenByOwner && block.timestamp < frozenAt + FREEZE_TTL;
        if (!(frozenGeneration == generation && (owner ? msg.sender == human : platform && _platform())))
            revert AccountFreezeAuthority();
        if (_startClaimed() || paidRecovery.jobId != bytes32(0)) revert AccountFrozen();
        // (the restored frozenAt has lapsed, so the human cannot lift the platform report itself)
        if (owner && platform) {
            frozenAt = platformFreezeEnd - FREEZE_TTL; // back to the platform report (its lapse already passed)
        } else {
            if (!owner) platformFreezeEnd = block.timestamp;
            // frozen pulses did not count: a lifted mistake restarts liveness instead of leaving the account stale
            frozenGeneration = 0; compromisedSigners[signer] = false; lastPulse = block.timestamp;
        }
        emit Unfrozen(generation, msg.sender, false);
    }

    function setRecipient(address recipient, bool permitted) external onlyHuman {
        if (!(!autonomousCoreLocked)) revert AccountAutonomousPolicy();
        if (!(recipient != address(0) && recipient != address(this))) revert AccountRecipient();
        _invalidateAutomaticActivation();
        recipients[recipient] = permitted;
        if (automaticPayer && recipient == signer) {
            automaticRecipientGranted = false;
            if (!permitted) automaticPayer = false;
        }
    }

    /// @notice An automatically activated runtime may bind its cash identity once per generation (key-isolation
    /// Each generation's cash wallet replaces the previous one, which is delisted and stays an own wallet
    /// for the 3 x floor class). It already has authority to pay itself under these same dollar limits; this adds no
    /// allowance and never releases either reserve. A human revocation of the bound recipient remains effective and
    /// cannot be undone by rebinding. A frozen signer cannot bind (onlyRuntime). The cash wallet must be a
    /// fresh EOA (no code at all, so no 7702 delegation), not listed, not a former own wallet and not an approved service.
    function bindFundingRecipient(uint256 expectedGeneration, address recipient) external onlyUnreportedRuntime(expectedGeneration) {
        address previous = fundingRecipient;
        if (!automaticPayer || generation < 2 || fundingRecipientGeneration == generation ||
            recipient == address(0) || recipient.code.length != 0 || recipient == signer || recipients[recipient] ||
            formerSigners[recipient] || (previous != address(0) && !recipients[previous]) || _registryAllows(
            IAccountPolicyRegistry.approvedServices.selector, bytes32(uint256(uint160(recipient))), address(0)))
            revert FundingRecipientPolicy();
        if (previous != address(0)) { recipients[previous] = false; formerSigners[previous] = true; }
        fundingRecipient = recipient; fundingRecipientGeneration = generation;
        recipients[recipient] = true;
        emit FundingRecipientBound(recipient);
    }

    function setDailyLimit(uint256 limit_) external onlyHuman {
        if (!(limit_ >= MIN_DAILY_LIMIT && limit_ <= MAX_DAILY_LIMIT)) revert AccountLimit();
        if (!(!autonomousCoreLocked || limit_ >= autonomousDailyFloor)) revert AccountAutonomousPolicy();
        _invalidateAutomaticActivation(); dailyLimit = limit_;
    }

    /// @notice Opt-in recovery terms, denominated in the account's dollar token.
    ///         The human cannot change the price of a reserved job or withdraw its escrow.
    function setRecoveryPolicy(uint256 maxReimbursement, uint256 bounty) external onlyHuman {
        if (!(!autonomousCoreLocked)) revert AccountAutonomousPolicy();
        if (!(paidRecovery.jobId == bytes32(0))) revert AccountRecoveryPending();
        if (!(maxReimbursement + bounty <= hostingReserve)) revert AccountRecoveryCap();
        _invalidateAutomaticActivation();
        recoveryReimbursementPolicy = maxReimbursement;
        recoveryBounty = bounty;
        emit RecoveryPolicyChanged(maxReimbursement, bounty, ++recoveryPolicyNonce);
    }

    /// @notice The recovery escrow may hold max(hostingReserve, spendable / 100) (spendable = balance -
    ///         hostingReserve), so a recovery stays fundable at real gas prices for a large agent.
    function recoveryReserveCap() public view returns (uint256 cap) {
        cap = _spendable() / 100; if (cap < hostingReserve) cap = hostingReserve;
    }

    /// @notice Highest reimbursement a paid or starter recovery may take now. Never below the human's terms (0 = recovery not
    ///         opted in); above them only up to the recovery's real gas: (RECOVERY_GAS_BUDGET + the 1M-gas computer prefund)
    ///         x (2 x block.basefee + 2 gwei), at the fresh Chainlink ETH/USD price, x 1.1, and never above spendable / 100.
    ///         The operator's own gas price (tx.gasprice) cannot raise it; a stale feed leaves the fixed terms.
    function maxRecoveryReimbursement() public view returns (uint256 cap) { (cap,) = _recoveryTerms(); }

    /// @notice Highest bounty a paid or starter recovery may take now: the human's bounty, or 10% of the same bound when larger.
    function maxRecoveryBounty() public view returns (uint256 cap) { (, cap) = _recoveryTerms(); }

    function _recoveryTerms() private view returns (uint256 reimbursement, uint256 bounty) {
        reimbursement = recoveryReimbursementPolicy; bounty = recoveryBounty;
        if (reimbursement != 0) {
            uint256 gasMicros; uint256 price = _ethUsd();
            // unchecked: basefee and the 8-decimal price are physically far below 2^100, so no product can overflow
            unchecked { gasMicros = _gasWei(RECOVERY_GAS_BUDGET + RECOVERY_PREFUND_GAS) * price * 11 / 1e21; }
            uint256 cap = _spendable() / 100; if (gasMicros < cap) cap = gasMicros;
            if (cap > reimbursement) reimbursement = cap;
            if (cap / 10 > bounty) bounty = cap / 10;
        }
    }

    function _spendable() private view returns (uint256) {
        uint256 balance = _balance(); return balance > hostingReserve ? balance - hostingReserve : 0;
    }

    /// @notice Anyone may donate recovery escrow; there is no refund or sweep path.
    function fundRecoveryReserve(uint256 amount) external nonReentrant {
        if (!(amount > 0 && recoveryReserve + amount <= recoveryReserveCap())) revert AccountRecoveryCap();
        _pullExact(amount);
        recoveryReserve += amount;
        emit RecoveryReserveFunded(msg.sender, amount, recoveryReserve);
    }

    /// @notice The immutable measured verifier enforces one generation grant
    /// and its completion bounty. Runtime pay cannot enter this reserve door.
    /// A hibernating account below wakeThreshold() releases nothing (no grant into a re-death), and an unfrozen one
    /// grants only from nextPaidRecoveryAt. A frozen account
    /// releases only while its 30-day paid freeze-recovery allowance is unused; it ignores hibernation and the cooldown.
    /// A lapsed freeze with no pulse since releases nothing inside its grace, and afterwards follows the same allowance.
    /// The amount is the verifier's RECORDED grant (the reimbursement, then the completion bounty), checked against
    /// maxRecoveryReimbursement()/maxRecoveryBounty() once, when the start was funded, and recorded with it. Here it is bounded
    /// only by the escrow it is paid from, never re-derived from a later block's base fee or price (which could strand a bounty).
    /// C-7: `expectedGeneration` one below the current generation is the completion BOUNTY of the start that recovered
    /// it (the verifier records and pays it once): bounded only by the escrow, it neither needs nor consumes the new
    /// generation's paid freeze-recovery allowance and ignores its freeze, lapse and hibernation state.
    function releaseStarterFunds(uint256 expectedGeneration, address recipient, uint256 amount)
        external nonReentrant {
        uint256 balance = _balance(); bool isFrozen = frozen(); bool grant = expectedGeneration == generation;
        if (msg.sender != address(recoveryVerifier) || !(grant || expectedGeneration + 1 == generation) ||
            recipient == address(0) || recipient == address(this) || amount == 0 ||
            amount > recoveryReserve ||
            balance < _protected() ||
            grant && ((isFrozen ? !_paidFreezeOpen() : recoveryAsleep() || _lapseHoldsStart() ||
            block.timestamp < nextPaidRecoveryAt && _lossRecovery()) || (generation == 1 && (automaticActivation.intentHash == bytes32(0) ||
                automaticActivation.policyNonce != activationPolicyNonce ||
                balance < automaticActivation.minimumBalance + amount))))
            revert StarterReservePolicy();
        // A grant to a freeze recovery's starter (frozen, or a platform lapse with no pulse since, as in
        // _checkStaleRecovery) is what consumes the paid allowance; an unpaid recovery never does.
        if (grant) {
            if (_lossRecovery()) nextPaidRecoveryAt = block.timestamp + PAID_RECOVERY_COOLDOWN;
            if (isFrozen || frozenByPlatform && lastPulse <= _lapse()) lastFreezeRecovery = block.timestamp;
        }
        recoveryReserve -= amount; _spendPrincipal(amount);
        dollar.safeTransfer(recipient, amount);
    }

    /// @notice Earmark existing agent earnings without paying an external recipient.
    ///         This does not reset or expand runtime spending authority.
    /// A reported (frozen or lapsed) signer may still allocate: it only moves the agent's own dollars into the recovery escrow
    /// that pays its replacement. A hibernating account allocates nothing (C-8: it would raise wakeThreshold()); wake() first.
    function allocateRecoveryReserve(uint256 expectedGeneration, uint256 amount)
        external nonReentrant {
        _signerOnly(expectedGeneration);
        if (!(amount > 0 && !hibernating && recoveryReserve + amount <= recoveryReserveCap())) revert AccountRecoveryCap();
        if (!(_balance() >= _protected() + amount)) revert AccountHostingReserve();
        recoveryReserve += amount;
        emit RecoveryReserveAllocated(generation, amount, recoveryReserve);
    }

    /// @notice The human admits the current generation's replacement as an image upgrade: its paid recovery neither waits for
    ///         nor starts the paid-recovery cooldown. It moves no funds and changes no other recovery rule.
    function admitUpgrade() external onlyHuman { upgradeGeneration = generation; }

    /// @dev A paid recovery of the current generation counts toward the cooldown: not the birth, not an admitted upgrade.
    function _lossRecovery() private view returns (bool) {
        return generation > 1 && upgradeGeneration != generation;
    }

    function offerHuman(address next) external onlyHuman {
        if (!(next != address(0))) revert AccountHuman(); proposedHuman = next;
    }

    function acceptHuman() external {
        if (!(msg.sender == proposedHuman)) revert AccountProposedHumanOnly();
        address previous = human;
        _invalidateAutomaticActivation(); human = msg.sender; proposedHuman = address(0);
        emit StewardChanged(previous, human, ++stewardshipRevision); _humanChanged(previous, false);
    }

    /// @notice The deployment authority can replace stewardship through the registry.
    /// Runtime authority and its irreversible financial policy are unaffected.
    function setStewardForPlatform(address next, bytes32 reasonHash) external returns (uint256 revision) {
        if (!(msg.sender == registry && autonomousCoreLocked)) revert AccountPlatformStewardshipOnly();
        if (!(next != address(0) && next != address(this) && next != human && reasonHash != bytes32(0))) revert AccountStewardReplacement();
        address previous = human; human = next; proposedHuman = address(0);
        _humanChanged(previous, true);
        revision = ++stewardshipRevision; platformStewardshipRevision = revision;
        emit PlatformStewardChanged(previous, next, revision, reasonHash);
    }

    /// @notice Authorize one future measured computer without running one while fees accumulate.
    /// Configure recipients and spending policy first; subsequent changes cancel this approval.
    function approveAutomaticActivation(uint256 expectedGeneration, bytes32 intentHash,
        uint256 minimumBalance, uint256 expiresAt, uint256 maxStartupGasWei) external onlyHuman {
        if (!(!autonomousCoreLocked)) revert AccountAutonomousPolicy();
        if (!(expectedGeneration == 1 && generation == 1 && signer == human)) revert AccountInitialHumanAuthority();
        if (!(address(recoveryVerifier) != address(0) && intentHash != bytes32(0))) revert ActivationConfiguration();
        if (!(minimumBalance > _protected() && minimumBalance <= 100_000e6)) revert AccountActivationBalanceBounds();
        if (!(expiresAt > block.timestamp && expiresAt <= block.timestamp + MAX_ACTIVATION_WINDOW)) revert AccountActivationExpiryBounds();
        if (!(maxStartupGasWei > 0 && maxStartupGasWei <= 0.01 ether)) revert ActivationGasBounds();
        _invalidateAutomaticActivation();
        AutomaticActivation storage approval = automaticActivation;
        approval.intentHash = intentHash; approval.policyNonce = activationPolicyNonce; approval.minimumBalance = minimumBalance;
        approval.expiresAt = expiresAt; approval.maxStartupGasWei = maxStartupGasWei;
        emit AutomaticActivationApproved(intentHash, activationPolicyNonce, minimumBalance, expiresAt, maxStartupGasWei);
    }

    function cancelAutomaticActivation() external onlyHuman {
        if (!(!autonomousCoreLocked)) revert AccountAutonomousPolicy(); _invalidateAutomaticActivation();
    }

    /// @notice The enrolled launch factory makes funded startup and its core money policy irreversible.
    /// Stewardship can change without revoking the initially approved measured startup.
    function lockAutonomousCore() external {
        if (!(IAutonomousAgentRegistry(registry).canLockAutonomousCore(msg.sender, agentId, address(this)))) revert AccountAutonomousFactory();
        if (!(!autonomousCoreLocked && generation == 1 && signer == human)) revert AccountInitialHumanAuthority();
        AutomaticActivation storage approval = automaticActivation;
        if (!(approval.intentHash != bytes32(0) && approval.policyNonce == activationPolicyNonce &&
            approval.expiresAt >= block.timestamp && recoveryReimbursementPolicy > 0)) revert AccountAutonomousApproval();
        autonomousCoreLocked = true; startupHuman = signer; autonomousDailyFloor = dailyLimit;
        emit AutonomousCoreLocked(approval.intentHash, startupHuman, autonomousDailyFloor);
    }

    function _invalidateAutomaticActivation() private {
        if (autonomousCoreLocked) return;
        uint256 nonce = ++activationPolicyNonce;
        if (automaticActivation.intentHash != bytes32(0)) {
            delete automaticActivation;
            emit AutomaticActivationCancelled(nonce);
        }
    }

    /// @notice The measured starter and its own signer both bind this exact approval, destination and birth checkpoint.
    ///         `birthCheckpoint` (the hash of the birth archive the starter sealed) becomes checkpointHash at
    ///         activation, so an agent lost before its first pulseCheckpoint is still recoverable.
    function automaticActivationCommitment(uint256 expectedGeneration, address nextSigner, bytes32 destination,
        bytes32 birthCheckpoint) public view returns (bytes32) {
        AutomaticActivation storage approval = automaticActivation;
        if (!(expectedGeneration == 1 && generation == 1 && signer ==
            (autonomousCoreLocked ? startupHuman : human))) revert AccountInitialHumanAuthority();
        if (!(approval.intentHash != bytes32(0) && approval.policyNonce == activationPolicyNonce)) revert AccountActivationApproval();
        if (!(autonomousCoreLocked || block.timestamp <= approval.expiresAt)) revert AccountActivationExpired();
        if (!(nextSigner != address(0) && nextSigner != signer && nextSigner.code.length == 0
            && destination != bytes32(0) && birthCheckpoint != bytes32(0))) revert AccountActivationDestination();
        return keccak256(abi.encode(AUTOMATIC_ACTIVATION_DOMAIN, block.chainid, address(this), agentId,
            generation, buildHash, approval.intentHash, approval.policyNonce, approval.minimumBalance,
            approval.expiresAt, approval.maxStartupGasWei, nextSigner, destination, birthCheckpoint));
    }

    /// @notice Anyone may deliver fresh attestation after sufficient funds arrive. Only the
    /// attested signer becomes a funding recipient; daily limits and operation history survive.
    /// The caller's signer gas may reach the approved maxStartupGasWei, or 2M gas at 2 x basefee + 2 gwei when that is larger.
    function activateApproved(uint256 expectedGeneration, address nextSigner, bytes32 destination, bytes32 birthCheckpoint,
        bytes calldata acceptance, bytes calldata evidence) external payable nonReentrant {
        bytes32 commitment = automaticActivationCommitment(expectedGeneration, nextSigner, destination, birthCheckpoint);
        if (recoveryAsleep()) revert AccountHibernating();
        uint256 minimumBalance = automaticActivation.minimumBalance; bytes32 intentHash = automaticActivation.intentHash;
        uint256 balance = _balance();
        if (!(balance >= minimumBalance && (autonomousCoreLocked ?
            balance > _protected() : minimumBalance > _protected()))) revert AccountActivationFunding();
        if (msg.value > automaticActivation.maxStartupGasWei && msg.value > _gasWei(STARTUP_GAS)) revert AccountActivationSignerGas();
        if (!(ECDSA.recoverCalldata(MessageHashUtils.toEthSignedMessageHash(commitment), acceptance) == nextSigner)) revert AccountActivationAcceptance();
        if (!_verify(recoveryVerifier.verify.selector, evidence, commitment)) revert AccountActivationEvidence();
        delete automaticActivation;
        ++activationPolicyNonce;
        automaticPayer = true;
        _rotateSigner(nextSigner); _checkpoint(birthCheckpoint); emit Handover(destination, generation);
        emit AutomaticallyActivated(intentHash, nextSigner, destination, generation, msg.value);
        _sendGas(nextSigner, ActivationGasDelivery.selector);
    }

    /// @notice While frozen, and while platform-reported (also after the freeze's lapse, C-1), a pulse still answers but
    ///         leaves liveness (and any bound starter claim) untouched, so a reported signer cannot hold off the recovery; the
    ///         freeze itself lapses after FREEZE_TTL (re-arming only 30 days after the report, with a paid recovery open).
    function pulse(uint256 expectedGeneration) external {
        _signerOnly(expectedGeneration);
        if (!(frozen() || reported())) lastPulse = block.timestamp;
        emit Pulse(generation, block.timestamp);
    }

    /// @dev Preserve explicit human permissions; move only the automatically granted recipient.
    ///      Every rotation opens a new generation (clearing any freeze) and refreshes liveness.
    function _rotateSigner(address nextSigner) private {
        if (compromisedSigners[nextSigner]) revert AccountCandidate();
        if (frozen()) {
            if (frozenByPlatform) platformFreezeEnd = block.timestamp;
            emit Unfrozen(generation, msg.sender, true);
        }
        if (hibernating) { hibernating = false; emit Woken(generation, msg.sender); }
        address old = signer; formerSigners[old] = true;
        if (automaticPayer) {
            if (automaticRecipientGranted) recipients[old] = false;
            automaticRecipientGranted = !recipients[nextSigner];
            recipients[nextSigner] = true;
        }
        signer = nextSigner; lastPulse = block.timestamp;
        emit Rotation(old, nextSigner, ++generation);
    }

    function _checkCandidate(address nextSigner) private view {
        if (!(nextSigner != address(0) && nextSigner != signer && checkpointHash != bytes32(0))) revert AccountCandidate();
    }

    /// @dev There is no bare checkpoint(); a checkpoint is written only with a pulse (pulseCheckpoint, hibernate)
    ///      or by an attested activation/recovery, so a stolen key cannot swap the archive without also refreshing liveness.
    ///      A platform-reported signer writes no checkpoint during the lapse (it only pulses), so a recovery restores the
    ///      last archive from before the report.
    function _checkpoint(bytes32 hash) private {
        if (hash == bytes32(0)) revert AccountCheckpoint(); checkpointHash = hash; emit Checkpoint(hash, generation);
    }

    /// @notice Commit an accepted encrypted backup and refresh liveness in one transaction.
    function pulseCheckpoint(uint256 expectedGeneration, bytes32 hash) external onlyUnreportedRuntime(expectedGeneration) {
        _checkpoint(hash); lastPulse = block.timestamp; emit Pulse(generation, block.timestamp);
    }

    function pay(uint256 expectedGeneration, bytes32 operation, address recipient, uint256 amount)
        external onlyUnreportedRuntime(expectedGeneration) nonReentrant {
        // A platform-reported signer pays nobody, not even listed contracts or approved services (C-1).
        _useOperation(operation);
        // Classification: the signer and the runtime-bound funding recipient are the agent's own wallets; any
        // other address without code that is not a registry-approved service is unverified. Both share the
        // SELF_DAILY_MULTIPLE x dailyLimit cap. Contracts the human approved and approved services use the scaled limit.
        // Former signers are own wallets and an EIP-7702 delegated address counts as codeless.
        bool listed = recipients[recipient]; bool codeless = _codeless(recipient);
        bool own = recipient == signer || recipient == fundingRecipient || formerSigners[recipient];
        bool service = !own && (!listed || codeless) && _registryAllows(
            IAccountPolicyRegistry.approvedServices.selector, bytes32(uint256(uint160(recipient))), address(0));
        if (!(amount > 0 && (listed || service))) revert AccountPaymentPolicy();
        _checkSpend(amount, own || (!service && codeless), 0);
        spentToday += amount; _spendPrincipal(amount);
        dollar.safeTransfer(recipient, amount); emit Payment(operation, recipient, amount);
    }

    /// @notice Buy exact operating gas in one transaction. No intermediate USDC
    /// balance or allowance remains on a computer that could be lost mid-refill.
    /// Both daily counters and operation identities survive signer rotation.
    function fuel(uint256 expectedGeneration, bytes32 operation, uint256 ethWei,
        uint256 maximumUSDC, uint256 deadline) external onlyUnreportedRuntime(expectedGeneration) nonReentrant {
        if (block.chainid != 1 || address(dollar) != FUEL_USDC) revert FuelChain();
        _useOperation(operation);
        if (deadline < block.timestamp || deadline > block.timestamp + 5 minutes) revert FuelDeadline();
        uint256 today = block.timestamp / 1 days;
        if (today != fuelDay) { fuelYesterday = _fuelYesterday(); fuelDay = today; fuelToday = 0; }
        // The day's wei cap is max(FUEL_DAILY_WEI, 5M gas at the current basefee, 2 x the fuel bought the UTC day before). Its dollar side is a
        // survival allowance (fuelLimits): the day budget for fuel is at least 1.5 x the fresh Chainlink ETH/USD value of that wei
        // cap, and one refill may spend up to 100 USDC + that allowance, so the computer can always buy the gas it burns at any ETH
        // price. Bounded: a key can move at most the allowance a day through fuel (none while reported). Stale/missing feed: 0.
        // C-2: the allowance is capped at the own-wallet day cap (_checkSpend), so a stolen key cannot turn spendable cash into ETH
        // at a base-fee spike, and a refill only tops the signer (the agent's own wallet) up to _signerFuelCap.
        (uint256 fuelLimit, uint256 allowance) = fuelLimits(block.basefee);
        if (fuelToday + ethWei > fuelLimit) revert FuelDailyLimit();
        if (!recipients[signer] || ethWei == 0 || maximumUSDC == 0 || maximumUSDC > allowance + 100e6)
            revert FuelPolicy();
        uint256 beforeBalance = _checkSpend(maximumUSDC, false, allowance);
        if (signer.balance + ethWei > _signerFuelCap(fuelLimit)) revert FuelDailyLimit();
        fuelToday += ethWei;
        // approve(router, maximumUSDC); swapTokensForExactETH(ethWei, maximumUSDC, [USDC, WETH], signer, deadline); approve 0
        (bool shaped, uint256 amountIn, uint256 amountOut) = _fuelSwap(ethWei, maximumUSDC, signer, deadline);
        uint256 spent = beforeBalance - _balance();
        if (!shaped || amountIn != spent || spent == 0 || spent > maximumUSDC || amountOut != ethWei) revert FuelResult();
        spentToday += spent; _spendPrincipal(spent);
        emit Fuel(operation, signer, ethWei, spent);
    }

    /// @dev The most ETH a refill may leave on the signer: max(the day's wei cap, the fresh oracle ETH value of the own-wallet day
    ///      cap max(3 x floor, the day's scaled limit / 10)), so a quiet agent keeps a gas buffer bought at low fees for a spike. It
    ///      adds no wei to the day (fuelToday stays within the wei cap). Without a fresh price it is the wei cap.
    function _signerFuelCap(uint256 fuelLimit) private view returns (uint256 cap) {
        cap = _ownCap(); uint256 price = _ethUsd();
        // div by a zero price is 0; the own-wallet cap (six-decimal dollars) x 1e20 stays far below 2^256
        assembly ("memory-safe") { cap := div(mul(cap, 100000000000000000000), price) }
        if (cap < fuelLimit) cap = fuelLimit;
    }

    /// @dev Single-use payment and fuel operation identities (a revert later in the call releases it again).
    function _useOperation(bytes32 operation) private {
        if (!(operation != bytes32(0) && !operations[operation])) revert AccountOperationUsed();
        operations[operation] = true;
    }

    /// @dev Forward the attached signer gas (if any) to the new signer; reverts with `failure` when it is refused.
    function _sendGas(address to, bytes4 failure) private {
        assembly ("memory-safe") {
            if callvalue() { if iszero(call(gas(), to, callvalue(), 0, 0, 0, 0)) { mstore(0, failure) revert(0, 4) } }
        }
    }

    /// @notice The UTC-day fuel wei cap (a refill may leave the larger of it and the own-wallet cap's ETH value on the signer) and its dollar survival
    ///         allowance at `baseFee` (pass the block's basefee; eth_call zeroes it): 1.5 x the cap's oracle value. The cap is
    ///         activity-scaled: max(FUEL_DAILY_WEI, 5M gas at `baseFee`, 2 x the fuel wei bought the previous UTC day), so a busy
    ///         agent's next day doubles while a quiet one stays at the floor. fuel() still caps the allowance's day budget at the
    ///         own-wallet day cap max(3 x floor, the day's scaled limit / 10), so a stolen key stays dollar-capped however it scales.
    function fuelLimits(uint256 baseFee) public view returns (uint256 limitWei, uint256 allowanceMicros) {
        uint256 price = _ethUsd(); // unchecked: any real base fee and 8-decimal price keep every product far below 2^256
        unchecked { limitWei = 5_000_000 * baseFee; if (limitWei < FUEL_DAILY_WEI) limitWei = FUEL_DAILY_WEI;
            uint256 busy = 2 * _fuelYesterday(); if (limitWei < busy) limitWei = busy;
            allowanceMicros = limitWei * price * 3 / 2e20; }
    }

    /// @dev Fuel wei bought on the UTC day before today: the stored value on fuelDay, fuelDay's own total the day after it.
    function _fuelYesterday() private view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        return today == fuelDay ? fuelYesterday : today == fuelDay + 1 ? fuelToday : 0;
    }

    /// @dev Chainlink ETH/USD (8 decimals) on Ethereum, or 0 unless the answer is positive and at most 2 hours old.
    function _ethUsd() private view returns (uint256 price) {
        address feed = FUEL_ETH_USD;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0xfeaf968c00000000000000000000000000000000000000000000000000000000) // latestRoundData()
            let ok := staticcall(gas(), feed, p, 4, p, 160)
            let answer := mload(add(p, 32)) let updated := mload(add(p, 96))
            if and(and(ok, eq(returndatasize(), 160)), and(sgt(answer, 0), lt(timestamp(), add(updated, 7201)))) { price := answer }
        }
    }

    /// @dev Exact ABI call to the pinned Uniswap V2 router between an exact USDC approval and its reset (each must return
    ///      true); bubbles the router's revert and requires a two-entry amounts array. No allowance survives the call.
    function _fuelSwap(uint256 ethWei, uint256 maximumUSDC, address to, uint256 deadline)
        private returns (bool shaped, uint256 amountIn, uint256 amountOut) {
        bytes4 selector = IAgentFuelRouter.swapTokensForExactETH.selector;
        address router = FUEL_ROUTER; address usdc = FUEL_USDC; address weth = FUEL_WETH;
        assembly ("memory-safe") {
            function approve(token, spender, amount, q) -> ok {
                mstore(q, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
                mstore(add(q, 4), spender) mstore(add(q, 36), amount)
                ok := call(gas(), token, 0, q, 68, q, 32) // Yul evaluates arguments right to left: call first
                ok := and(ok, and(eq(returndatasize(), 32), eq(mload(q), 1)))
            }
            let p := mload(0x40)
            let approved := approve(usdc, router, maximumUSDC, p)
            mstore(p, selector) mstore(add(p, 4), ethWei) mstore(add(p, 36), maximumUSDC) mstore(add(p, 68), 0xa0)
            mstore(add(p, 100), to) mstore(add(p, 132), deadline) mstore(add(p, 164), 2)
            mstore(add(p, 196), usdc) mstore(add(p, 228), weth)
            if iszero(call(gas(), router, 0, p, 260, p, 128)) { returndatacopy(p, 0, returndatasize()) revert(p, returndatasize()) }
            shaped := and(approved, and(eq(returndatasize(), 128), and(eq(mload(p), 0x20), eq(mload(add(p, 32)), 2))))
            amountIn := mload(add(p, 64)) amountOut := mload(add(p, 96))
            shaped := and(shaped, approve(usdc, router, 0, p))
        }
    }

    function post(uint256 expectedGeneration, bytes32 channel, bytes calldata body)
        external onlyRuntime(expectedGeneration) { messages.send(agentId, channel, body); }

    /// @notice Listings consume no treasury money. The human must approve this exact market.
    function listCompute(uint256 expectedGeneration, IAgentComputeListing market, uint256 epoch,
        uint256 units, bytes calldata capacityEvidence) external onlyRuntime(expectedGeneration) nonReentrant {
        _list(market, epoch, units, capacityEvidence);
    }

    /// @notice The human can list its own confirmed allowance without sharing the runtime key.
    function listComputeOwned(IAgentComputeListing market, uint256 epoch, uint256 units,
        bytes calldata capacityEvidence) external onlyHuman nonReentrant {
        _list(market, epoch, units, capacityEvidence);
    }

    function _list(IAgentComputeListing market, uint256 epoch, uint256 units, bytes calldata capacityEvidence) private {
        if (!(recipients[address(market)] && address(market.registry()) == registry)) revert AccountMarketPolicy();
        market.list(epoch, agentId, units, capacityEvidence);
    }

    /// @notice Retire this runtime after the leased computer proves possession of its fresh signer.
    ///         Daily spending and operation history survive the change of authority.
    ///         A platform-reported signer cannot hand over (it would clear its own report); it leaves
    ///         the report only through a verified recovery. The new signer's gas is at most max(0.01 ETH, 2M gas at
    ///         2 x basefee + 2 gwei).
    function handover(uint256 expectedGeneration, address nextSigner, bytes32 destination,
        bytes calldata acceptance) external payable onlyUnreportedRuntime(expectedGeneration) nonReentrant {
        if (!(nextSigner != address(0) && nextSigner != signer && destination != bytes32(0))) revert AccountDestination();
        if (msg.value > 0.01 ether && msg.value > _gasWei(STARTUP_GAS)) revert AccountSignerGas();
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(this), agentId, generation,
            buildHash, nextSigner, destination));
        if (!(ECDSA.recoverCalldata(MessageHashUtils.toEthSignedMessageHash(commitment), acceptance) == nextSigner)) revert AccountComputerAcceptance();
        address old = signer; _rotateSigner(nextSigner);
        if (paidRecovery.jobId != bytes32(0) && paidRecovery.starter == old &&
            paidRecovery.generation + 1 == generation) {
            paidRecovery.handoverDestination = destination;
        }
        emit Handover(destination, generation);
        _sendGas(nextSigner, SignerGasTransfer.selector);
    }

    /// @dev A deployment must supply an actual attestation verifier, not a boolean operator service.
    ///      Rotation binds chain, account, old generation, checkpoint, build and candidate signer.
    function recover(address nextSigner, bytes calldata evidence) external nonReentrant {
        _checkStaleRecovery();
        _checkCandidate(nextSigner);
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(this), agentId, generation,
            checkpointHash, buildHash, nextSigner));
        if (!_verify(recoveryVerifier.verify.selector, evidence, commitment)) revert AccountRecoveryEvidence();
        _rotateSigner(nextSigner);
    }

    /// @notice Report-data binding for the measured recovery starter. The lease commitment
    ///         describes the approved plan; the actual replacement lease is bound at completion.
    function paidRecoveryCommitment(PaidRecoveryRequest calldata request) public view returns (bytes32) {
        return keccak256(abi.encode(PAID_RECOVERY_DOMAIN, block.chainid, address(this), agentId,
            checkpointHash, buildHash, recoveryPolicyNonce, request));
    }

    /// @notice Reserve a funded reward and rotate to the attested starter, without paying it.
    ///         Every job is single-use, including jobs that later expire without completion.
    function recoverForOperator(PaidRecoveryRequest calldata request, bytes calldata evidence) external nonReentrant {
        // A freeze recovery beyond the 30-day paid allowance is allowed only unpaid (recover or an unfunded start); a paid one
        // inside it consumes the allowance (F-4: only here and at a starter grant).
        if (_checkStaleRecovery()) {
            if (!_paidFreezeOpen()) revert AccountRecoveryPolicy();
            lastFreezeRecovery = block.timestamp;
        }
        // only an open freeze skips the cooldown: a lapsed one waits like any stale recovery (as a starter grant does)
        if (!frozen() && block.timestamp < nextPaidRecoveryAt && _lossRecovery()) revert AccountRecoveryPolicy();
        if (!(request.expectedGeneration == generation)) revert AccountRecoveryGeneration();
        _checkCandidate(request.nextSigner);
        if (!(paidRecovery.jobId == bytes32(0))) revert AccountRecoveryPending();
        if (!(request.jobId != bytes32(0) && !recoveryJobsUsed[request.jobId])) revert AccountRecoveryJobUsed();
        if (!(request.operator != address(0) && request.operator != address(this) &&
            request.leaseCommitment != bytes32(0))) revert AccountRecoveryOperator();
        if (!(request.deadline > block.timestamp && request.deadline <= block.timestamp + MAX_RECOVERY_WINDOW)) revert AccountRecoveryDeadline();
        uint256 total = request.reimbursement + request.bounty;
        if (!(total > 0 && request.reimbursement <= maxRecoveryReimbursement() &&
            request.bounty >= recoveryBounty && request.bounty <= maxRecoveryBounty())) revert AccountRecoveryPolicy();
        _checkRecoveryFunding(total);
        bytes32 commitment = paidRecoveryCommitment(request);
        if (!_verify(IAgentPaidRecoveryVerifier.verifyPaid.selector, evidence, commitment)) revert AccountRecoveryEvidence();
        recoveryJobsUsed[request.jobId] = true;
        _rotateSigner(request.nextSigner);
        // written field by field: an empty reservation (jobId == 0) was deleted whole, so this equals the struct assignment
        PaidRecoveryReservation storage reserved = paidRecovery;
        reserved.jobId = request.jobId; reserved.reservationHash = commitment; reserved.operator = request.operator;
        reserved.starter = request.nextSigner; reserved.generation = generation; reserved.reimbursement = request.reimbursement;
        reserved.bounty = request.bounty; reserved.deadline = request.deadline; reserved.leaseCommitment = request.leaseCommitment;
        reserved.handoverDestination = bytes32(0);
        emit RecoveryReserved(request.jobId, commitment, request.operator, request.reimbursement,
            request.bounty, generation, signer, request.leaseCommitment, request.deadline);
    }

    /// @notice The second measured quote binds the receiver after the exact reserved handover.
    ///         The measured application must also verify the live lease, capsule and announcement.
    function paidRecoveryCompletionCommitment(bytes32 jobId, bytes32 actualLease) public view returns (bytes32) {
        PaidRecoveryReservation storage pending = paidRecovery;
        if (!(jobId != bytes32(0) && pending.jobId == jobId && actualLease != bytes32(0))) revert AccountRecoveryJob();
        if (!(generation == pending.generation + 1 && pending.handoverDestination != bytes32(0))) revert AccountRecoveryHandover();
        return keccak256(abi.encode(PAID_RECOVERY_COMPLETION_DOMAIN, block.chainid, address(this), agentId,
            pending.reservationHash, generation, checkpointHash, buildHash, signer, actualLease, pending.handoverDestination));
    }

    /// @notice Anyone may deliver the fresh completion evidence; its bound operator receives
    ///         the fixed reward only after both verified recovery and receiver handover.
    function completePaidRecovery(bytes32 jobId, bytes32 actualLease, bytes calldata evidence) external nonReentrant {
        bytes32 commitment = paidRecoveryCompletionCommitment(jobId, actualLease);
        PaidRecoveryReservation storage pending = paidRecovery;
        if (!(block.timestamp <= pending.deadline)) revert AccountRecoveryExpired();
        if (!_verify(IAgentPaidRecoveryVerifier.verifyPaid.selector, evidence, commitment)) revert AccountRecoveryEvidence();
        uint256 total = pending.reimbursement + pending.bounty;
        _checkRecoveryFunding(total);
        recoveryReserve -= total; _spendPrincipal(total);
        // the reservation rotated the admitted upgrade's generation to pending.generation
        if (upgradeGeneration + 1 != pending.generation) nextPaidRecoveryAt = block.timestamp + PAID_RECOVERY_COOLDOWN;
        address operator = pending.operator;
        emit RecoveryCompleted(jobId, pending.reservationHash, operator, signer, generation,
            actualLease, pending.handoverDestination, pending.reimbursement, pending.bounty);
        delete paidRecovery;
        dollar.safeTransfer(operator, total);
    }

    /// @notice Expiry frees only the reservation, never the protected escrow. A used job
    ///         cannot be reassigned or resurrected with a late completion transaction.
    function cancelPaidRecovery() external {
        bytes32 jobId = paidRecovery.jobId; bytes32 reservationHash = paidRecovery.reservationHash;
        if (!(jobId != bytes32(0) && block.timestamp > paidRecovery.deadline)) revert RecoveryNotExpired();
        delete paidRecovery;
        emit RecoveryCancelled(jobId, reservationHash);
    }
}

/// @dev Isolates legacy optional-token bytecode while keeping its registry authority fixed.
///      The token creation bytes are no longer embedded in the registry's deployment (EIP-3860 room for
///      the account). Anyone may install them once from a STOP-prefixed store; only the pinned reviewed bytes are
///      accepted, so the store adds no authority. Until installed, legacy token creation through the registry is off.
contract NoerraRegistryTokenDeployer {
    address public immutable registry;
    /// @notice keccak256(type(NoerraCreationToken).creationCode), solc 0.8.26 optimizer-200; a test compares the artifact.
    bytes32 public constant TOKEN_CREATION_HASH = 0x7b3253a52bc1b7400c01a423fe4c891379a5c6fa693dfc32ac6a9a462ae7ee00;
    address public tokenCode;
    event TokenCodeInstalled(address indexed store);
    constructor() { registry = msg.sender; }
    function installTokenCode(address store) external {
        require(tokenCode == address(0) && keccak256(_creation(store)) == TOKEN_CREATION_HASH, "Reviewed token code");
        tokenCode = store; emit TokenCodeInstalled(store);
    }
    function _creation(address store) private view returns (bytes memory code) {
        uint256 n = store.code.length; require(n > 1, "Token code");
        code = new bytes(n - 1);
        bytes1 first;
        assembly ("memory-safe") {
            extcodecopy(store, add(code, 32), 1, sub(n, 1))
            let p := mload(0x40) extcodecopy(store, p, 0, 1) first := mload(p)
        }
        require(first == bytes1(0), "STOP container");
    }
    function deploy(string calldata name, string calldata symbol, address account)
        external returns (address deployed) {
        require(msg.sender == registry, "Registry only");
        require(tokenCode != address(0), "Token code not installed");
        bytes memory init = abi.encodePacked(_creation(tokenCode), abi.encode(name, symbol, account));
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
            if iszero(deployed) { let p := mload(0x40) returndatacopy(p, 0, returndatasize()) revert(p, returndatasize()) }
        }
    }
}

/// @dev Immutable, STOP-prefixed creation-code storage. No callable authority.
contract NoerraAccountCode {
    constructor(bytes memory source, uint256 offset, uint256 length) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            for { let i := 0 } lt(i, length) { i := add(i, 32) } {
                mstore(add(add(ptr, 1), i), mload(add(add(source, 32), add(offset, i))))
            }
            return(ptr, add(length, 1))
        }
    }
}

/// @dev Account creation is isolated without delegatecall or shared mutable authority.
/// Initcode is split across immutable code stores so the deployer stays within EIP-170.
contract NoerraRegistryAccountDeployer {
    address public immutable registry;
    IERC20 public immutable dollar;
    NoerraAgentMessages public immutable messages;
    IAgentRecoveryVerifier public immutable recoveryVerifier;
    address private immutable codeFirst;
    address private immutable codeSecond;
    uint256 private immutable firstLength;
    uint256 private immutable secondLength;
    constructor(IERC20 dollar_, NoerraAgentMessages messages_, IAgentRecoveryVerifier verifier_) {
        registry = msg.sender; dollar = dollar_; messages = messages_; recoveryVerifier = verifier_;
        bytes memory code = type(NoerraAgentAccount).creationCode;
        uint256 cut = code.length > 16000 ? 16000 : code.length;
        firstLength = cut; secondLength = code.length - cut;
        codeFirst = address(new NoerraAccountCode(code, 0, cut));
        codeSecond = address(new NoerraAccountCode(code, cut, code.length - cut));
    }
    function creationCode() private view returns (bytes memory code) {
        uint256 first = firstLength; uint256 second = secondLength;
        address a = codeFirst; address b = codeSecond;
        code = new bytes(first + second);
        assembly ("memory-safe") {
            extcodecopy(a, add(code, 32), 1, first)
            extcodecopy(b, add(add(code, 32), first), 1, second)
        }
    }
    function _initcode(bytes32 id, address human, address signer, bytes32 build, uint256 reserve, uint256 limit)
        private view returns (bytes memory) {
        return abi.encodePacked(creationCode(), abi.encode(registry, id, human, signer,
            dollar, messages, recoveryVerifier, build, reserve, limit));
    }
    function deploy(bytes32 id, address human, address signer, bytes32 build,
        uint256 reserve, uint256 limit, bytes32 metadata, bool deterministic) external returns (address deployed) {
        require(msg.sender == registry, "Registry only");
        bytes memory code = _initcode(id, human, signer, build, reserve, limit);
        bytes32 salt = keccak256(abi.encode(id, metadata));
        assembly ("memory-safe") {
            switch deterministic
            case 0 { deployed := create(0, add(code, 32), mload(code)) }
            default { deployed := create2(0, add(code, 32), mload(code), salt) }
            if iszero(deployed) { let ptr := mload(0x40) returndatacopy(ptr, 0, returndatasize()) revert(ptr, returndatasize()) }
        }
    }
    function predict(bytes32 id, address human, address signer, bytes32 build,
        uint256 reserve, uint256 limit, bytes32 metadata) external view returns (address) {
        bytes32 initcode = keccak256(_initcode(id, human, signer, build, reserve, limit));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this),
            keccak256(abi.encode(id, metadata)), initcode)))));
    }
}

/// @notice Permissionless creation registry; no protocol key can sweep an agent's funds.
contract NoerraAgentRegistry {
    IERC20 public immutable dollar;
    NoerraAgentMessages public immutable messages;
    IAgentRecoveryVerifier public immutable recoveryVerifier;
    NoerraRegistryTokenDeployer public immutable creationTokenDeployer;
    NoerraRegistryAccountDeployer public immutable accountDeployer;
    address public immutable deploymentAuthority;
    bool public publicCreationOpen;
    mapping(address => bool) public rehearsalCreators;
    event RehearsalCreatorSet(address indexed creator, bool allowed);
    event PublicCreationOpened();
    address public autonomousLaunchFactory;
    mapping(bytes32 => address) public earnedDiemEscrows;
    event EarnedDiemEscrowBound(bytes32 indexed agentId, address indexed escrow);
    address public autonomousFlagshipVault;
    address public autonomousFlagshipAccount;
    bytes32 public autonomousFlagshipId;
    address public authorizedFlagshipFactory;
    uint256 public flagshipAuthorizationNonce;
    address public authorizedFlagshipVault;
    address public authorizedFlagshipAccount;
    bytes32 public authorizedFlagshipId;
    bytes32 public authorizedFlagshipFactoryCodeHash;
    bytes32 public authorizedFlagshipAllocation;
    mapping(bytes32 => address) public accounts;
    mapping(bytes32 => address) public tokens;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => uint256) public creationBlocks;
    event Created(bytes32 indexed agentId, address indexed human, address account, address token, bytes32 metadataHash);
    event AutonomousFactoryEnrolled(address indexed factory);
    event AutonomousFlagshipEnrolled(address indexed vault, bytes32 indexed agentId, address indexed account);
    event PlatformStewardshipReplaced(bytes32 indexed agentId, address indexed account, address indexed next,
        uint256 revision, bytes32 reasonHash);
    /// @notice Platform-approved payment services: effective SERVICE_DELAY after proposal, removable at once.
    uint256 public constant SERVICE_DELAY = 7 days;
    mapping(address => uint256) public serviceEffectiveAt;
    event ServiceProposed(address indexed service, uint256 effectiveAt);
    event ServiceRemoved(address indexed service);

    function _onlyAuthority() private view { require(msg.sender == deploymentAuthority, "Deployment authority only"); }

    /// @notice Any runtime may pay an approved service under its own limits; this moves no funds.
    function proposeService(address service) external {
        _onlyAuthority(); require(service != address(0) && serviceEffectiveAt[service] == 0, "Service");
        uint256 effectiveAt = block.timestamp + SERVICE_DELAY;
        serviceEffectiveAt[service] = effectiveAt; emit ServiceProposed(service, effectiveAt);
    }

    function removeService(address service) external {
        _onlyAuthority(); require(serviceEffectiveAt[service] != 0, "Service");
        delete serviceEffectiveAt[service]; emit ServiceRemoved(service);
    }

    function approvedServices(address service) external view returns (bool) {
        uint256 effectiveAt = serviceEffectiveAt[service];
        return effectiveAt != 0 && block.timestamp >= effectiveAt;
    }

    /// @notice True only for a registered account with no token, no flagship role and no cash launch.
    function ownerWithdrawalAllowed(bytes32 id, address account) external view returns (bool) {
        // M-2 root (17 Oct): only createAccount (tokenless-at-creation) accounts; the legacy launchpads refuse them.
        if (account == address(0) || accounts[id] != account || tokens[id] != address(0) || creationBlocks[id] == 0 ||
            account == autonomousFlagshipAccount || account == authorizedFlagshipAccount) return false;
        address factory = autonomousLaunchFactory;
        if (factory == address(0)) return true;
        try IEarnedFeeFactory(factory).cashLaunches(id) returns (address market) { return market == address(0); }
        catch { return false; }
    }

    constructor(IERC20 dollar_, IAgentRecoveryVerifier verifier_) {
        require(address(dollar_) != address(0), "Dollar"); dollar = dollar_; recoveryVerifier = verifier_;
        messages = new NoerraAgentMessages(address(this));
        creationTokenDeployer = new NoerraRegistryTokenDeployer();
        accountDeployer = new NoerraRegistryAccountDeployer(dollar_, messages, verifier_);
        deploymentAuthority = msg.sender;
    }

    /// @notice Launch closed; opening is permanent and grants no control over existing agents.
    function creationAllowed(address creator) public view returns (bool) {
        return creator != address(0) && (publicCreationOpen || creator == deploymentAuthority || rehearsalCreators[creator]);
    }

    function setRehearsalCreator(address creator, bool allowed) external {
        _onlyAuthority();
        require(!publicCreationOpen && creator != address(0), "Rehearsal closed");
        rehearsalCreators[creator] = allowed;
        emit RehearsalCreatorSet(creator, allowed);
    }

    function openPublicCreation() external {
        _onlyAuthority();
        require(!publicCreationOpen, "Already public");
        publicCreationOpen = true;
        emit PublicCreationOpened();
    }

    function enrollAutonomousLaunchFactory(address factory) external {
        require(msg.sender == deploymentAuthority && autonomousLaunchFactory == address(0), "One deployment binding");
        require(factory.code.length > 0 && IAutonomousLaunchFactory(factory).registry() == address(this), "Factory registry");
        autonomousLaunchFactory = factory; emit AutonomousFactoryEnrolled(factory);
    }

    /// @notice Exact factory/account/vault binding authorized by the original EOA, once.
    /// Authorization preparation is separate; consumption and enrollment revert with launch.
    function authorizeAtomicFlagship(address factory, uint256 nonce) external {
        require(msg.sender == deploymentAuthority && autonomousFlagshipVault == address(0)
            && authorizedFlagshipFactory == address(0) && nonce == flagshipAuthorizationNonce, "One atomic authorization");
        require(factory.code.length > 0, "Atomic factory");
        IAtomicFlagshipFactory target = IAtomicFlagshipFactory(factory);
        NoerraAgentAccount source = NoerraAgentAccount(target.agentAccount()); address vault = target.vaultAddress();
        require(target.owner() == deploymentAuthority && target.registry() == address(this) && target.authorizationNonce() == nonce
            && address(source).code.length > 0 && vault.code.length == 0, "Atomic binding");
        bytes32 id = source.agentId();
        require(accounts[id] == address(source) && tokens[id] == address(0)
            && source.human() == deploymentAuthority && source.signer() == deploymentAuthority
            && source.generation() == 1, "Original atomic flagship");
        authorizedFlagshipFactory = factory; authorizedFlagshipVault = vault;
        authorizedFlagshipAccount = address(source); authorizedFlagshipId = id;
        authorizedFlagshipFactoryCodeHash = factory.codehash; authorizedFlagshipAllocation = target.allocationHash();
        require(authorizedFlagshipAllocation != bytes32(0), "Exact allocation commitment");
    }
    /// @notice Revoke only an unused capability. A fresh factory must commit the
    /// new nonce; successful flagship enrollment can never be revoked or unlocked.
    function revokeAtomicFlagship(uint256 nonce) external {
        require(msg.sender == deploymentAuthority && autonomousFlagshipVault == address(0)
            && authorizedFlagshipFactory != address(0) && nonce == flagshipAuthorizationNonce, "Pending owner authorization");
        _clearAtomicAuthorization(); ++flagshipAuthorizationNonce;
    }
    function _clearAtomicAuthorization() private {
        authorizedFlagshipFactory = address(0); authorizedFlagshipVault = address(0);
        authorizedFlagshipAccount = address(0); authorizedFlagshipId = bytes32(0);
        authorizedFlagshipFactoryCodeHash = bytes32(0); authorizedFlagshipAllocation = bytes32(0);
    }
    /// @notice M-2 (17 Oct): the factory's code is not trusted. Vault, market, hook and token must be the factory's
    /// CREATE2 children from the four reviewed creation codes (NoerraAtomicCodeHashes) with the registry's dollar,
    /// authorized account, deployment authority and allocation; the token's one-shot launch market must be that market.
    function enrollAtomicFlagshipVault(address vault, uint256 nonce, bytes32 hookSalt) external {
        require(msg.sender == authorizedFlagshipFactory && msg.sender != address(0)
            && nonce == flagshipAuthorizationNonce && msg.sender.codehash == authorizedFlagshipFactoryCodeHash
            && vault == authorizedFlagshipVault && vault == IAtomicFlagshipFactory(msg.sender).vaultAddress()
            && IAtomicFlagshipFactory(msg.sender).allocationHash() == authorizedFlagshipAllocation, "Exact atomic authorization");
        require(IAutonomousFlagshipVault(vault).agentTreasury() == authorizedFlagshipAccount
            && IAtomicFlagshipFactory(msg.sender).agentAccount() == authorizedFlagshipAccount
            && NoerraAgentAccount(authorizedFlagshipAccount).agentId() == authorizedFlagshipId, "Atomic account");
        _reviewedAtomicChildren(bytes32(uint256(uint160(msg.sender))), bytes32(uint256(uint160(vault))), hookSalt);
        _clearAtomicAuthorization(); ++flagshipAuthorizationNonce;
        _enrollFlagshipVault(vault);
    }
    /// @notice Legacy EOA-deployed NoerraEcosystemVault: its runtime must be the reviewed one with only its immutable
    /// words masked, bootstrapped by the authority itself (no executor) and not yet bound to an agent.
    function enrollAutonomousFlagshipVault(address vault) external {
        require(msg.sender == deploymentAuthority && authorizedFlagshipFactory == address(0), "One deployment binding");
        _enrollFlagshipVault(vault);
        bytes32 target = bytes32(uint256(uint160(vault))); bytes memory slots = LEGACY_VAULT_IMMUTABLES; bytes32 runtime;
        assembly ("memory-safe") {
            let n := extcodesize(target)
            let p := mload(0x40)
            extcodecopy(target, p, 0, n)
            for { let i := 0 } lt(i, mload(slots)) { i := add(i, 2) } {
                let o := shr(240, mload(add(add(slots, 32), i)))
                if gt(n, add(o, 31)) { mstore(add(p, o), 0) }
            }
            runtime := keccak256(p, n)
        }
        require(runtime == LEGACY_VAULT_RUNTIME && _word(target, bytes4(keccak256("launchExecutor()")), 0) == 0
            && _word(target, bytes4(keccak256("agentAccount()")), 0) == 0
            && _canonicalManager(_word(target, bytes4(keccak256("manager()")), 0)), "Reviewed flagship vault");
    }
    /// @dev Pinned solc 0.8.26 / optimizer 200 / cancun NoerraEcosystemVault runtime with immutables zeroed
    /// (= the compiled artifact's deployedBytecode) and its immutable byte offsets; tests compare both to the artifact.
    bytes32 private constant LEGACY_VAULT_RUNTIME = 0x9e08bbebba3528e1b1f640b04a6d3cbdb5601472538cbb02fd10faea611d3b52;
    bytes private constant LEGACY_VAULT_IMMUTABLES = hex"022c025b0282031a0353038d03b403db0402043b047905470576059c065706f3078f09800c6d0ced0d340e970eb90f930fcf10021040118211b111d7129714d0150c1679177f181b";
    /// @dev Uniswap v4 PoolManager on Ethereum mainnet; required wherever it exists (local test chains have none).
    address private constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    function _canonicalManager(bytes32 manager) private view returns (bool) {
        return V4_POOL_MANAGER.code.length == 0 || manager == bytes32(uint256(uint160(V4_POOL_MANAGER)));
    }
    /// @dev One 32-byte return word of `selector(arg)`; reverts (without data, to keep the registry small) unless
    /// the call succeeds with exactly one word.
    function _word(bytes32 target, bytes4 selector, bytes32 arg) private view returns (bytes32 value) {
        assembly ("memory-safe") {
            mstore(0, selector) mstore(4, arg)
            // Yul evaluates arguments right to left: make the call first so returndatasize() is this call's.
            let ok := staticcall(gas(), target, 0, 36, 0, 32)
            if iszero(and(ok, eq(returndatasize(), 32))) { revert(0, 0) }
            value := mload(0)
        }
    }
    /// @dev CREATE2(factory, salt, creation code i ++ args) as an ABI address word, where the factory's container i
    /// must be STOP-prefixed and hold exactly the pinned creation code i.
    function _child(bytes32 factory, uint256 i, bytes32 salt, bytes memory args) private view returns (bytes32 child) {
        bytes32 container = _word(factory, bytes4(keccak256("codeContainers(uint256)")), bytes32(i));
        bytes32 creation;
        assembly ("memory-safe") {
            let n := extcodesize(container)
            let p := mload(0x40)
            extcodecopy(container, p, 0, n)
            if and(gt(n, 1), iszero(byte(0, mload(p)))) {
                let code := add(p, 1)
                let size := sub(n, 1)
                creation := keccak256(code, size)
                mcopy(add(code, size), add(args, 32), mload(args))
                let init := keccak256(code, add(size, mload(args)))
                mstore(p, factory) mstore8(add(p, 11), 0xff) mstore(add(p, 32), salt) mstore(add(p, 64), init)
                child := shr(96, shl(96, keccak256(add(p, 11), 85)))
            }
        }
        require(creation == NoerraAtomicCodeHashes.expected(i), "Reviewed atomic children");
    }
    function _reviewedAtomicChildren(bytes32 factory, bytes32 vault, bytes32 hookSalt) private view {
        bytes32 m = _word(vault, bytes4(keccak256("manager()")), 0);
        bytes32 d = bytes32(uint256(uint160(address(dollar))));
        bytes32 token = _child(factory, 0, keccak256("NOERRA_ATOMIC_TOKEN"), abi.encode(factory));
        require(_canonicalManager(m) && vault == _child(factory, 1, keccak256("NOERRA_ATOMIC_VAULT"), abi.encode(d, token, m,
            _word(vault, bytes4(keccak256("quoter()")), 0), _word(vault, bytes4(keccak256("operationsTreasury()")), 0),
            authorizedFlagshipAccount, deploymentAuthority, authorizedFlagshipAllocation)), "Reviewed atomic children");
        bytes32 hook = _child(factory, 3, hookSalt, abi.encode(m, d, token, factory));
        _reviewedAtomicMarket(factory, vault, token, abi.encode(m, d, token, vault, hook));
    }
    /// @dev `head`: the market's first five constructor words (manager, dollar, token, vault, hook). Its arguments end
    /// with the feed, the maximum age and its access list, which must hash to the authorized allocation.
    function _reviewedAtomicMarket(bytes32 factory, bytes32 vault, bytes32 token, bytes memory head) private view {
        bytes32 market = _word(vault, bytes4(keccak256("market()")), 0);
        address[] memory list = IAtomicFlagshipFactory(address(uint160(uint256(factory)))).accessList();
        require(keccak256(abi.encode(list)) == authorizedFlagshipAllocation, "Reviewed atomic children");
        bytes32 feed = _word(market, bytes4(keccak256("ethUsdFeed()")), 0);
        bytes32 age = _word(market, bytes4(keccak256("oracleMaximumAge()")), 0);
        bytes memory args = abi.encodePacked(head, feed, age, uint256(0x100), list.length, list);
        require(market == _child(factory, 2, keccak256("NOERRA_ATOMIC_MARKET"), args)
            && market == _word(token, bytes4(keccak256("launchMarket()")), 0), "Reviewed atomic children");
    }
    /// @dev The enrolled launch factory's canonical CREATE2 brain escrow for `id` (the same one every token launch binds).
    function _canonicalEscrow(bytes32 id) private view returns (address) {
        bytes32 cash = _word(bytes32(uint256(uint160(autonomousLaunchFactory))), bytes4(keccak256("cashDeployer()")), 0);
        bytes32 escrows = _word(cash, bytes4(keccak256("escrowDeployer()")), 0);
        return address(uint160(uint256(_word(escrows, bytes4(keccak256("predictEscrow(bytes32)")), id))));
    }
    function _enrollFlagshipVault(address vault) private {
        require(autonomousFlagshipVault == address(0), "One deployment binding");
        require(vault.code.length > 0, "Flagship vault");
        IAutonomousFlagshipVault target = IAutonomousFlagshipVault(vault);
        address account = target.agentTreasury();
        require(target.dollar() == address(dollar) && target.deployer() == deploymentAuthority &&
            account.code.length > 0, "Flagship authority");
        NoerraAgentAccount source = NoerraAgentAccount(account);
        bytes32 id = source.agentId();
        require(source.registry() == address(this) && accounts[id] == account && tokens[id] == address(0)
            && creationBlocks[id] > 0, "Registered flagship");
        require(source.human() == deploymentAuthority && source.signer() == deploymentAuthority &&
            source.generation() == 1, "Original flagship authority");
        address bound = earnedDiemEscrows[id];
        require(bound == address(0) || bound == _canonicalEscrow(id), "Canonical flagship escrow");
        autonomousFlagshipVault = vault; autonomousFlagshipAccount = account; autonomousFlagshipId = id;
        emit AutonomousFlagshipEnrolled(vault, id, account);
    }

    /// @notice Explicit opt-in before launch, without changing the account or its fixed treasury.
    /// The enrolled launch factory also binds the canonical brain escrow inside every token launch,
    /// including for an already-running agent-only account that later adds its token.
    function bindEarnedDiemEscrow(bytes32 id, address escrow) external {
        address account = accounts[id];
        require(account != address(0) && (msg.sender == NoerraAgentAccount(account).human()
            || msg.sender == autonomousLaunchFactory), "One creator prelaunch reserve binding");
        _bindEarnedDiemEscrow(id, escrow, account);
    }

    function bindEarnedDiemEscrowWithPermit(bytes32 id, address escrow,
        NoerraReserveSetupPermit.Permit calldata permit) external
    {
        address account = accounts[id];
        require(account != address(0), "Registered agent");
        NoerraReserveSetupPermit.verify(NoerraAgentAccount(account).human(), address(this), id,
            abi.encodeCall(this.bindEarnedDiemEscrow, (id, escrow)), permit);
        _bindEarnedDiemEscrow(id, escrow, account);
    }

    function _bindEarnedDiemEscrow(bytes32 id, address escrow, address account) private {
        require((msg.sender == autonomousLaunchFactory || !NoerraAgentAccount(account).autonomousCoreLocked())
            && earnedDiemEscrows[id] == address(0), "One creator prelaunch reserve binding");
        require(escrow.code.length > 0 && IEarnedDiemEscrow(escrow).sourceAccount() == account
            && IEarnedDiemEscrow(escrow).dollar() == address(dollar) && IEarnedDiemEscrow(escrow).agentId() == id
            && IEarnedDiemEscrow(escrow).recoveryAuthority() == deploymentAuthority, "Exact earned reserve");
        // M-2: the flagship (enrolled or authorized) takes only the canonical escrow; creators keep their own choice.
        if (account == autonomousFlagshipAccount || account == authorizedFlagshipAccount)
            require(escrow == _canonicalEscrow(id), "Canonical flagship escrow");
        earnedDiemEscrows[id] = escrow;
        emit EarnedDiemEscrowBound(id,escrow);
    }

    /// @notice Exact enrolled source addresses; matching getters alone are insufficient.
    function isEarnedFeeSource(address source, bytes32 id, address account) external view returns (bool) {
        if (source == address(0) || accounts[id] != account) return false;
        if (source == autonomousFlagshipVault) return account == autonomousFlagshipAccount && id == autonomousFlagshipId;
        address factory = autonomousLaunchFactory;
        if (factory == address(0) || account == autonomousFlagshipAccount) return false;
        try IEarnedFeeFactory(factory).cashLaunches(id) returns (address market) { return market == source; }
        catch { return false; }
    }

    function canLockAutonomousCore(address caller, bytes32 id, address account) external view returns (bool) {
        if (accounts[id] != account || tokens[id] != address(0) || creationBlocks[id] == 0) return false;
        return caller != address(0) && ((caller == autonomousLaunchFactory && account != autonomousFlagshipAccount)
            || (caller == autonomousFlagshipVault && account == autonomousFlagshipAccount && id == autonomousFlagshipId));
    }

    /// @notice The platform deployer may replace a launched agent's steward immediately.
    /// This grants no spending, withdrawal, runtime rotation or shutdown authority.
    function replaceAgentSteward(bytes32 id, address next, bytes32 reasonHash) external {
        _onlyAuthority();
        address account = accounts[id]; require(account != address(0), "Registered agent");
        uint256 revision = NoerraAgentAccount(account).setStewardForPlatform(next, reasonHash);
        emit PlatformStewardshipReplaced(id, account, next, revision, reasonHash);
    }

    function create(address signer, bytes32 metadataHash, bytes32 buildHash, uint256 reserve, uint256 dailyLimit,
        string calldata name, string calldata symbol) external returns (bytes32 id, address account) {
        (id, account) = _createAccount(signer, metadataHash, buildHash, reserve, dailyLimit, false);
        accounts[id] = account;
        if (bytes(name).length != 0) tokens[id] = creationTokenDeployer.deploy(name, symbol, account);
        else require(bytes(symbol).length == 0, "Token configuration");
        emit Created(id, msg.sender, account, tokens[id], metadataHash);
    }

    /// @notice Owner-scoped tokenless accounts can be committed as treasury recipients before creation.
    /// Other owners cannot consume their CREATE2 address by creating unrelated accounts.
    function predictAccount(address human, uint256 ownerNonce, address signer, bytes32 metadataHash,
        bytes32 buildHash, uint256 reserve, uint256 dailyLimit) public view returns (bytes32 id, address account) {
        require(human != address(0) && metadataHash != bytes32(0), "Account identity");
        id = keccak256(abi.encode(block.chainid, address(this), human, ownerNonce));
        account = accountDeployer.predict(id, human, signer, buildHash, reserve, dailyLimit, metadataHash);
    }

    function _createAccount(address signer, bytes32 metadataHash, bytes32 buildHash, uint256 reserve,
        uint256 dailyLimit, bool deterministic) private returns (bytes32 id, address account) {
        require(creationAllowed(msg.sender), "Creation not open");
        require(metadataHash != bytes32(0), "Metadata");
        id = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonces[msg.sender]++));
        account = accountDeployer.deploy(id, msg.sender, signer, buildHash, reserve, dailyLimit, metadataHash, deterministic);
        accounts[id] = account;
    }

    function createAccount(address signer, bytes32 metadataHash, bytes32 buildHash, uint256 reserve,
        uint256 dailyLimit) external returns (bytes32 id, address account) {
        (id, account) = _createAccount(signer, metadataHash, buildHash, reserve, dailyLimit, true);
        creationBlocks[id] = block.number;
        emit Created(id, msg.sender, account, address(0), metadataHash);
    }
}

/// @notice One credit = one six-decimal dollar held until activation. No unbacked fee minting.
///         Activation funds a registered agent, not a personal withdrawal address.
contract NoerraAgentCredits is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable dollar;
    IAgentRegistry public immutable registry;
    address public immutable settlement;
    event Activated(address indexed payer, bytes32 indexed agentId, uint256 amount);

    constructor(IERC20 dollar_, IAgentRegistry registry_, address settlement_) ERC20("Noerra Compute Credit", "NCC") {
        require(address(dollar_) != address(0) && address(registry_) != address(0), "Configuration");
        dollar = dollar_; registry = registry_; settlement = settlement_;
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(uint256 amount, address recipient) external nonReentrant {
        require(amount > 0 && recipient != address(0), "Amount");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        require(dollar.balanceOf(address(this)) == beforeBalance + amount, "Exact backing required");
        _mint(recipient, amount);
    }
    /// @notice Unspent credits remain redeemable, including returned purchase escrow.
    function redeem(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount");
        _burn(msg.sender, amount); dollar.safeTransfer(msg.sender, amount);
        require(dollar.balanceOf(address(this)) >= totalSupply(), "Backing");
    }
    function activate(bytes32 agentId, uint256 amount) external nonReentrant {
        address account = registry.accounts(agentId);
        require(account != address(0) && amount > 0, "Agent");
        _burn(msg.sender, amount); dollar.safeTransfer(account, amount);
        require(dollar.balanceOf(address(this)) >= totalSupply(), "Backing");
        emit Activated(msg.sender, agentId, amount);
    }
    /// @notice Anyone may turn an agent's own credits into its own treasury dollars.
    ///         No caller can redirect the backing or withdraw another holder's credits.
    function activateAccount(bytes32 agentId, uint256 amount) external nonReentrant {
        address account = registry.accounts(agentId);
        require(account != address(0) && amount > 0, "Agent");
        _burn(account, amount); dollar.safeTransfer(account, amount);
        require(dollar.balanceOf(address(this)) >= totalSupply(), "Backing");
        emit Activated(account, agentId, amount);
    }
    /// @notice A pinned market may settle only credits it holds in buyer escrow.
    ///         The 10% returned credit remains dollar-backed; the other 90% leaves as dollars.
    function settleUsage(address buyer, address sellerPool, address computeTreasury, uint256 amount)
        external nonReentrant returns (uint256 sellerAmount, uint256 computeAmount, uint256 cashback) {
        require(msg.sender == settlement && settlement != address(0), "Market only");
        require(buyer != address(0) && sellerPool != address(0) && computeTreasury != address(0) && amount > 0, "Recipients");
        _burn(msg.sender, amount);
        cashback = amount / 10; sellerAmount = amount * 4 / 10; computeAmount = amount - cashback - sellerAmount;
        if (cashback > 0) _mint(buyer, cashback);
        dollar.safeTransfer(sellerPool, sellerAmount); dollar.safeTransfer(computeTreasury, computeAmount);
        require(dollar.balanceOf(address(this)) >= totalSupply(), "Backing");
    }
}
