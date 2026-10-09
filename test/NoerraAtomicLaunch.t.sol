// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";
import {NoerraEcosystemFixture} from "./NoerraEcosystemFixture.sol";
import {NoerraAtomicLaunch,NoerraAtomicCreationCode} from "../src/agents/NoerraAtomicLaunch.sol";
import {NoerraAtomicCodeHashes} from "../src/agents/NoerraAtomicCodeHashes.sol";
import {NoerraEcosystemVault,NoerraAtomicEcosystemVault,NoerraNoerMarket} from "../src/agents/NoerraEcosystem.sol";
import {NoerraAgentRegistry,NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraNoerFeeHook} from "../src/agents/NoerraUsdcFeeHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NoerraAtomicLaunchTest is Test {
    AgentTestDollar dollar; IPoolManager manager; NoerraEcosystemVault vault; NoerraNoerMarket market; NoerraRevenueCoin noer;
    address operations=address(0xA1);address operator=address(0xB1);address outsider=address(0xC1);
    NoerraAtomicLaunch factory;
    NoerraAgentRegistry atomicRegistry;
    address account;
    bytes32 id;
    bytes32 hookSalt;
    NoerraNoerMarket.LaunchBuy[] buys;
    address tokenPred; address vaultPred; address marketPred; address hookPred;
    function setUp() public {
        vm.chainId(1);vm.warp(1000);dollar=new AgentTestDollar();manager=new PoolManager(address(this));
        (vault,market,noer)=NoerraEcosystemFixture.deploy(manager,dollar,operations,operator);
        noer.transfer(address(market),noer.totalSupply());market.initialize(noer.totalSupply());
        for(uint256 i;i<24;++i) {
            (uint256 cost,uint256 output)=_launchCostBelow(18_100_000 ether);
            address buyer=vm.addr(7000+i);
            buys.push(NoerraNoerMarket.LaunchBuy(buyer,cost,18_000_000 ether,19_900_000 ether));
            dollar.mint(buyer,cost);vm.startPrank(buyer);dollar.approve(address(market),cost);
            market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();
        }
        (atomicRegistry,id,account)=NoerraEcosystemFixture.prepareAccount(dollar);
        address[4] memory codes;
        codes[0]=address(new NoerraAtomicCreationCode(type(NoerraRevenueCoin).creationCode));
        codes[1]=address(new NoerraAtomicCreationCode(type(NoerraAtomicEcosystemVault).creationCode));
        codes[2]=address(new NoerraAtomicCreationCode(type(NoerraNoerMarket).creationCode));
        codes[3]=address(new NoerraAtomicCreationCode(type(NoerraNoerFeeHook).creationCode));
        NoerraAtomicLaunch.Configuration memory c=NoerraAtomicLaunch.Configuration(address(this),address(atomicRegistry),id,account,
            address(manager),address(dollar),address(vault.quoter()),address(market.ethUsdFeed()),7200,operations,operator,keccak256(abi.encode(buys)),0);
        factory=new NoerraAtomicLaunch(c,codes);
        tokenPred=factory.tokenAddress();vaultPred=factory.vaultAddress();
        for(uint256 i;;++i){hookSalt=bytes32(i);hookPred=factory.hookAddress(hookSalt);if(uint160(hookPred)&0x3fff==0x20cc)break;}
        marketPred=factory.marketAddress(hookSalt);
        atomicRegistry.authorizeAtomicFlagship(address(factory),0);
        for(uint256 i;i<24;++i){dollar.mint(buys[i].buyer,buys[i].amountIn);vm.prank(buys[i].buyer);dollar.approve(marketPred,buys[i].amountIn);}
    }
    function _quote(uint256 amount) internal returns(uint256 output) {
        PoolKey memory key=market.poolKey();(output,)=vault.quoter().quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key,
            Currency.unwrap(key.currency0)==address(dollar),uint128(amount),""));
    }
    function _launchCostBelow(uint256 target) internal returns(uint256 cost,uint256 output) {
        uint256 low=1;uint256 high=10000e6;
        while(low<high){uint256 mid=(low+high+1)/2;PoolKey memory key=market.poolKey();
            try vault.quoter().quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key,
                Currency.unwrap(key.currency0)==address(dollar),uint128(mid),"")) returns(uint256 quoted,uint256) {
                if(quoted<=target)low=mid;else high=mid-1;
            }catch{high=mid-1;}}
        cost=low;output=_quote(cost);
    }
    function testFactoryAllTwentyFourCreateAndBuyInSameTransactionPreservingCustody() public {
        uint256 beforeGas=gasleft();uint256[] memory outputs=factory.launch(hookSalt,buys,block.timestamp+120);
        uint256 gasUsed=beforeGas-gasleft();emit log_named_uint("Full atomic deployment and 24 buys execution gas",gasUsed);
        assertLt(gasUsed,15_000_000);assertEq(outputs.length,24);assertTrue(factory.launched());
        assertTrue(NoerraAgentAccount(account).autonomousCoreLocked());assertEq(NoerraAgentAccount(account).human(),address(this));
        assertEq(NoerraAgentAccount(account).signer(),address(this));assertEq(atomicRegistry.flagshipAuthorizationNonce(),1);
        assertEq(atomicRegistry.autonomousFlagshipVault(),vaultPred);
        NoerraAtomicEcosystemVault target=NoerraAtomicEcosystemVault(vaultPred);
        assertEq(target.deployer(),address(this));assertEq(target.launchExecutor(),address(factory));
        assertEq(target.operationsTreasury(),operations);assertEq(target.agentTreasury(),account);assertEq(target.buybackTreasury(),operator);
        NoerraNoerMarket m=NoerraNoerMarket(marketPred);assertEq(m.deployer(),address(this));assertEq(m.launchExecutor(),address(factory));
        assertEq(m.feeHook().feeBps(),2500);assertEq(NoerraRevenueCoin(tokenPred).protectionEndBlock(),block.number+10);
        for(uint256 i;i<24;++i){assertGe(outputs[i],buys[i].minimumOut);assertLe(outputs[i],buys[i].maximumOut);assertEq(IERC20(tokenPred).balanceOf(buys[i].buyer),outputs[i]);}
        uint256 fees=m.feeHook().accruedFees(_poolId(m));uint256 beforeOps=dollar.balanceOf(operations);
        uint256 beforeAccount=dollar.balanceOf(account);uint256 beforeBuyback=dollar.balanceOf(operator);m.collect();
        assertEq(dollar.balanceOf(operations)-beforeOps,fees*50/100);assertEq(dollar.balanceOf(account)-beforeAccount,fees*10/100);
        assertEq(dollar.balanceOf(operator)-beforeBuyback,fees-fees*50/100-fees*10/100);
        vm.expectRevert("One owner launch");factory.launch(hookSalt,buys,block.timestamp+120);
        vm.expectRevert("Atomic launch only");m.initialize(1_000_000_000 ether);
        vm.expectRevert("One bound launch");m.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        vm.roll(block.number+10);assertEq(m.feeHook().feeBps(),175);
    }
    function _poolId(NoerraNoerMarket m) private view returns(PoolId) {return PoolId.wrap(keccak256(abi.encode(m.poolKey())));}
    function _assertUnlaunched() private view {
        assertEq(tokenPred.code.length,0);assertEq(vaultPred.code.length,0);assertEq(marketPred.code.length,0);assertEq(hookPred.code.length,0);
        assertFalse(factory.launched());assertFalse(NoerraAgentAccount(account).autonomousCoreLocked());
        assertEq(atomicRegistry.autonomousFlagshipVault(),address(0));assertEq(atomicRegistry.flagshipAuthorizationNonce(),0);
        assertEq(atomicRegistry.authorizedFlagshipFactory(),address(factory));assertEq(atomicRegistry.authorizedFlagshipVault(),vaultPred);
    }
    function testFinalBuyerFailureErasesEveryChildAndEnrollmentThenRetrySucceeds() public {
        vm.prank(buys[23].buyer);dollar.approve(marketPred,0);
        vm.expectRevert();factory.launch(hookSalt,buys,block.timestamp+120);_assertUnlaunched();
        for(uint256 i;i<24;++i){assertEq(dollar.balanceOf(buys[i].buyer),buys[i].amountIn);assertEq(dollar.allowance(buys[i].buyer,marketPred),i==23?0:buys[i].amountIn);}
        vm.prank(buys[23].buyer);dollar.approve(marketPred,buys[23].amountIn);
        factory.launch(hookSalt,buys,block.timestamp+120);assertTrue(factory.launched());
    }
    function testWrongOwnerRosterAmountBoundsDeadlineAndLegacyEscapeReject() public {
        vm.prank(outsider);vm.expectRevert("One owner launch");factory.launch(hookSalt,buys,block.timestamp+120);
        vm.expectRevert("Fresh deadline");factory.launch(hookSalt,buys,block.timestamp-1);
        vm.expectRevert("One deployment binding");atomicRegistry.enrollAutonomousFlagshipVault(address(vault));
        vm.prank(outsider);vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(vaultPred,0);
        uint256 saved=buys[0].amountIn;buys[0].amountIn++;vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);buys[0].amountIn=saved;
        address first=buys[0].buyer;buys[0].buyer=buys[1].buyer;vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);buys[0].buyer=first;
        buys.pop();vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);_assertUnlaunched();
    }
    function testCommitmentRejectsMinimumMaximumAndOrderChanges() public {
        uint256 saved=buys[0].minimumOut;buys[0].minimumOut++;
        vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);buys[0].minimumOut=saved;
        saved=buys[0].maximumOut;buys[0].maximumOut--;
        vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);buys[0].maximumOut=saved;
        NoerraNoerMarket.LaunchBuy memory first=buys[0];buys[0]=buys[1];buys[1]=first;
        vm.expectRevert("Exact 24 allocations");factory.launch(hookSalt,buys,block.timestamp+120);_assertUnlaunched();
    }
    function testRegistryRejectsWrongNonceVaultFactoryAndGetterSubstitution() public {
        vm.prank(address(factory));vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(vaultPred,1);
        vm.prank(address(factory));vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(address(vault),0);
        vm.prank(outsider);vm.expectRevert("One atomic authorization");atomicRegistry.authorizeAtomicFlagship(address(factory),0);
        vm.expectRevert("One atomic authorization");atomicRegistry.authorizeAtomicFlagship(address(factory),0);
        vm.mockCall(address(factory),abi.encodeWithSignature("vaultAddress()"),abi.encode(address(vault)));
        vm.prank(address(factory));vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(vaultPred,0);vm.clearMockedCalls();
        vm.mockCall(address(factory),abi.encodeWithSignature("allocationHash()"),abi.encode(keccak256("changed")));
        vm.prank(address(factory));vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(vaultPred,0);vm.clearMockedCalls();
        _assertUnlaunched();factory.launch(hookSalt,buys,block.timestamp+120);
        vm.prank(address(factory));vm.expectRevert("Exact atomic authorization");atomicRegistry.enrollAtomicFlagshipVault(vaultPred,0);
    }
    function testOwnerRevocationInvalidatesOldFactoryAndFreshNonceCanLaunch() public {
        vm.prank(outsider);vm.expectRevert("Pending owner authorization");atomicRegistry.revokeAtomicFlagship(0);
        vm.expectRevert("Pending owner authorization");atomicRegistry.revokeAtomicFlagship(1);
        atomicRegistry.revokeAtomicFlagship(0);assertEq(atomicRegistry.flagshipAuthorizationNonce(),1);
        vm.expectRevert("Atomic binding");atomicRegistry.authorizeAtomicFlagship(address(factory),1);
        vm.expectRevert("Exact atomic authorization");factory.launch(hookSalt,buys,block.timestamp+120);
        assertEq(tokenPred.code.length,0);assertEq(vaultPred.code.length,0);assertEq(marketPred.code.length,0);assertEq(hookPred.code.length,0);
        assertFalse(factory.launched());assertFalse(NoerraAgentAccount(account).autonomousCoreLocked());
        address[4] memory codes;for(uint256 i;i<4;++i)codes[i]=factory.codeContainers(i);
        NoerraAtomicLaunch.Configuration memory c=NoerraAtomicLaunch.Configuration(address(this),address(atomicRegistry),id,account,
            address(manager),address(dollar),address(vault.quoter()),address(market.ethUsdFeed()),7200,operations,operator,keccak256(abi.encode(buys)),1);
        NoerraAtomicLaunch next=new NoerraAtomicLaunch(c,codes);atomicRegistry.authorizeAtomicFlagship(address(next),1);
        bytes32 salt;for(uint256 i;;++i){salt=bytes32(i);if(uint160(next.hookAddress(salt))&0x3fff==0x20cc)break;}
        address destination=next.marketAddress(salt);
        for(uint256 i;i<24;++i){vm.prank(buys[i].buyer);dollar.approve(destination,buys[i].amountIn);}
        vm.expectRevert("Exact atomic authorization");factory.launch(hookSalt,buys,block.timestamp+120);
        next.launch(salt,buys,block.timestamp+120);assertEq(atomicRegistry.flagshipAuthorizationNonce(),2);
        vm.expectRevert("Pending owner authorization");atomicRegistry.revokeAtomicFlagship(2);
    }
    function testPinnedCreationCodeAndLiveSizeLimits() public view {
        assertEq(NoerraAtomicCodeHashes.expected(0),keccak256(type(NoerraRevenueCoin).creationCode));
        assertEq(NoerraAtomicCodeHashes.expected(1),keccak256(type(NoerraAtomicEcosystemVault).creationCode));
        assertEq(NoerraAtomicCodeHashes.expected(2),keccak256(type(NoerraNoerMarket).creationCode));
        assertEq(NoerraAtomicCodeHashes.expected(3),keccak256(type(NoerraNoerFeeHook).creationCode));
        assertLe(address(factory).code.length,24576);assertLe(type(NoerraAtomicLaunch).creationCode.length+1024,49152);
        for(uint256 i;i<4;++i)assertLe(factory.codeContainers(i).code.length,24576);
    }
}
