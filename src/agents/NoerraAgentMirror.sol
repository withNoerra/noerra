// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NoerraAgentRegistry, NoerraAgentAccount} from "./NoerraAgents.sol";

interface INoerraCrossDomainMessenger {
    function xDomainMessageSender() external view returns (address);
    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external;
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

    function update(address human_, address signer_, uint256 generation_, uint256 sequence_) external {
        require(msg.sender == registry, "Mirror registry only");
        require(human_ != address(0) && signer_ != address(0) && generation_ > 0, "Source authority");
        require(sequence_ > sourceSequence && generation_ >= sourceGeneration, "Stale source authority");
        human = human_;
        signer = signer_;
        sourceGeneration = generation_;
        sourceSequence = sequence_;
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

    function receiveAuthority(
        bytes32 id,
        address account,
        address human,
        address signer,
        uint256 generation,
        uint256 sequence
    ) external {
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
        NoerraAgentMirror(mirror).update(human, signer, generation, sequence);
        emit AuthorityMirrored(id, account, mirror, generation, sequence);
    }
}

/// @notice Ethereum-only authority sender. Anyone may relay the registry's actual current state.
/// @dev Base delivery is asynchronous. sendMessage is not proof that the mirror has updated.
contract NoerraAgentAuthorityMessenger {
    uint256 public constant sourceChainId = 1;
    uint256 public constant destinationChainId = 8453;
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

    function sync(bytes32 id) external returns (uint256 sequence) {
        address account = registry.accounts(id);
        require(account != address(0), "Registered Ethereum agent");
        NoerraAgentAccount authority = NoerraAgentAccount(account);
        sequence = ++sequences[id];
        messenger.sendMessage(
            destinationRegistry,
            abi.encodeCall(
                NoerraAgentMirrorRegistry.receiveAuthority,
                (id, account, authority.human(), authority.signer(), authority.generation(), sequence)
            ),
            minGasLimit
        );
        emit AuthoritySent(id, account, authority.generation(), sequence);
    }
}
