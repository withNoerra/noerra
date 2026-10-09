// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {
    NoerraAgentMirror,
    NoerraAgentMirrorRegistry,
    NoerraAgentAuthorityMessenger,
    INoerraCrossDomainMessenger
} from "../src/agents/NoerraAgentMirror.sol";

contract MessageFixture is INoerraCrossDomainMessenger {
    address public xDomainMessageSender;
    address public target;
    bytes public message;
    bool public reject;

    function setReject(bool value) external {
        reject = value;
    }

    function sendMessage(address target_, bytes calldata message_, uint32) external {
        require(!reject, "Message rejected");
        target = target_;
        message = message_;
    }

    function relay(address source, address target_, bytes calldata message_) external {
        xDomainMessageSender = source;
        (bool ok, bytes memory result) = target_.call(message_);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        xDomainMessageSender = address(0);
    }
}

contract MirrorDollar is ERC20 {
    constructor() ERC20("Dollar", "USD") {}
}

contract NoerraAgentMirrorTest is Test {
    NoerraAgentRegistry registry;
    NoerraAgentAuthorityMessenger sender;
    NoerraAgentMirrorRegistry mirrors;
    MessageFixture l1;
    MessageFixture l2;
    bytes32 id;
    address account;
    address human = address(0xA11CE);
    address signer = address(0xBEEF);

    function setUp() public {
        registry = new NoerraAgentRegistry(new MirrorDollar(), IAgentRecoveryVerifier(address(0)));
        l1 = new MessageFixture();
        l2 = new MessageFixture();
        address predictedSender = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        mirrors = new NoerraAgentMirrorRegistry(l2, predictedSender, address(registry));
        sender = new NoerraAgentAuthorityMessenger(registry, l1, address(mirrors), 1_000_000);
        assertEq(address(sender), predictedSender);
        vm.prank(human);
        (id, account) = registry.create(signer, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
    }

    function _relay() internal {
        l2.relay(address(sender), l1.target(), l1.message());
    }

    function testCanonicalDeliveryIsAsynchronousAndSourceBound() public {
        assertEq(sender.sync(id), 1);
        assertEq(mirrors.accounts(id), address(0));
        _relay();
        NoerraAgentMirror mirror = NoerraAgentMirror(mirrors.accounts(id));
        assertEq(mirror.sourceChainId(), 1);
        assertEq(mirror.sourceRegistry(), address(registry));
        assertEq(mirror.sourceAccount(), account);
        assertEq(mirror.agentId(), id);
        assertEq(mirror.signer(), signer);
        assertEq(mirror.human(), human);
        assertEq(mirror.sourceGeneration(), 1);
        assertEq(mirror.sourceSequence(), 1);
    }

    function testDirectAndWrongCrossDomainSenderRejected() public {
        sender.sync(id);
        vm.expectRevert("Canonical L1 messenger only");
        mirrors.receiveAuthority(id, account, human, signer, 1, 1);
        bytes memory payload = l1.message();
        vm.expectRevert("Canonical L1 messenger only");
        l2.relay(address(0xBAD), address(mirrors), payload);
        assertEq(mirrors.accounts(id), address(0));
    }

    function testDuplicateAndOutOfOrderDeliveryRejected() public {
        sender.sync(id);
        bytes memory first = l1.message();
        sender.sync(id);
        _relay();
        bytes memory payload = l1.message();
        vm.expectRevert("Stale source authority");
        l2.relay(address(sender), address(mirrors), payload);
        vm.expectRevert("Stale source authority");
        l2.relay(address(sender), address(mirrors), first);
        assertEq(NoerraAgentMirror(mirrors.accounts(id)).sourceSequence(), 2);
    }

    function testMirrorIdentityCannotChangeAndUpdateNotPublic() public {
        sender.sync(id);
        _relay();
        NoerraAgentMirror mirror = NoerraAgentMirror(mirrors.accounts(id));
        vm.expectRevert("Mirror registry only");
        mirror.update(human, address(0xBAD), 2, 2);
        vm.expectRevert("Source account changed");
        l2.relay(
            address(sender),
            address(mirrors),
            abi.encodeCall(mirrors.receiveAuthority, (id, address(0xBAD), human, signer, 1, 2))
        );
        vm.expectRevert("Source authority");
        l2.relay(
            address(sender),
            address(mirrors),
            abi.encodeCall(mirrors.receiveAuthority, (id, account, human, signer, 0, 2))
        );
    }

    function testHumanChangeNeedsNewMessageEvenWithoutGenerationChange() public {
        sender.sync(id);
        _relay();
        NoerraAgentAccount authority = NoerraAgentAccount(account);
        vm.prank(human);
        authority.offerHuman(address(this));
        authority.acceptHuman();
        assertEq(NoerraAgentMirror(mirrors.accounts(id)).human(), human);
        sender.sync(id);
        _relay();
        assertEq(NoerraAgentMirror(mirrors.accounts(id)).human(), address(this));
        assertEq(NoerraAgentMirror(mirrors.accounts(id)).generation(), authority.generation());
    }

    function testRejectedSendRollsBackSequenceAndUnknownAgentFails() public {
        vm.expectRevert("Registered Ethereum agent");
        sender.sync(keccak256("unknown"));
        l1.setReject(true);
        vm.expectRevert("Message rejected");
        sender.sync(id);
        assertEq(sender.sequences(id), 0);
    }

    function testRealHandoverRevokesOldSignerOnlyAfterCanonicalMirrorDelivery() public {
        sender.sync(id);
        _relay();
        NoerraAgentAccount source = NoerraAgentAccount(account);
        address next = vm.addr(123);
        bytes32 destination = keccak256("next leased runtime");
        bytes32 commitment =
            keccak256(
            abi.encode(block.chainid, account, id, source.generation(), source.buildHash(), next, destination)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, MessageHashUtils.toEthSignedMessageHash(commitment));
        vm.prank(signer);
        source.handover(1, next, destination, abi.encodePacked(r, s, v));
        NoerraAgentMirror mirror = NoerraAgentMirror(mirrors.accounts(id));
        assertEq(source.generation(), 2);
        assertEq(mirror.generation(), 1);
        assertEq(mirror.signer(), signer);
        sender.sync(id);
        _relay();
        assertEq(mirror.generation(), 2);
        assertEq(mirror.signer(), next);
        bytes memory stale = abi.encodeCall(mirrors.receiveAuthority, (id, account, human, signer, 1, 3));
        vm.expectRevert("Stale source authority");
        l2.relay(address(sender), address(mirrors), stale);
    }
}
