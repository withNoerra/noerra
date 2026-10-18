// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {NoerraAgentRegistry, NoerraAgentAccount} from "./NoerraAgents.sol";

interface INoerraCrossDomainMessenger {
    function xDomainMessageSender() external view returns (address);
    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external;
}

/// @dev Reads `frozen()` from an agent account through a staticcall. An account deployed before the emergency freeze (no
/// getter) or a malformed answer counts as not frozen, so older accounts keep working unchanged.
library NoerraFrozenRead {
    function frozen(address account) internal view returns (bool) {
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("frozen()"));
        return ok && data.length >= 32 && abi.decode(data, (uint256)) == 1;
    }

    /// @dev Reads `reported()` (C-4: the current signer is platform-reported, also after its freeze lapsed). An account
    /// without the getter, or a malformed answer, counts as not reported.
    function reported(address account) internal view returns (bool) {
        (bool ok, bytes memory data) = account.staticcall(abi.encodeWithSignature("reported()"));
        return ok && data.length >= 32 && abi.decode(data, (uint256)) == 1;
    }
}

/// @notice Base-side provider identity, authenticated by Ethereum through the canonical messenger.
/// @dev This is not a treasury, bridge receipt or second autonomous account. It cannot spend funds.
/// A runtime must compare it with finalized Ethereum authority and stop while this mirror is stale.
contract NoerraAgentMirror {
    uint256 public constant sourceChainId = 1;
    address public immutable registry;
    address public immutable sourceRegistry;
    address public immutable sourceAccount;
    bytes32 public immutable agentId;
    address public human;
    address public signer;
    /// @notice True while the Ethereum account's current signer is frozen (reported compromised). Base contracts that
    /// trust `signer` (brain fund keeper buys, ERC-1271 sign-in) refuse it while this is set.
    /// @dev Both flags share the signer's storage slot, so a sync writes no extra slot (C-4).
    bool public frozen;
    /// @notice True while the Ethereum account's current signer is platform-reported compromised, also after the freeze
    /// lapsed (until a rotation or the platform's unfreeze). Base contracts refuse a reported signer like a frozen one.
    bool public reported;
    uint256 public sourceGeneration;
    uint256 public sourceSequence;

    constructor(address registry_, address sourceRegistry_, address account_, bytes32 id_) {
        require(
            registry_ != address(0) && sourceRegistry_ != address(0) && account_ != address(0) && id_ != bytes32(0),
            "Source identity"
        );
        registry = registry_;
        sourceRegistry = sourceRegistry_;
        sourceAccount = account_;
        agentId = id_;
    }

    function generation() external view returns (uint256) {
        return sourceGeneration;
    }

    /// @dev Only the mirror registry (same deployment) calls this; one entry point keeps the Base creation gas low (C-4).
    function update(address human_, address signer_, uint256 generation_, uint256 sequence_, bool frozen_, bool reported_)
        external
    {
        require(msg.sender == registry, "Mirror registry only");
        require(human_ != address(0) && signer_ != address(0) && generation_ > 0, "Source authority");
        require(sequence_ > sourceSequence && generation_ >= sourceGeneration, "Stale source authority");
        human = human_;
        signer = signer_;
        sourceGeneration = generation_;
        sourceSequence = sequence_;
        frozen = frozen_;
        reported = reported_;
    }
}

/// @notice Base-only provider registry; accepts authority solely from its pinned L1 sender.
/// @dev Trust is the configured canonical Base bridge/messengers and Ethereum source account.
/// No owner, arbitrary attestor, signer override or mint authority exists.
contract NoerraAgentMirrorRegistry {
    uint256 public constant sourceChainId = 1;
    INoerraCrossDomainMessenger public immutable messenger;
    address public immutable sourceMessenger;
    address public immutable sourceRegistry;
    mapping(bytes32 => address) public accounts;
    // A mirror does not register a second creation token; the brain market uses a bridged L1 token.
    mapping(bytes32 => address) public tokens;
    event AuthorityMirrored(
        bytes32 indexed agentId, address indexed sourceAccount, address mirror, uint256 generation, uint256 sequence
    );

    constructor(INoerraCrossDomainMessenger messenger_, address sourceMessenger_, address sourceRegistry_) {
        require(
            address(messenger_).code.length > 0 && sourceMessenger_ != address(0) && sourceRegistry_ != address(0),
            "Canonical source"
        );
        messenger = messenger_;
        sourceMessenger = sourceMessenger_;
        sourceRegistry = sourceRegistry_;
    }

    /// @notice Version 1 message (no report state): kept so a V1 sender stays deliverable; it mirrors `reported` as false.
    function receiveAuthority(
        bytes32 id,
        address account,
        address human,
        address signer,
        uint256 generation,
        uint256 sequence,
        bool frozen
    ) external {
        _receive(id, account, human, signer, generation, sequence, frozen, false);
    }

    /// @notice Version 2 message (C-4): also carries the account's `reported()` state.
    function receiveAuthorityV2(
        bytes32 id,
        address account,
        address human,
        address signer,
        uint256 generation,
        uint256 sequence,
        bool frozen,
        bool reported
    ) external {
        _receive(id, account, human, signer, generation, sequence, frozen, reported);
    }

    function _receive(
        bytes32 id,
        address account,
        address human,
        address signer,
        uint256 generation,
        uint256 sequence,
        bool frozen,
        bool reported
    ) private {
        require(
            msg.sender == address(messenger) && messenger.xDomainMessageSender() == sourceMessenger,
            "Canonical L1 messenger only"
        );
        require(id != bytes32(0) && account != address(0), "Source identity");
        address mirror = accounts[id];
        if (mirror == address(0)) {
            mirror = address(new NoerraAgentMirror(address(this), sourceRegistry, account, id));
            accounts[id] = mirror;
        }
        require(NoerraAgentMirror(mirror).sourceAccount() == account, "Source account changed");
        NoerraAgentMirror(mirror).update(human, signer, generation, sequence, frozen, reported);
        emit AuthorityMirrored(id, account, mirror, generation, sequence);
    }
}

/// @notice Ethereum-only authority sender. Anyone may relay the registry's actual current state.
/// @dev Base delivery is asynchronous. sendMessage is not proof that the mirror has updated.
/// Gas: the L1 messenger burns Ethereum gas in proportion to the L2 gas limit it
/// buys, so every sync used to cost ~2.5M gas. An agent's FIRST message creates its NoerraAgentMirror on Base (measured
/// 414,622 L2 gas) and is sent with `minGasLimit`; every later message only updates that mirror (measured 29,967 L2 gas)
/// and is sent with UPDATE_GAS_LIMIT (4x headroom). A delivery that still ran out of gas on Base is recorded as a failed
/// message by the L2 messenger and anyone may replay it there with more gas; ordering stays enforced by the sequence.
/// Freeze changes driven only by time (an owner or platform freeze lapsing at frozenAt + 72 h, a platform report re-arming
/// at frozenAt + 30 days) emit nothing on Ethereum: the platform relayer syncs at those times. Since C-4 every message is the
/// version 2 receiveAuthorityV2 (eight words: ... frozen, reported); the platform report is set by Frozen and ends with
/// Unfrozen / Rotation, so the same event-driven syncs carry it.
contract NoerraAgentAuthorityMessenger {
    uint256 public constant sourceChainId = 1;
    uint256 public constant destinationChainId = 8453;
    uint32 public constant UPDATE_GAS_LIMIT = 200_000;
    NoerraAgentRegistry public immutable registry;
    INoerraCrossDomainMessenger public immutable messenger;
    address public immutable destinationRegistry;
    uint32 public immutable minGasLimit;
    mapping(bytes32 => uint256) public sequences;
    event AuthoritySent(bytes32 indexed agentId, address indexed account, uint256 generation, uint256 sequence);

    constructor(
        NoerraAgentRegistry registry_,
        INoerraCrossDomainMessenger messenger_,
        address destinationRegistry_,
        uint32 gasLimit_
    ) {
        require(
            address(registry_).code.length > 0 && address(messenger_).code.length > 0
                && destinationRegistry_ != address(0),
            "Canonical destination"
        );
        require(gasLimit_ >= 100_000 && gasLimit_ <= 5_000_000, "Message gas bounds");
        registry = registry_;
        messenger = messenger_;
        destinationRegistry = destinationRegistry_;
        minGasLimit = gasLimit_;
    }

    /// @notice The L2 gas limit the next sync of `id` buys: the full limit for the message that creates the mirror.
    function gasLimitFor(bytes32 id) public view returns (uint32) {
        return sequences[id] == 0 || minGasLimit < UPDATE_GAS_LIMIT ? minGasLimit : UPDATE_GAS_LIMIT;
    }

    function sync(bytes32 id) external returns (uint256 sequence) {
        return _sync(id, gasLimitFor(id));
    }

    /// @notice Same message with a caller-chosen L2 gas limit in [gasLimitFor(id), minGasLimit]: if the
    /// mirror-creating first delivery failed on Base, every later 200k update fails too until that message is replayed; a
    /// relayer may instead buy the creation gas again here so the next delivery creates the mirror itself. Paying more L1
    /// gas is the only effect; the first message of an agent always buys the full creation limit.
    function sync(bytes32 id, uint256 gasLimit) external returns (uint256 sequence) {
        require(gasLimit >= gasLimitFor(id) && gasLimit <= minGasLimit, "Message gas bounds");
        return _sync(id, uint32(gasLimit));
    }

    function _sync(bytes32 id, uint32 gasLimit) private returns (uint256 sequence) {
        address account = registry.accounts(id);
        require(account != address(0), "Registered Ethereum agent");
        NoerraAgentAccount authority = NoerraAgentAccount(account);
        sequence = ++sequences[id];
        messenger.sendMessage(
            destinationRegistry,
            abi.encodeCall(
                NoerraAgentMirrorRegistry.receiveAuthorityV2,
                (
                    id, account, authority.human(), authority.signer(), authority.generation(), sequence,
                    NoerraFrozenRead.frozen(account), NoerraFrozenRead.reported(account)
                )
            ),
            gasLimit
        );
        emit AuthoritySent(id, account, authority.generation(), sequence);
    }
}
