// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {NoerraEcosystemVault, NoerraNoerMarket, INoerraFlagshipRegistry} from "../src/agents/NoerraEcosystem.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraQuoter} from "../src/agents/NoerraQuoter.sol";
import {AgentTestDollar, AgentTestVerifier} from "./NoerraAgents.t.sol";
import {NoerraEcosystemFixture} from "./NoerraEcosystemFixture.sol";

contract NoerraFlagshipTest is Test {
    AgentTestDollar dollar;
    AgentTestVerifier verifier;
    NoerraAgentRegistry registry;
    NoerraEcosystemVault vault;
    NoerraNoerMarket market;
    NoerraRevenueCoin noer;
    bytes32 constant BUILD = keccak256("reviewed build");
    bytes32 constant META = keccak256("fixed local identity");
    bytes32 id;
    address account;
    address capacity;
    function setUp() public {
        vm.chainId(1); vm.roll(100);
        dollar = new AgentTestDollar(); verifier = new AgentTestVerifier(); registry = new NoerraAgentRegistry(dollar, verifier);
        (,capacity) = registry.create(address(0xB1),keccak256("capacity"),BUILD,10e6,5e6,"","");
        (id,account) = registry.predictAccount(address(this),1,address(this),META,BUILD,50e6,7e6);
        IPoolManager manager = new PoolManager(address(this)); noer = new NoerraRevenueCoin(address(this));
        vault = new NoerraEcosystemVault(dollar,noer,manager,new NoerraQuoter(manager),address(0xD2),account,address(0xC1));
        market = NoerraEcosystemFixture.deployMarket(manager,dollar,noer,vault); vault.bindMarket(market);
    }
    function _create() internal { (bytes32 actual,address deployed) = registry.createAccount(address(this),META,BUILD,50e6,7e6); assertEq(actual,id); assertEq(deployed,account); }
    function _bind() internal {
        if(account.code.length > 0) {
            NoerraAgentAccount source = NoerraAgentAccount(account);
            if(!source.autonomousCoreLocked()) {
                source.setRecoveryPolicy(5e6,1e6);
                source.approveAutomaticActivation(1,keccak256("flagship startup"),51e6,block.timestamp+1 days,0.001 ether);
                if(registry.autonomousFlagshipVault()==address(0)) registry.enrollAutonomousFlagshipVault(address(vault));
            }
        }
        vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
    }
    function testOtherOwnersCannotOccupyFlagshipAndEveryReviewedTermChangesAddress() public {
        vm.startPrank(address(0xA1));
        registry.create(address(0xA1),META,BUILD,1,1,"","");
        registry.createAccount(address(0xA1),META,BUILD,50e6,7e6); vm.stopPrank();
        (,address unchanged) = registry.predictAccount(address(this),1,address(this),META,BUILD,50e6,7e6);
        assertEq(unchanged,account);
        (,address changed) = registry.predictAccount(address(this),1,address(this),keccak256("other metadata"),BUILD,50e6,7e6); assertNotEq(changed,account);
        (,changed) = registry.predictAccount(address(this),1,address(this),META,keccak256("other build"),50e6,7e6); assertNotEq(changed,account);
        (,changed) = registry.predictAccount(address(this),1,address(this),META,BUILD,50e6+1,7e6); assertNotEq(changed,account);
        (,changed) = registry.predictAccount(address(this),1,address(this),META,BUILD,50e6,7e6+1); assertNotEq(changed,account);
        _create(); _bind(); assertEq(registry.tokens(id),address(0)); assertEq(registry.creationBlocks(id),block.number);
        assertEq(vault.agentAccount(),account); assertEq(vault.agentId(),id); assertEq(vault.agentRegistry(),address(registry)); assertEq(vault.agentBuildHash(),BUILD);
        assertNotEq(account,capacity); assertEq(NoerraAgentAccount(capacity).dailyLimit(),5e6); assertEq(NoerraAgentAccount(account).dailyLimit(),7e6);
    }
    function testPlatformPoolCannotStartBeforeEnrolledApprovedFlagshipLock() public {
        noer.transfer(address(market),noer.totalSupply()); uint256 supply=noer.totalSupply();
        vm.expectRevert("Autonomous flagship binding"); market.initialize(supply);
        _create(); registry.enrollAutonomousFlagshipVault(address(vault));
        vm.expectRevert("Autonomous approval"); vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
        assertEq(vault.agentAccount(),address(0)); assertFalse(NoerraAgentAccount(account).autonomousCoreLocked());
        _bind(); assertTrue(NoerraAgentAccount(account).autonomousCoreLocked());
        market.initialize(supply); assertGt(market.lockedLiquidity(),0);
        vm.expectRevert("One deployment binding"); registry.enrollAutonomousFlagshipVault(address(vault));
    }
    function testDonationBeforeCreationAndBindingCannotBlockOrRedirectOperations() public {
        dollar.mint(address(this),100e6); dollar.approve(address(vault),100e6); vault.receiveRevenue(100e6);
        assertEq(dollar.balanceOf(account),10e6); _create(); _bind();
        assertEq(dollar.balanceOf(account),10e6); assertEq(dollar.balanceOf(vault.buybackTreasury()),40e6); assertEq(dollar.balanceOf(capacity),0);
        noer.transfer(address(market),noer.totalSupply()); market.initialize(noer.totalSupply());
        assertEq(noer.totalSupply(),1_000_000_000 ether); assertGt(market.lockedLiquidity(),0);
        dollar.mint(account,50e6); NoerraAgentAccount source = NoerraAgentAccount(account);
        assertTrue(source.autonomousCoreLocked());
        vm.expectRevert("Autonomous policy"); source.setRecipient(address(0xD1),true);
        vm.expectRevert("Autonomous startup"); source.pay(1,keccak256("unattested work"),address(0xD1),7e6);
        assertEq(dollar.balanceOf(account),60e6);
    }
    function testUnauthorizedDuplicateForeignAndUncreatedBindingRejected() public {
        vm.expectRevert("Tokenless registry account"); vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id); _create();
        NoerraAgentAccount source=NoerraAgentAccount(account); source.setRecoveryPolicy(5e6,1e6);
        source.approveAutomaticActivation(1,keccak256("flagship startup"),51e6,block.timestamp+1 days,0.001 ether);
        registry.enrollAutonomousFlagshipVault(address(vault));
        vm.prank(address(0xA1)); vm.expectRevert("One platform agent binding"); vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
        vm.expectRevert("Tokenless registry account"); vault.bindAgent(INoerraFlagshipRegistry(address(registry)),bytes32(uint256(1)));
        _bind(); vm.expectRevert("One platform agent binding"); vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
    }
    function testChangedBuildOrSignerCannotBecomeCommittedRecipient() public {
        registry.createAccount(address(this),META,keccak256("wrong build"),50e6,7e6);
        vm.expectRevert("Flagship account"); _bind();
    }
    function testWrongDollarRegistryRejected() public {
        NoerraAgentRegistry other = new NoerraAgentRegistry(new AgentTestDollar(),verifier);
        (bytes32 otherId,) = other.createAccount(address(this),META,BUILD,50e6,7e6);
        vm.expectRevert("Tokenless registry account"); vault.bindAgent(INoerraFlagshipRegistry(address(other)),otherId);
    }
    function testChangedInitialSignerAndZeroBuildAreRejected() public {
        vm.expectRevert("Bounds"); registry.createAccount(address(this),META,bytes32(0),50e6,7e6);
        (bytes32 wrongId,address wrongAccount) = registry.createAccount(address(0xA1),META,BUILD,50e6,7e6);
        IPoolManager manager = market.manager();
        NoerraEcosystemVault other = new NoerraEcosystemVault(dollar,noer,manager,vault.quoter(),address(0xD2),wrongAccount,address(0xC1));
        NoerraNoerMarket otherMarket = NoerraEcosystemFixture.deployMarket(manager,dollar,noer,other); other.bindMarket(otherMarket);
        vm.expectRevert("Original platform authority"); other.bindAgent(INoerraFlagshipRegistry(address(registry)),wrongId);
    }
    function testBothCanonicalAccountsStayDeterministicAfterForeignCreates() public {
        NoerraAgentRegistry fresh = new NoerraAgentRegistry(dollar,verifier);
        bytes32 capacityMeta=keccak256("independent capacity");
        (bytes32 capacityId,address expectedCapacity)=fresh.predictAccount(address(this),0,address(0xB1),capacityMeta,BUILD,10e6,5e6);
        (bytes32 flagshipId,address expectedFlagship)=fresh.predictAccount(address(this),1,address(this),META,BUILD,50e6,7e6);
        vm.prank(address(0xA1)); fresh.create(address(0xA1),META,BUILD,1,1,"","");
        (bytes32 madeCapacity,address actualCapacity)=fresh.createAccount(address(0xB1),capacityMeta,BUILD,10e6,5e6);
        vm.prank(address(0xA1)); fresh.createAccount(address(0xA1),META,BUILD,1,1);
        (bytes32 madeFlagship,address actualFlagship)=fresh.createAccount(address(this),META,BUILD,50e6,7e6);
        assertEq(madeCapacity,capacityId);assertEq(actualCapacity,expectedCapacity);
        assertEq(madeFlagship,flagshipId);assertEq(actualFlagship,expectedFlagship);assertNotEq(actualCapacity,actualFlagship);
    }
    function testForeignOwnerCannotBindEvenWhenChosenAsOperationsRecipient() public {
        vm.prank(address(0xA1)); (bytes32 foreignId,address foreignAccount) = registry.createAccount(address(0xA1),META,BUILD,50e6,7e6);
        IPoolManager manager = market.manager();
        NoerraEcosystemVault other = new NoerraEcosystemVault(dollar,noer,manager,vault.quoter(),address(0xD2),foreignAccount,address(0xC1));
        NoerraNoerMarket otherMarket = NoerraEcosystemFixture.deployMarket(manager,dollar,noer,other); other.bindMarket(otherMarket);
        vm.expectRevert("Original platform authority"); other.bindAgent(INoerraFlagshipRegistry(address(registry)),foreignId);
    }
}
