// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoerraFrozenRead} from "./NoerraAgentMirror.sol";
import {NoerraAgentAccount, IEarnedFeeRegistry} from "./NoerraAgents.sol";

/// @dev Circle CCTP V2 TokenMessenger interface, reviewed against circlefin/evm-cctp-contracts.
interface IEarnedDiemTokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @notice The agent's Ethereum brain fund. It receives the exact brain row of each authenticated fee
/// collection and open deposits from anyone, and only bridges to the agent's fixed Base reserve.
/// @dev The cap is the Base reserve's 10 DIEM, not a USDC amount: the
/// runtime marks the fund full when the reserve reaches it, and clears the mark when the reserve drops below it (for example
/// after a platform withdrawal), so the fund refills. While `full`, fee routing pays the brain row to the agent account (the
/// agent's own pockets) and anyone may release unbridged brain USDC to that account, so nothing strands here. Bridging is
/// bounded only per batch and per rolling 24 hours (a safety rate, sized to reach the cap within days at the reviewed DIEM
/// price); there is no lifetime bound. An attested bridge burn is not a DIEM purchase or API credit.
/// The fund also counts as full while a week of bridging (7 x the daily rate) is already
/// waiting, so it never grows without bound when DIEM cannot be bought or the runtime is offline: brain rows then go to the
/// agent account and anyone may release the backlog above that week to it (bridging continues at the daily rate). Bridge
/// fees may be proportional (up to 0.1% of the batch) so a proportional CCTP fee can never freeze bridging.
contract NoerraEarnedDiemEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentAccount public immutable sourceAccount;
    IERC20 public immutable dollar;
    bytes32 public immutable agentId;
    address public immutable recoveryAuthority;
    /// @notice Fixed CCTP mint recipient AND destination caller on Base. It may be a predicted CREATE2 address that is
    /// deployed only later: nothing is minted until the deployed reserve itself relays the attested message
    /// (NoerraEarnedDiemReserve.receiveBridge), so a burn before deployment waits as an unrelayed attestation.
    address public immutable baseReserve;
    IEarnedDiemTokenMessengerV2 public immutable messenger;
    bytes32 public immutable messengerCodeHash;
    bytes32 public immutable reviewedPlanHash;
    uint256 public immutable maximumBatchUSDC;
    /// @notice At most this much USDC bridges in any 24-hour window (the window opens with its first bridge).
    uint256 public immutable maximumDailyUSDC;
    uint256 public immutable maximumBridgeFee;
    uint256 public constant BRIDGE_WINDOW = 1 days;
    /// @notice Days of bridging (at maximumDailyUSDC) the fund holds before it counts as full.
    uint256 public constant BACKLOG_DAYS = 7;
    /// @notice A bridge may carry a fee up to this share of its amount (basis points) when above maximumBridgeFee.
    uint256 public constant PROPORTIONAL_FEE_BPS = 10;

    struct ReserveFloors {
        uint256 operatingUSDC;
        uint256 runtimeGasWei;
    }
    uint256 public immutable minimumOperatingUSDC;
    uint256 public immutable minimumRuntimeGasWei;
    bool public allocationsEnabled = true;
    /// @notice Set by the agent's current runtime signer when its Base reserve holds the 10 DIEM cap.
    bool public fullFlag;
    uint256 public totalBridged;
    /// @notice Start of the current 24-hour bridge window and the USDC bridged in it.
    uint256 public windowStart;
    uint256 public bridgedInWindow;
    /// @notice Unbridged brain funds: fee rows plus deposits.
    uint256 public availableEarnedUSDC;
    /// @notice Lifetime exact brain rows received from fee routing.
    uint256 public earnedFeeIncome;
    uint256 public totalDeposited;
    /// @dev Both values equal the exact brain row (signature kept for indexers).
    event EarnedAllocation(uint256 feeIncome, uint256 allocation);
    event Deposited(address indexed from, uint256 amount);
    event FullChanged(bool full);
    mapping(bytes32 => bool) public operations;
    event AllocationPolicy(bool enabled);
    event EarnedReserveBridged(
        bytes32 indexed operation, uint256 amount, uint256 maximumFee, address indexed baseReserve
    );
    event AllocationReturned(uint256 amount);
    event ReleasedToAccount(address indexed caller, uint256 amount);

    constructor(
        NoerraAgentAccount account_,
        address reserve_,
        IEarnedDiemTokenMessengerV2 messenger_,
        uint256 maximumBatch_,
        uint256 maximumDaily_,
        uint256 maximumFee_,
        ReserveFloors memory floors_,
        bytes32 planHash_
    ) {
        require(
            block.chainid == 1 && address(account_).code.length > 0 && address(messenger_).code.length > 0,
            "Ethereum infrastructure"
        );
        require(
            reserve_ != address(0) && reserve_ != address(account_) && planHash_ != bytes32(0), "Reviewed destination"
        );
        require(
            maximumBatch_ > 0 && maximumDaily_ >= maximumBatch_ && maximumFee_ < maximumBatch_,
            "Finite bridge bounds"
        );
        require(floors_.operatingUSDC > 0 && floors_.runtimeGasWei > 0, "Nonzero operating and gas floors");
        minimumOperatingUSDC = floors_.operatingUSDC;
        minimumRuntimeGasWei = floors_.runtimeGasWei;
        sourceAccount = account_;
        dollar = account_.dollar();
        agentId = account_.agentId();
        recoveryAuthority = IEarnedFeeRegistry(account_.registry()).deploymentAuthority();
        baseReserve = reserve_;
        messenger = messenger_;
        messengerCodeHash = address(messenger_).codehash;
        maximumBatchUSDC = maximumBatch_;
        maximumDailyUSDC = maximumDaily_;
        maximumBridgeFee = maximumFee_;
        reviewedPlanHash = planHash_;
    }

    /// @notice The exact canonical market or flagship vault sends the agent's exact brain row.
    function allocateFromEarnedFees(uint256 amount) external nonReentrant returns (uint256 allocation) {
        require(
            allocationsEnabled && !full() && amount > 0
                && IEarnedFeeRegistry(sourceAccount.registry())
                    .isEarnedFeeSource(msg.sender, agentId, address(sourceAccount)),
            "Canonical earned fees only"
        );
        allocation = amount;
        earnedFeeIncome += amount;
        availableEarnedUSDC += amount;
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        require(dollar.balanceOf(address(this)) == beforeBalance + amount, "Exact fee allocation");
        emit EarnedAllocation(amount, amount);
    }

    /// @notice Anyone may add USDC to this agent's brain fund. It can only ever bridge to `baseReserve`
    /// (or return to the agent account on recovery); there is no withdrawal to the depositor.
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit amount");
        uint256 beforeBalance = dollar.balanceOf(address(this));
        dollar.safeTransferFrom(msg.sender, address(this), amount);
        require(dollar.balanceOf(address(this)) == beforeBalance + amount, "Exact deposit");
        availableEarnedUSDC += amount;
        totalDeposited += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Only the account's current runtime signer may mark the brain fund full or not full.
    function setFull(bool value) external {
        require(msg.sender == sourceAccount.signer(), "Current runtime signer");
        require(!NoerraFrozenRead.frozen(address(sourceAccount)), "Frozen signer");
        fullFlag = value;
        emit FullChanged(value);
    }

    /// @notice Platform emergency stop. Fee routing then pays the brain row to the agent account.
    function pauseAllocations() public {
        require(msg.sender == recoveryAuthority, "Reserve recovery authority");
        allocationsEnabled = false;
        emit AllocationPolicy(false);
    }

    function resumeAllocations() external {
        require(msg.sender == recoveryAuthority && address(messenger).codehash == messengerCodeHash,
            "Reserve recovery authority");
        allocationsEnabled = true;
        emit AllocationPolicy(true);
    }

    /// @notice Full while the runtime reports the Base reserve at its 10 DIEM cap, or while a week of bridging is already
    /// waiting here (backlogThreshold): brain rows then go to the agent account. There is no USDC lifetime: below both the
    /// fund always takes and bridges brain rows again.
    function full() public view returns (bool) {
        return fullFlag || availableEarnedUSDC >= backlogThreshold();
    }

    /// @notice A week of bridging at the daily rate: unbridged brain USDC above it is agent cash.
    function backlogThreshold() public view returns (uint256) {
        return BACKLOG_DAYS * maximumDailyUSDC;
    }

    /// @notice USDC releaseToAccount moves now: everything while flagged at the cap, else the backlog above a week.
    function releasable() public view returns (uint256) {
        uint256 balance = dollar.balanceOf(address(this));
        if (fullFlag) return balance;
        uint256 keep = backlogThreshold();
        return availableEarnedUSDC >= keep && balance > keep ? balance - keep : 0;
    }

    /// @notice Largest CCTP fee a bridge of `amount` may carry: the fixed bound, or 0.1% of the amount when larger.
    function maximumFeeFor(uint256 amount) public view returns (uint256) {
        uint256 proportional = amount * PROPORTIONAL_FEE_BPS / 10_000;
        return proportional > maximumBridgeFee ? proportional : maximumBridgeFee;
    }

    /// @notice USDC that may still bridge in the current 24-hour window.
    function dailyRemaining() public view returns (uint256) {
        return block.timestamp >= windowStart + BRIDGE_WINDOW ? maximumDailyUSDC : maximumDailyUSDC - bridgedInWindow;
    }

    /// @notice While the fund is full, anyone may move its unbridged USDC (brain rows received before the cap, later
    /// deposits and stray transfers) to the agent account, the only destination besides the Base reserve. Full by backlog
    /// (not flagged), it keeps exactly a week of bridging and releases the rest.
    function releaseToAccount() external nonReentrant returns (uint256 amount) {
        require(full(), "Brain fund below its cap");
        amount = releasable();
        require(amount > 0, "Nothing to release");
        availableEarnedUSDC = fullFlag ? 0 : backlogThreshold();
        dollar.safeTransfer(address(sourceAccount), amount);
        emit ReleasedToAccount(msg.sender, amount);
    }

    /// @notice Platform recovery returns every unbridged USDC (brain funds, deposits and stray transfers) to the agent
    /// account, never elsewhere.
    function returnAllocation() external nonReentrant {
        pauseAllocations();
        uint256 amount = dollar.balanceOf(address(this));
        availableEarnedUSDC = 0;
        if (amount > 0) dollar.safeTransfer(address(sourceAccount), amount);
        emit AllocationReturned(amount);
    }

    function bridge(bytes32 operation, uint256 expectedGeneration, uint256 amount, uint256 maxFee)
        external
        nonReentrant
    {
        require(
            allocationsEnabled && msg.sender == sourceAccount.signer()
                && expectedGeneration == sourceAccount.generation(),
            "Active runtime generation"
        );
        require(!NoerraFrozenRead.frozen(address(sourceAccount)), "Frozen signer");
        require(!sourceAccount.autonomousCoreLocked() || expectedGeneration > 1, "Autonomous startup");
        require(operation != bytes32(0) && !operations[operation], "Unused bridge operation");
        require(!fullFlag, "Brain fund at its cap");
        if (block.timestamp >= windowStart + BRIDGE_WINDOW) {
            windowStart = block.timestamp;
            bridgedInWindow = 0;
        }
        require(
            amount > 0 && amount <= maximumBatchUSDC && bridgedInWindow + amount <= maximumDailyUSDC
                && maxFee <= maximumFeeFor(amount) && maxFee < amount,
            "Bridge spend bounds"
        );
        require(address(messenger).codehash == messengerCodeHash, "Bridge code changed");
        require(amount <= availableEarnedUSDC, "Earned reserve only");
        require(
            dollar.balanceOf(address(sourceAccount))
                >= sourceAccount.hostingReserve() + sourceAccount.recoveryReserve() + minimumOperatingUSDC,
            "Hosting reserve"
        );
        require(msg.sender.balance >= minimumRuntimeGasWei, "Runtime gas reserve");
        operations[operation] = true;
        totalBridged += amount;
        bridgedInWindow += amount;
        uint256 beforeBalance = dollar.balanceOf(address(this));
        availableEarnedUSDC -= amount;
        dollar.forceApprove(address(messenger), amount);
        // Ethereum domain 0 -> Base domain 6. Standard finality, fixed recipient AND caller.
        messenger.depositForBurn(
            amount,
            6,
            bytes32(uint256(uint160(baseReserve))),
            address(dollar),
            bytes32(uint256(uint160(baseReserve))),
            maxFee,
            2000
        );
        dollar.forceApprove(address(messenger), 0);
        require(dollar.balanceOf(address(this)) + amount == beforeBalance, "Exact bridge debit");
        emit EarnedReserveBridged(operation, amount, maxFee, baseReserve);
    }
}

interface INoerraEscrowLaunchFactory { function registry() external view returns (address); }
interface IAgentAccounts { function accounts(bytes32 id) external view returns (address); }

/// @dev Non-executable container for the reviewed Base reserve creation code (STOP-prefixed), so the
/// Ethereum side can predict each agent's Base reserve without embedding that code in its runtime.
contract NoerraBaseReserveCode {
    constructor(bytes memory creation) {
        require(creation.length > 0 && creation.length < 24576, "Creation code size");
        bytes memory code = abi.encodePacked(hex"00", creation);
        assembly ("memory-safe") { return(add(code, 32), mload(code)) }
    }
}

/// @notice Canonical brain escrow per agent: CREATE2 salt `agentId`, one reviewed parameter set.
/// Anyone may deploy an agent's canonical escrow (the result is fixed); its source factory binds it
/// automatically inside every token launch, and a tokenless owner may bind it voluntarily.
/// @dev Base recipient = CREATE2(baseReserveFactory, salt agentId,
/// keccak256(reserveCreationCode ++ abi.encode(agentId))), matching NoerraEarnedDiemReserveFactory on Base.
contract NoerraEarnedDiemEscrowDeployer {
    address public immutable factory;
    IEarnedDiemTokenMessengerV2 public immutable messenger;
    address public immutable baseReserveFactory;
    address public immutable baseReserveCode;
    bytes32 public immutable baseReserveCodeHash;
    uint256 public immutable maximumBatchUSDC;
    uint256 public immutable maximumDailyUSDC;
    uint256 public immutable maximumBridgeFee;
    uint256 public immutable minimumOperatingUSDC;
    uint256 public immutable minimumRuntimeGasWei;
    bytes32 public immutable reviewedPlanHash;
    event EscrowDeployed(bytes32 indexed agentId, address indexed account, address escrow, address baseReserve);

    struct Bounds {
        uint256 maximumBatchUSDC;
        uint256 maximumDailyUSDC;
        uint256 maximumBridgeFee;
    }

    constructor(
        address factory_,
        IEarnedDiemTokenMessengerV2 messenger_,
        address baseReserveFactory_,
        address baseReserveCode_,
        Bounds memory bounds_,
        NoerraEarnedDiemEscrow.ReserveFloors memory floors_,
        bytes32 planHash_
    ) {
        require(factory_ != address(0) && address(messenger_).code.length > 0 && baseReserveFactory_ != address(0)
            && baseReserveCode_.code.length > 1 && planHash_ != bytes32(0), "Escrow deployer pins");
        require(bounds_.maximumBatchUSDC > 0 && bounds_.maximumDailyUSDC >= bounds_.maximumBatchUSDC
            && bounds_.maximumBridgeFee < bounds_.maximumBatchUSDC && floors_.operatingUSDC > 0
            && floors_.runtimeGasWei > 0, "Finite bridge bounds");
        factory = factory_;
        messenger = messenger_;
        baseReserveFactory = baseReserveFactory_;
        baseReserveCode = baseReserveCode_;
        bytes memory creation = _reserveCreation(baseReserveCode_);
        baseReserveCodeHash = keccak256(creation);
        maximumBatchUSDC = bounds_.maximumBatchUSDC;
        maximumDailyUSDC = bounds_.maximumDailyUSDC;
        maximumBridgeFee = bounds_.maximumBridgeFee;
        minimumOperatingUSDC = floors_.operatingUSDC;
        minimumRuntimeGasWei = floors_.runtimeGasWei;
        reviewedPlanHash = planHash_;
    }

    function _reserveCreation(address container) private view returns (bytes memory code) {
        uint256 n = container.code.length;
        bytes memory first = new bytes(1);
        assembly ("memory-safe") { extcodecopy(container, add(first, 32), 0, 1) }
        require(n > 1 && first[0] == bytes1(0), "STOP container");
        code = new bytes(n - 1);
        assembly ("memory-safe") { extcodecopy(container, add(code, 32), 1, sub(n, 1)) }
    }

    /// @notice The agent's deterministic Base reserve (it may not exist yet).
    function predictBaseReserve(bytes32 id) public view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(_reserveCreation(baseReserveCode), abi.encode(id)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), baseReserveFactory, id, initHash)))));
    }

    function _initCode(bytes32 id, address account) private view returns (bytes memory) {
        return abi.encodePacked(type(NoerraEarnedDiemEscrow).creationCode, abi.encode(
            account, predictBaseReserve(id), messenger, maximumBatchUSDC, maximumDailyUSDC, maximumBridgeFee,
            NoerraEarnedDiemEscrow.ReserveFloors(minimumOperatingUSDC, minimumRuntimeGasWei), reviewedPlanHash));
    }

    function _account(bytes32 id) private view returns (address account) {
        account = IAgentAccounts(INoerraEscrowLaunchFactory(factory).registry()).accounts(id);
        require(account != address(0), "Registered agent");
    }

    function _predict(bytes memory code, bytes32 id) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), id, keccak256(code))))));
    }

    function predictEscrow(bytes32 id) external view returns (address) {
        return _predict(_initCode(id, _account(id)), id);
    }

    /// @notice Idempotent: returns the existing canonical escrow when already deployed.
    function deploy(bytes32 id) external returns (NoerraEarnedDiemEscrow escrow) {
        address account = _account(id);
        bytes memory code = _initCode(id, account);
        address predicted = _predict(code, id);
        if (predicted.code.length > 0) return NoerraEarnedDiemEscrow(predicted);
        address child;
        assembly ("memory-safe") { child := create2(0, add(code, 32), mload(code), id) }
        require(child == predicted && child.code.length > 0, "Canonical escrow deployment");
        escrow = NoerraEarnedDiemEscrow(child);
        emit EscrowDeployed(id, account, child, NoerraEarnedDiemEscrow(child).baseReserve());
    }
}
