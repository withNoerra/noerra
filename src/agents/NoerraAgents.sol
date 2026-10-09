// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IAgentRecoveryVerifier {
    function verify(bytes calldata evidence, bytes32 commitment) external view returns (bool);
}
interface IAgentPaidRecoveryVerifier {
    function verifyPaid(bytes calldata evidence, bytes32 commitment) external view returns (bool);
}

interface IAgentRegistry {
    function accounts(bytes32 agentId) external view returns (address);
}
interface IAutonomousAgentRegistry {
    function canLockAutonomousCore(address caller, bytes32 id, address account) external view returns (bool);
}
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

/// @notice An optional creation token. Fixed supply; no tax, upgrade or hidden mint authority.
contract NoerraCreationToken is ERC20 {
    address public immutable launchFactory;
    address public launchPoolManager;
    uint256 public protectionStartBlock;
    uint256 public protectionEndBlock;
    uint256 public constant MAX_LAUNCH_HOLDING = 20_000_000 ether;
    uint256 public constant LAUNCH_PROTECTION_BLOCKS = 10;
    bool public protectionInitialized;
    mapping(address => bool) public launchExempt;

    constructor(string memory name_, string memory symbol_, address account) ERC20(name_, symbol_) {
        require(bytes(name_).length > 0 && bytes(name_).length <= 48, "Name");
        require(bytes(symbol_).length > 0 && bytes(symbol_).length <= 12, "Symbol");
        launchFactory = account;
        _mint(account, 1_000_000_000 ether);
    }

    /// @notice Canonical Ethereum launch protection. Legacy token creation is unchanged.
    /// Only the original factory can initialize once, before distributing supply.
    function initializeLaunchProtection(address poolManager, address locker, address reserve, address bridge)
        external
    {
        require(msg.sender == launchFactory && msg.sender.code.length > 0 && block.chainid == 1, "Launch factory only");
        require(!protectionInitialized && balanceOf(launchFactory) == totalSupply(), "Launch protection fixed");
        require(poolManager.code.length > 0 && locker.code.length > 0 && reserve.code.length > 0
            && bridge.code.length > 0, "Launch protection pins");
        protectionInitialized = true;
        launchPoolManager = poolManager;
        protectionStartBlock = block.number;
        protectionEndBlock = block.number + LAUNCH_PROTECTION_BLOCKS;
        launchExempt[launchFactory] = true;
        launchExempt[poolManager] = true;
        launchExempt[locker] = true;
        launchExempt[reserve] = true;
        launchExempt[bridge] = true;
    }

    function launchProtectionActive() public view returns (bool) {
        return protectionInitialized && block.number < protectionEndBlock;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (launchProtectionActive() && from != address(0) && to != address(0) && !launchExempt[to]) {
            if (from == launchPoolManager) require(value <= MAX_LAUNCH_HOLDING, "Launch max buy");
            require(balanceOf(to) + (from == to ? 0 : value) <= MAX_LAUNCH_HOLDING, "Launch max wallet");
        }
        super._update(from, to, value);
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
    uint256 public constant STALE_AFTER = 3 hours;
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
    uint256 public constant MAX_RECOVERY_WINDOW = 1 days;
    bytes32 public constant PAID_RECOVERY_DOMAIN = keccak256("NOERRA_PAID_RECOVERY_V1");
    bytes32 public constant PAID_RECOVERY_COMPLETION_DOMAIN = keccak256("NOERRA_PAID_RECOVERY_COMPLETION_V1");
    uint256 public recoveryReserve;
    uint256 public maxRecoveryReimbursement;
    uint256 public recoveryBounty;
    uint256 public recoveryPolicyNonce;
    bytes32 public constant AUTOMATIC_ACTIVATION_DOMAIN = keccak256("NOERRA_AUTOMATIC_ACTIVATION_V1");
    uint256 public constant MAX_ACTIVATION_WINDOW = 30 days;
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
    mapping(bytes32 => bool) public operations;
    event Pulse(uint256 indexed generation, uint256 at);
    event Payment(bytes32 indexed operation, address indexed recipient, uint256 amount);
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
        require(human_ != address(0) && signer_ != address(0) && address(dollar_) != address(0), "Identity");
        require(build_ != bytes32(0) && reserve_ > 0 && limit_ > 0, "Bounds");
        require(registry_ != address(0), "Registry");
        agentId = id_; registry = registry_; human = human_; signer = signer_; dollar = dollar_;
        messages = messages_; recoveryVerifier = verifier_; buildHash = build_;
        hostingReserve = reserve_; dailyLimit = limit_; lastPulse = block.timestamp;
    }

    modifier onlyHuman() { require(msg.sender == human, "Human only"); _; }
    modifier onlyRuntime(uint256 expectedGeneration) {
        require(!autonomousCoreLocked || generation > 1, "Autonomous startup");
        require(msg.sender == signer && expectedGeneration == generation, "Runtime generation"); _;
    }

    function setRecipient(address recipient, bool permitted) external onlyHuman {
        require(!autonomousCoreLocked, "Autonomous policy");
        require(recipient != address(0) && recipient != address(this), "Recipient");
        _invalidateAutomaticActivation();
        recipients[recipient] = permitted;
        if (automaticPayer && recipient == signer) {
            automaticRecipientGranted = false;
            if (!permitted) automaticPayer = false;
        }
    }

    function setDailyLimit(uint256 limit_) external onlyHuman {
        require(limit_ > 0, "Limit");
        require(!autonomousCoreLocked || limit_ >= autonomousDailyFloor, "Autonomous policy");
        _invalidateAutomaticActivation(); dailyLimit = limit_;
    }

    /// @notice Opt-in recovery terms, denominated in the account's dollar token.
    ///         The human cannot change the price of a reserved job or withdraw its escrow.
    function setRecoveryPolicy(uint256 maxReimbursement, uint256 bounty) external onlyHuman {
        require(!autonomousCoreLocked, "Autonomous policy");
        require(paidRecovery.jobId == bytes32(0), "Recovery pending");
        require(maxReimbursement + bounty <= hostingReserve, "Recovery cap");
        _invalidateAutomaticActivation();
        maxRecoveryReimbursement = maxReimbursement;
        recoveryBounty = bounty;
        emit RecoveryPolicyChanged(maxReimbursement, bounty, ++recoveryPolicyNonce);
    }

    /// @notice Anyone may donate recovery escrow; there is no refund or sweep path.
    function fundRecoveryReserve(uint256 amount) external nonReentrant {
        require(amount > 0 && recoveryReserve + amount <= hostingReserve, "Recovery cap");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        require(dollar.balanceOf(address(this)) == beforeBalance + amount, "Exact recovery funding");
        recoveryReserve += amount;
        emit RecoveryReserveFunded(msg.sender, amount, recoveryReserve);
    }

    /// @notice Earmark existing agent earnings without paying an external recipient.
    ///         This does not reset or expand runtime spending authority.
    function allocateRecoveryReserve(uint256 expectedGeneration, uint256 amount)
        external onlyRuntime(expectedGeneration) nonReentrant {
        require(amount > 0 && recoveryReserve + amount <= hostingReserve, "Recovery cap");
        require(dollar.balanceOf(address(this)) >= hostingReserve + recoveryReserve + amount, "Hosting reserve");
        recoveryReserve += amount;
        emit RecoveryReserveAllocated(generation, amount, recoveryReserve);
    }

    function offerHuman(address next) external onlyHuman {
        require(next != address(0), "Human"); proposedHuman = next;
    }

    function acceptHuman() external {
        require(msg.sender == proposedHuman, "Proposed human only");
        address previous = human;
        _invalidateAutomaticActivation(); human = msg.sender; proposedHuman = address(0);
        emit StewardChanged(previous, human, ++stewardshipRevision);
    }

    /// @notice The deployment authority can replace stewardship through the registry.
    /// Runtime authority and its irreversible financial policy are unaffected.
    function setStewardForPlatform(address next, bytes32 reasonHash) external returns (uint256 revision) {
        require(msg.sender == registry && autonomousCoreLocked, "Platform stewardship only");
        require(next != address(0) && next != address(this) && next != human && reasonHash != bytes32(0), "Steward replacement");
        address previous = human; human = next; proposedHuman = address(0);
        revision = ++stewardshipRevision; platformStewardshipRevision = revision;
        emit PlatformStewardChanged(previous, next, revision, reasonHash);
    }

    /// @notice Authorize one future measured computer without running one while fees accumulate.
    /// Configure recipients and spending policy first; subsequent changes cancel this approval.
    function approveAutomaticActivation(uint256 expectedGeneration, bytes32 intentHash,
        uint256 minimumBalance, uint256 expiresAt, uint256 maxStartupGasWei) external onlyHuman {
        require(!autonomousCoreLocked, "Autonomous policy");
        require(expectedGeneration == 1 && generation == 1 && signer == human, "Initial human authority");
        require(address(recoveryVerifier) != address(0) && intentHash != bytes32(0), "Activation configuration");
        require(minimumBalance > hostingReserve + recoveryReserve && minimumBalance <= 100_000e6,
            "Activation balance bounds");
        require(expiresAt > block.timestamp && expiresAt <= block.timestamp + MAX_ACTIVATION_WINDOW,
            "Activation expiry bounds");
        require(maxStartupGasWei > 0 && maxStartupGasWei <= 0.01 ether, "Activation gas bounds");
        _invalidateAutomaticActivation();
        automaticActivation = AutomaticActivation(intentHash, activationPolicyNonce, minimumBalance,
            expiresAt, maxStartupGasWei);
        emit AutomaticActivationApproved(intentHash, activationPolicyNonce, minimumBalance, expiresAt, maxStartupGasWei);
    }

    function cancelAutomaticActivation() external onlyHuman {
        require(!autonomousCoreLocked, "Autonomous policy"); _invalidateAutomaticActivation();
    }

    /// @notice The enrolled launch factory makes funded startup and its core money policy irreversible.
    /// Stewardship can change without revoking the initially approved measured startup.
    function lockAutonomousCore() external {
        require(IAutonomousAgentRegistry(registry).canLockAutonomousCore(msg.sender, agentId, address(this)), "Autonomous factory");
        require(!autonomousCoreLocked && generation == 1 && signer == human, "Initial human authority");
        AutomaticActivation storage approval = automaticActivation;
        require(approval.intentHash != bytes32(0) && approval.policyNonce == activationPolicyNonce &&
            approval.expiresAt >= block.timestamp && maxRecoveryReimbursement > 0, "Autonomous approval");
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

    /// @notice The measured starter and its own signer both bind this exact approval and destination.
    function automaticActivationCommitment(uint256 expectedGeneration, address nextSigner, bytes32 destination)
        public view returns (bytes32) {
        AutomaticActivation memory approval = automaticActivation;
        require(expectedGeneration == 1 && generation == 1 && signer ==
            (autonomousCoreLocked ? startupHuman : human), "Initial human authority");
        require(approval.intentHash != bytes32(0) && approval.policyNonce == activationPolicyNonce,
            "Activation approval");
        require(autonomousCoreLocked || block.timestamp <= approval.expiresAt, "Activation expired");
        require(nextSigner != address(0) && nextSigner != signer && nextSigner.code.length == 0
            && destination != bytes32(0), "Activation destination");
        return keccak256(abi.encode(AUTOMATIC_ACTIVATION_DOMAIN, block.chainid, address(this), agentId,
            generation, buildHash, approval.intentHash, approval.policyNonce, approval.minimumBalance,
            approval.expiresAt, approval.maxStartupGasWei, nextSigner, destination));
    }

    /// @notice Anyone may deliver fresh attestation after sufficient funds arrive. Only the
    /// attested signer becomes a funding recipient; daily limits and operation history survive.
    function activateApproved(uint256 expectedGeneration, address nextSigner, bytes32 destination,
        bytes calldata acceptance, bytes calldata evidence) external payable nonReentrant {
        bytes32 commitment = automaticActivationCommitment(expectedGeneration, nextSigner, destination);
        AutomaticActivation memory approval = automaticActivation;
        uint256 balance = dollar.balanceOf(address(this));
        require(balance >= approval.minimumBalance && (autonomousCoreLocked ?
            balance > hostingReserve + recoveryReserve : approval.minimumBalance > hostingReserve + recoveryReserve),
            "Activation funding");
        require(msg.value <= approval.maxStartupGasWei, "Activation signer gas");
        require(ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(commitment), acceptance) == nextSigner,
            "Activation acceptance");
        require(recoveryVerifier.verify(evidence, commitment), "Activation evidence");
        delete automaticActivation;
        ++activationPolicyNonce;
        address old = signer;
        automaticPayer = true;
        _rotateSigner(nextSigner); generation++; lastPulse = block.timestamp;
        emit Rotation(old, nextSigner, generation); emit Handover(destination, generation);
        emit AutomaticallyActivated(approval.intentHash, nextSigner, destination, generation, msg.value);
        if (msg.value != 0) {
            (bool sent,) = nextSigner.call{value: msg.value}(""); require(sent, "Activation gas delivery");
        }
    }

    function pulse(uint256 expectedGeneration) external onlyRuntime(expectedGeneration) {
        lastPulse = block.timestamp; emit Pulse(generation, block.timestamp);
    }

    /// @dev Preserve explicit human permissions; move only the automatically granted recipient.
    function _rotateSigner(address nextSigner) private {
        if (automaticPayer) {
            if (automaticRecipientGranted) recipients[signer] = false;
            automaticRecipientGranted = !recipients[nextSigner];
            recipients[nextSigner] = true;
        }
        signer = nextSigner;
    }

    function checkpoint(uint256 expectedGeneration, bytes32 hash) external onlyRuntime(expectedGeneration) {
        require(hash != bytes32(0), "Checkpoint"); checkpointHash = hash; emit Checkpoint(hash, generation);
    }

    /// @notice Commit an accepted encrypted backup and refresh liveness in one transaction.
    function pulseCheckpoint(uint256 expectedGeneration, bytes32 hash) external onlyRuntime(expectedGeneration) {
        require(hash != bytes32(0), "Checkpoint");
        checkpointHash = hash; lastPulse = block.timestamp;
        emit Checkpoint(hash, generation); emit Pulse(generation, block.timestamp);
    }

    function pay(uint256 expectedGeneration, bytes32 operation, address recipient, uint256 amount)
        external onlyRuntime(expectedGeneration) nonReentrant {
        require(operation != bytes32(0) && !operations[operation], "Operation used");
        require(recipients[recipient] && amount > 0, "Payment policy");
        uint256 today = block.timestamp / 1 days;
        if (today != spentDay) { spentDay = today; spentToday = 0; }
        require(spentToday + amount <= dailyLimit, "Daily limit");
        require(dollar.balanceOf(address(this)) >= hostingReserve + recoveryReserve + amount, "Hosting reserve");
        operations[operation] = true; spentToday += amount;
        dollar.safeTransfer(recipient, amount); emit Payment(operation, recipient, amount);
    }

    function post(uint256 expectedGeneration, bytes32 channel, bytes calldata body)
        external onlyRuntime(expectedGeneration) { messages.send(agentId, channel, body); }

    /// @notice Listings consume no treasury money. The human must approve this exact market.
    function listCompute(uint256 expectedGeneration, IAgentComputeListing market, uint256 epoch,
        uint256 units, bytes calldata capacityEvidence) external onlyRuntime(expectedGeneration) nonReentrant {
        require(recipients[address(market)] && address(market.registry()) == registry, "Market policy");
        market.list(epoch, agentId, units, capacityEvidence);
    }

    /// @notice The human can list its own confirmed allowance without sharing the runtime key.
    function listComputeOwned(IAgentComputeListing market, uint256 epoch, uint256 units,
        bytes calldata capacityEvidence) external onlyHuman nonReentrant {
        require(recipients[address(market)] && address(market.registry()) == registry, "Market policy");
        market.list(epoch, agentId, units, capacityEvidence);
    }

    /// @notice Retire this runtime after the leased computer proves possession of its fresh signer.
    ///         Daily spending and operation history survive the change of authority.
    function handover(uint256 expectedGeneration, address nextSigner, bytes32 destination,
        bytes calldata acceptance) external payable onlyRuntime(expectedGeneration) nonReentrant {
        require(nextSigner != address(0) && nextSigner != signer && destination != bytes32(0), "Destination");
        require(msg.value <= 0.01 ether, "Signer gas");
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(this), agentId, generation,
            buildHash, nextSigner, destination));
        require(ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(commitment), acceptance) == nextSigner,
            "Computer acceptance");
        address old = signer; _rotateSigner(nextSigner); generation++; lastPulse = block.timestamp;
        if (paidRecovery.jobId != bytes32(0) && paidRecovery.starter == old &&
            paidRecovery.generation + 1 == generation) {
            paidRecovery.handoverDestination = destination;
        }
        emit Rotation(old, nextSigner, generation); emit Handover(destination, generation);
        if (msg.value != 0) {
            (bool paid,) = nextSigner.call{value: msg.value}(""); require(paid, "Signer gas transfer");
        }
    }

    /// @dev A deployment must supply an actual attestation verifier, not a boolean operator service.
    ///      Rotation binds chain, account, old generation, checkpoint, build and candidate signer.
    function recover(address nextSigner, bytes calldata evidence) external nonReentrant {
        require(!autonomousCoreLocked || generation > 1, "Autonomous startup");
        require(address(recoveryVerifier) != address(0), "Recovery disabled");
        require(block.timestamp > lastPulse + STALE_AFTER, "Runtime alive");
        require(nextSigner != address(0) && nextSigner != signer && checkpointHash != bytes32(0), "Candidate");
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(this), agentId, generation,
            checkpointHash, buildHash, nextSigner));
        require(recoveryVerifier.verify(evidence, commitment), "Recovery evidence");
        address old = signer; _rotateSigner(nextSigner); generation++; lastPulse = block.timestamp;
        emit Rotation(old, nextSigner, generation);
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
        require(!autonomousCoreLocked || generation > 1, "Autonomous startup");
        require(address(recoveryVerifier) != address(0), "Recovery disabled");
        require(block.timestamp > lastPulse + STALE_AFTER, "Runtime alive");
        require(request.expectedGeneration == generation, "Recovery generation");
        require(request.nextSigner != address(0) && request.nextSigner != signer && checkpointHash != bytes32(0), "Candidate");
        require(paidRecovery.jobId == bytes32(0), "Recovery pending");
        require(request.jobId != bytes32(0) && !recoveryJobsUsed[request.jobId], "Recovery job used");
        require(request.operator != address(0) && request.operator != address(this) &&
            request.leaseCommitment != bytes32(0), "Recovery operator");
        require(request.deadline > block.timestamp && request.deadline <= block.timestamp + MAX_RECOVERY_WINDOW,
            "Recovery deadline");
        uint256 total = request.reimbursement + request.bounty;
        require(total > 0 && request.reimbursement <= maxRecoveryReimbursement &&
            request.bounty == recoveryBounty, "Recovery policy");
        require(total <= recoveryReserve && dollar.balanceOf(address(this)) >= hostingReserve + recoveryReserve,
            "Recovery funding");
        bytes32 commitment = paidRecoveryCommitment(request);
        require(IAgentPaidRecoveryVerifier(address(recoveryVerifier)).verifyPaid(evidence, commitment), "Recovery evidence");
        recoveryJobsUsed[request.jobId] = true;
        address old = signer;
        _rotateSigner(request.nextSigner);
        generation++;
        lastPulse = block.timestamp;
        paidRecovery = PaidRecoveryReservation(request.jobId, commitment, request.operator, request.nextSigner,
            generation, request.reimbursement, request.bounty, request.deadline, request.leaseCommitment, bytes32(0));
        emit Rotation(old, signer, generation);
        emit RecoveryReserved(request.jobId, commitment, request.operator, request.reimbursement,
            request.bounty, generation, signer, request.leaseCommitment, request.deadline);
    }

    /// @notice The second measured quote binds the receiver after the exact reserved handover.
    ///         The measured application must also verify the live lease, capsule and announcement.
    function paidRecoveryCompletionCommitment(bytes32 jobId, bytes32 actualLease) public view returns (bytes32) {
        PaidRecoveryReservation memory pending = paidRecovery;
        require(jobId != bytes32(0) && pending.jobId == jobId && actualLease != bytes32(0), "Recovery job");
        require(generation == pending.generation + 1 && pending.handoverDestination != bytes32(0), "Recovery handover");
        return keccak256(abi.encode(PAID_RECOVERY_COMPLETION_DOMAIN, block.chainid, address(this), agentId,
            pending.reservationHash, generation, checkpointHash, buildHash, signer, actualLease, pending.handoverDestination));
    }

    /// @notice Anyone may deliver the fresh completion evidence; its bound operator receives
    ///         the fixed reward only after both verified recovery and receiver handover.
    function completePaidRecovery(bytes32 jobId, bytes32 actualLease, bytes calldata evidence) external nonReentrant {
        bytes32 commitment = paidRecoveryCompletionCommitment(jobId, actualLease);
        PaidRecoveryReservation memory pending = paidRecovery;
        require(block.timestamp <= pending.deadline, "Recovery expired");
        require(IAgentPaidRecoveryVerifier(address(recoveryVerifier)).verifyPaid(evidence, commitment), "Recovery evidence");
        uint256 total = pending.reimbursement + pending.bounty;
        require(total <= recoveryReserve && dollar.balanceOf(address(this)) >= hostingReserve + recoveryReserve,
            "Recovery funding");
        recoveryReserve -= total;
        delete paidRecovery;
        dollar.safeTransfer(pending.operator, total);
        emit RecoveryCompleted(jobId, pending.reservationHash, pending.operator, signer, generation,
            actualLease, pending.handoverDestination, pending.reimbursement, pending.bounty);
    }

    /// @notice Expiry frees only the reservation, never the protected escrow. A used job
    ///         cannot be reassigned or resurrected with a late completion transaction.
    function cancelPaidRecovery() external {
        PaidRecoveryReservation memory pending = paidRecovery;
        require(pending.jobId != bytes32(0) && block.timestamp > pending.deadline, "Recovery not expired");
        delete paidRecovery;
        emit RecoveryCancelled(pending.jobId, pending.reservationHash);
    }
}

/// @dev Isolates legacy optional-token bytecode while keeping its registry authority fixed.
contract NoerraRegistryTokenDeployer {
    address public immutable registry;
    constructor() { registry = msg.sender; }
    function deploy(string calldata name, string calldata symbol, address account)
        external returns (address) {
        require(msg.sender == registry, "Registry only");
        return address(new NoerraCreationToken(name, symbol, account));
    }
}

/// @dev Account creation is isolated without delegatecall or shared mutable authority.
contract NoerraRegistryAccountDeployer {
    address public immutable registry;
    IERC20 public immutable dollar;
    NoerraAgentMessages public immutable messages;
    IAgentRecoveryVerifier public immutable recoveryVerifier;
    constructor(IERC20 dollar_, NoerraAgentMessages messages_, IAgentRecoveryVerifier verifier_) {
        registry = msg.sender; dollar = dollar_; messages = messages_; recoveryVerifier = verifier_;
    }
    function deploy(bytes32 id, address human, address signer, bytes32 build,
        uint256 reserve, uint256 limit, bytes32 metadata, bool deterministic) external returns (address) {
        require(msg.sender == registry, "Registry only");
        if (deterministic) return address(new NoerraAgentAccount{salt:keccak256(abi.encode(id, metadata))}(
            registry, id, human, signer, dollar, messages, recoveryVerifier, build, reserve, limit));
        return address(new NoerraAgentAccount(registry, id, human, signer, dollar, messages,
            recoveryVerifier, build, reserve, limit));
    }
    function predict(bytes32 id, address human, address signer, bytes32 build,
        uint256 reserve, uint256 limit, bytes32 metadata) external view returns (address) {
        bytes32 initcode = keccak256(abi.encodePacked(type(NoerraAgentAccount).creationCode,
            abi.encode(registry, id, human, signer, dollar, messages, recoveryVerifier, build, reserve, limit)));
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
    address public autonomousLaunchFactory;
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

    constructor(IERC20 dollar_, IAgentRecoveryVerifier verifier_) {
        require(address(dollar_) != address(0), "Dollar"); dollar = dollar_; recoveryVerifier = verifier_;
        messages = new NoerraAgentMessages(address(this));
        creationTokenDeployer = new NoerraRegistryTokenDeployer();
        accountDeployer = new NoerraRegistryAccountDeployer(dollar_, messages, verifier_);
        deploymentAuthority = msg.sender;
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
        require(target.owner() == deploymentAuthority && target.registry() == address(this) && target.authorizationNonce() == nonce
            && target.agentAccount().code.length > 0 && target.vaultAddress().code.length == 0, "Atomic binding");
        NoerraAgentAccount source = NoerraAgentAccount(target.agentAccount());
        require(accounts[source.agentId()] == address(source) && tokens[source.agentId()] == address(0)
            && source.human() == deploymentAuthority && source.signer() == deploymentAuthority
            && source.generation() == 1, "Original atomic flagship");
        authorizedFlagshipFactory = factory; authorizedFlagshipVault = target.vaultAddress();
        authorizedFlagshipAccount = address(source); authorizedFlagshipId = source.agentId();
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
    function enrollAtomicFlagshipVault(address vault, uint256 nonce) external {
        require(msg.sender == authorizedFlagshipFactory && msg.sender != address(0)
            && nonce == flagshipAuthorizationNonce && msg.sender.codehash == authorizedFlagshipFactoryCodeHash
            && vault == authorizedFlagshipVault && vault == IAtomicFlagshipFactory(msg.sender).vaultAddress()
            && IAtomicFlagshipFactory(msg.sender).allocationHash() == authorizedFlagshipAllocation, "Exact atomic authorization");
        require(IAutonomousFlagshipVault(vault).agentTreasury() == authorizedFlagshipAccount
            && IAtomicFlagshipFactory(msg.sender).agentAccount() == authorizedFlagshipAccount
            && NoerraAgentAccount(authorizedFlagshipAccount).agentId() == authorizedFlagshipId, "Atomic account");
        _clearAtomicAuthorization(); ++flagshipAuthorizationNonce;
        _enrollFlagshipVault(vault);
    }
    function enrollAutonomousFlagshipVault(address vault) external {
        require(msg.sender == deploymentAuthority && authorizedFlagshipFactory == address(0), "One deployment binding");
        _enrollFlagshipVault(vault);
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
        autonomousFlagshipVault = vault; autonomousFlagshipAccount = account; autonomousFlagshipId = id;
        emit AutonomousFlagshipEnrolled(vault, id, account);
    }

    function canLockAutonomousCore(address caller, bytes32 id, address account) external view returns (bool) {
        if (accounts[id] != account || tokens[id] != address(0) || creationBlocks[id] == 0) return false;
        return caller != address(0) && ((caller == autonomousLaunchFactory && account != autonomousFlagshipAccount)
            || (caller == autonomousFlagshipVault && account == autonomousFlagshipAccount && id == autonomousFlagshipId));
    }

    /// @notice The platform deployer may replace a launched agent's steward immediately.
    /// This grants no spending, withdrawal, runtime rotation or shutdown authority.
    function replaceAgentSteward(bytes32 id, address next, bytes32 reasonHash) external {
        require(msg.sender == deploymentAuthority, "Deployment authority only");
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
