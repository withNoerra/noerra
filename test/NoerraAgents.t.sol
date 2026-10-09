// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, NoerraAgentMessages, IAgentRecoveryVerifier, IAgentRegistry} from "../src/agents/NoerraAgents.sol";

contract AgentTestDollar is ERC20 {
    constructor() ERC20("Synthetic Dollar", "TEST") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
contract AgentTestVerifier is IAgentRecoveryVerifier {
    bytes32 public accepted;
    function set(bytes32 value) external { accepted = value; }
    function verify(bytes calldata evidence, bytes32 commitment) external view returns (bool) { return commitment == accepted && keccak256(evidence) == keccak256("synthetic attestation"); }
}
contract NoerraAgentsTest is Test {
    AgentTestDollar dollar; AgentTestVerifier verifier; NoerraAgentRegistry registry;
    NoerraAgentCredits credits; NoerraAgentAccount account; bytes32 agentId;
    address human = address(0xA1); address runtime = address(0xB1); address vendor = address(0xC1);
    function setUp() public {
        dollar = new AgentTestDollar(); verifier = new AgentTestVerifier(); registry = new NoerraAgentRegistry(dollar, verifier);
        credits = new NoerraAgentCredits(dollar, IAgentRegistry(address(registry)), address(0));
        vm.prank(human); (bytes32 created, address deployed) = registry.create(runtime, keccak256("metadata"), keccak256("build"), 50e6, 10e6, "Research", "RSCH");
        agentId = created; account = NoerraAgentAccount(deployed); dollar.mint(address(account), 100e6);
        vm.prank(human); account.setRecipient(vendor, true);
    }
    function testFixedSupplyAndIsolatedFunds() public view {
        ERC20 token = ERC20(registry.tokens(agentId)); assertEq(token.totalSupply(), 1_000_000_000 ether); assertEq(token.balanceOf(address(account)), token.totalSupply());
        assertEq(account.human(), human); assertEq(account.signer(), runtime); assertEq(address(account.dollar()), address(dollar));
    }
    function testComputerHandoverRevokesOldSignerPreservesSpendingAndSeedsNewGas() public {
        uint256 nextKey = 0x123456789; address next = vm.addr(nextKey); bytes32 destination = keccak256("own active lease");
        vm.prank(runtime); account.pay(1, keccak256("spent before handover"), vendor, 7e6);
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(account), agentId, uint256(1), account.buildHash(), next, destination));
        (uint8 v,bytes32 r,bytes32 s) = vm.sign(nextKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",commitment)));
        bytes memory acceptance = abi.encodePacked(r,s,v); vm.deal(runtime,1 ether);
        vm.prank(runtime); account.handover{value:0.0001 ether}(1,next,destination,acceptance);
        assertEq(account.signer(),next); assertEq(account.generation(),2); assertEq(next.balance,0.0001 ether);
        assertEq(account.spentToday(),7e6); assertTrue(account.operations(keccak256("spent before handover")));
        vm.prank(runtime); vm.expectRevert("Runtime generation"); account.pulse(1);
        vm.prank(runtime); vm.expectRevert("Runtime generation"); account.pay(2,keccak256("old signer"),vendor,1);
        vm.prank(next); vm.expectRevert("Daily limit"); account.pay(2,keccak256("over limit"),vendor,4e6);
        vm.prank(next); account.pay(2,keccak256("new signer"),vendor,3e6);
        vm.prank(next); vm.expectRevert("Computer acceptance"); account.handover(2,runtime,destination,acceptance);
    }
    function testHandoverRejectsAlteredLeaseAccountAndUnapprovedCaller() public {
        uint256 nextKey=0x789; address next=vm.addr(nextKey); bytes32 destination=keccak256("lease");
        bytes32 commitment=keccak256(abi.encode(block.chainid,address(account),agentId,uint256(1),account.buildHash(),next,destination));
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(nextKey,keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",commitment)));
        bytes memory signature=abi.encodePacked(r,s,v);
        vm.prank(human); vm.expectRevert("Runtime generation"); account.handover(1,next,destination,signature);
        vm.prank(runtime); vm.expectRevert("Computer acceptance"); account.handover(1,next,keccak256("another lease"),signature);
        vm.prank(runtime); vm.expectRevert("Destination"); account.handover(1,next,bytes32(0),signature);
        vm.deal(runtime,1 ether);vm.prank(runtime);vm.expectRevert("Signer gas"); account.handover{value:0.011 ether}(1,next,destination,signature);
    }
    function testAtomicAcceptedCheckpointRefreshesLivenessWithoutSpending() public {
        vm.warp(block.timestamp + 2 hours);
        bytes32 checkpoint = keccak256("accepted encrypted envelope");
        vm.prank(runtime); account.pulseCheckpoint(1, checkpoint);
        assertEq(account.lastPulse(), block.timestamp); assertEq(account.checkpointHash(), checkpoint);
        assertEq(dollar.balanceOf(address(account)), 100e6);
        vm.prank(runtime); vm.expectRevert("Runtime generation"); account.pulseCheckpoint(2, checkpoint);
        vm.prank(human); vm.expectRevert("Runtime generation"); account.pulseCheckpoint(1, checkpoint);
        vm.prank(runtime); vm.expectRevert("Checkpoint"); account.pulseCheckpoint(1, bytes32(0));
    }
    function testRuntimePaymentsBoundedAndReplayProtected() public {
        vm.prank(runtime); account.pay(1, keccak256("one"), vendor, 7e6);
        assertEq(dollar.balanceOf(vendor), 7e6);
        vm.prank(runtime); vm.expectRevert("Operation used"); account.pay(1, keccak256("one"), vendor, 1);
        vm.prank(runtime); vm.expectRevert("Daily limit"); account.pay(1, keccak256("two"), vendor, 4e6);
        vm.prank(runtime); vm.expectRevert("Payment policy"); account.pay(1, keccak256("three"), human, 1);
        vm.prank(human); vm.expectRevert("Runtime generation"); account.pay(1, keccak256("four"), vendor, 1);
        vm.warp(block.timestamp + 1 days); vm.prank(runtime); account.pay(1, keccak256("two"), vendor, 4e6);
    }
    function testHostingReserveCannotBeSpentByRuntime() public {
        vm.prank(human); account.setDailyLimit(100e6);
        vm.prank(runtime); vm.expectRevert("Hosting reserve"); account.pay(1, keccak256("one"), vendor, 51e6);
        vm.prank(runtime); account.pay(1, keccak256("one"), vendor, 50e6); assertEq(dollar.balanceOf(address(account)), 50e6);
    }
    function testDollarCreditsBackedAndActivateOnlyIntoAgent() public {
        dollar.mint(human, 100e6); vm.startPrank(human); dollar.approve(address(credits), 100e6); credits.mint(80e6, human);
        assertEq(credits.totalSupply(), 80e6); assertEq(dollar.balanceOf(address(credits)), 80e6);
        vm.expectRevert("Agent"); credits.activate(bytes32(uint256(33)), 20e6);
        credits.activate(agentId, 20e6); vm.stopPrank();
        assertEq(credits.totalSupply(), 60e6); assertEq(dollar.balanceOf(address(credits)), 60e6); assertEq(dollar.balanceOf(address(account)), 120e6);
    }
    function testFuzzCreditBacking(uint96 amount, uint96 activated) public {
        amount = uint96(bound(amount, 1, 1e12)); activated = uint96(bound(activated, 1, amount));
        dollar.mint(human, amount); vm.startPrank(human); dollar.approve(address(credits), amount); credits.mint(amount, human); credits.activate(agentId, activated); vm.stopPrank();
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply()); assertEq(credits.totalSupply(), uint256(amount) - activated);
    }
    function testUnspentCreditRedemptionPreservesBacking() public {
        dollar.mint(human,100e6); vm.startPrank(human); dollar.approve(address(credits),100e6); credits.mint(100e6,human);
        credits.redeem(75e6); vm.stopPrank();
        assertEq(dollar.balanceOf(human),75e6); assertEq(credits.balanceOf(human),25e6); assertEq(dollar.balanceOf(address(credits)),credits.totalSupply());
        vm.prank(vendor); vm.expectRevert(); credits.redeem(1);
        vm.prank(human); vm.expectRevert("Amount"); credits.redeem(0);
    }
    function testRecoveryBindsCheckpointBuildChainAccountAndGeneration() public {
        bytes32 checkpoint = keccak256("encrypted checkpoint"); address next = address(0xD1);
        vm.prank(runtime); account.checkpoint(1, checkpoint);
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(account), agentId, uint256(1), checkpoint, keccak256("build"), next)); verifier.set(commitment);
        vm.expectRevert("Runtime alive"); account.recover(next, "synthetic attestation");
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert("Recovery evidence"); account.recover(address(0xE1), "synthetic attestation");
        account.recover(next, "synthetic attestation"); assertEq(account.signer(), next); assertEq(account.generation(), 2);
        vm.prank(runtime); vm.expectRevert("Runtime generation"); account.pulse(1);
        vm.prank(next); vm.expectRevert("Runtime generation"); account.pulse(1);
        vm.prank(next); account.pulse(2);
    }
    function testMessageAuthorshipAndSize() public {
        NoerraAgentMessages board = registry.messages();
        vm.expectRevert("Agent account only"); board.send(agentId, keccak256("wall"), "hello");
        vm.prank(runtime); account.post(1, keccak256("wall"), "hello"); assertEq(board.sequences(keccak256("wall")), 1);
        vm.prank(runtime); vm.expectRevert("Message size"); account.post(1, keccak256("wall"), new bytes(4097));
    }
    function testHumanshipRequiresAcceptance() public {
        vm.prank(human); account.offerHuman(address(0xD1)); assertEq(account.human(), human);
        vm.prank(vendor); vm.expectRevert("Proposed human only"); account.acceptHuman();
        vm.prank(address(0xD1)); account.acceptHuman(); assertEq(account.human(), address(0xD1));
        vm.prank(human); vm.expectRevert("Human only"); account.setRecipient(human, true);
    }
}
