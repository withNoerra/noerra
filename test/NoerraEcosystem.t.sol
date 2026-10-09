// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {AgentTestDollar} from "./NoerraAgents.t.sol";
import {NoerraEcosystemFixture,NoerraPlatformOracleFixture} from "./NoerraEcosystemFixture.sol";
import {NoerraEcosystemVault, NoerraNoerMarket, NoerraNoerMarketDeployer,INoerraPlatformEthUsdFeed} from "../src/agents/NoerraEcosystem.sol";
import {NoerraAgentRegistry} from "../src/agents/NoerraAgents.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraQuoter} from "../src/agents/NoerraQuoter.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {NoerraNoerFeeHook} from "../src/agents/NoerraUsdcFeeHook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract NoerraEcosystemTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    AgentTestDollar dollar;
    NoerraRevenueCoin noer;
    IPoolManager manager;
    NoerraEcosystemVault vault;
    NoerraNoerMarket market;
    address operations = address(0xA1);
    address operator = address(0xB1);
    address outsider = address(0xC1);
    function setUp() public {
        vm.chainId(1); vm.warp(1000);
        dollar = new AgentTestDollar(); manager = new PoolManager(address(this));
        (vault, market, noer) = NoerraEcosystemFixture.deploy(manager, dollar, operations, operator);
        noer.transfer(address(market), noer.totalSupply());
        market.initialize(noer.totalSupply()); vm.roll(block.number+10);
    }
    function _fund(uint256 amount) internal {
        dollar.mint(address(this), amount); dollar.approve(address(vault), amount); vault.receiveRevenue(amount);
    }
    function _quote(uint256 amount) internal returns (uint256 output) {
        PoolKey memory key = market.poolKey();
        (output,) = vault.quoter().quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key,
            Currency.unwrap(key.currency0) == address(dollar), uint128(amount), ""));
    }
    function _launchCostBelow(uint256 target) internal returns(uint256 cost,uint256 output) {
        // USDC has six decimals: choose the greatest exact input whose real
        // hook-aware quote stays below the chosen supply cap.
        uint256 low = 1; uint256 high = 10000e6;
        while(low < high) {
            uint256 mid = (low + high + 1) / 2;
            PoolKey memory key = market.poolKey();
            try vault.quoter().quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key,
                Currency.unwrap(key.currency0) == address(dollar),uint128(mid),"")) returns(uint256 quoted,uint256) {
                if(quoted <= target) low = mid; else high = mid - 1;
            } catch { high = mid - 1; }
        }
        cost = low; output = _quote(cost);
    }
    function testFifteenLaunchWalletsBuyInOneBlockAndWalletOneCanSellIndependently() public {
        vm.roll(market.launchBlock());
        address[15] memory wallets; uint256[15] memory balances;
        uint256 totalCost; uint256 totalTokens;
        for(uint256 i; i < 15; ++i) {
            wallets[i] = vm.addr(1000 + i);
            uint256 bps = i == 14 ? 199 : 181 + i;
            (uint256 cost,uint256 output) = _launchCostBelow(noer.totalSupply() * bps / 10000);
            assertGe(output,18_000_000 ether); assertLe(output,19_900_000 ether);
            dollar.mint(wallets[i],cost);
            vm.startPrank(wallets[i]);dollar.approve(address(market),cost);
            balances[i] = market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();
            assertEq(balances[i],output);assertEq(noer.balanceOf(wallets[i]),output);
            assertEq(dollar.balanceOf(wallets[i]),0);assertEq(block.number,market.launchBlock());
            totalCost += cost;totalTokens += output;
        }
        assertGe(totalTokens,270_000_000 ether);assertLe(totalTokens,298_500_000 ether);
        uint256 sell = balances[0] * 33 / 100;
        vm.startPrank(wallets[0]);noer.approve(address(market),sell);
        uint256 proceeds = market.trade(false,sell,1,block.timestamp+120);vm.stopPrank();
        assertGt(proceeds,0);assertEq(noer.balanceOf(wallets[0]),balances[0]-sell);
        for(uint256 i=1;i<15;++i)assertEq(noer.balanceOf(wallets[i]),balances[i]);
        emit log_named_uint("15 launch wallets USDC micros",totalCost);
        emit log_named_uint("15 launch wallets token units",totalTokens);
    }
    function testARevertingWalletDoesNotRollbackAnEarlierSeparateWalletTrade() public {
        vm.roll(market.launchBlock());address first=vm.addr(1000);address second=vm.addr(1001);
        (uint256 cost,uint256 output)=_launchCostBelow(18_100_000 ether);
        dollar.mint(first,cost);vm.startPrank(first);dollar.approve(address(market),cost);
        market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();
        vm.startPrank(second);dollar.approve(address(market),cost);vm.expectRevert();
        market.trade(true,cost,1,block.timestamp+120);vm.stopPrank();
        assertEq(noer.balanceOf(first),output);assertEq(noer.balanceOf(second),0);
    }
    function testImmutableHookCodeContainerFitsLiveLimitsAndPreservesCreate2Identities() public {
        NoerraNoerMarketDeployer builder=new NoerraNoerMarketDeployer();address container=builder.hookCreationCode();
        assertLe(address(builder).code.length,24576);assertLe(type(NoerraNoerMarketDeployer).creationCode.length,49152);
        assertEq(keccak256(container.code),keccak256(abi.encodePacked(hex"00",type(NoerraNoerFeeHook).creationCode)));
        bytes32 initHash=keccak256(abi.encodePacked(type(NoerraNoerFeeHook).creationCode,abi.encode(manager,address(dollar),address(noer),address(builder))));
        bytes32 salt;address predictedHook;
        for(uint256 i;;++i){salt=bytes32(i);predictedHook=address(uint160(uint256(keccak256(abi.encodePacked(hex"ff",address(builder),salt,initHash)))));if(uint160(predictedHook)&0x3fff==0x20cc)break;}
        INoerraPlatformEthUsdFeed feed=market.ethUsdFeed();
        bytes32 marketHash=keccak256(abi.encodePacked(type(NoerraNoerMarket).creationCode,abi.encode(manager,dollar,noer,vault,NoerraNoerFeeHook(predictedHook),feed,uint32(7200))));
        address predictedMarket=address(uint160(uint256(keccak256(abi.encodePacked(hex"ff",address(builder),salt,marketHash)))));
        vm.prank(outsider);vm.expectRevert("Deployment owner only");builder.deploy(manager,dollar,noer,vault,salt,feed,7200);
        NoerraNoerMarket created=builder.deploy(manager,dollar,noer,vault,salt,feed,7200);
        assertEq(address(created),predictedMarket);assertEq(address(created.feeHook()),predictedHook);
        assertEq(created.deployer(),address(this));assertEq(created.feeHook().registrationAuthority(),address(builder));
        assertLe(address(created).code.length,24576);assertLe(predictedHook.code.length,24576);
        (bool ok,bytes memory result)=container.call(hex"deadbeef");assertTrue(ok);assertEq(result.length,0);
        assertEq(keccak256(container.code),keccak256(abi.encodePacked(hex"00",type(NoerraNoerFeeHook).creationCode)));
    }
    function _prepareAtomic() internal returns(NoerraNoerMarket.LaunchBuy[] memory buys) {
        return _prepareAtomicCount(15);
    }
    function _prepareAtomicCount(uint256 count) internal returns(NoerraNoerMarket.LaunchBuy[] memory buys) {
        (vault,market,noer)=NoerraEcosystemFixture.deploy(manager,dollar,operations,operator);
        noer.transfer(address(market),noer.totalSupply());
        uint256 snapshot=vm.snapshotState();market.initialize(noer.totalSupply());
        buys=new NoerraNoerMarket.LaunchBuy[](count);
        for(uint256 i;i<count;++i) {
            address wallet=vm.addr(3000+i);
            uint256 target=18_100_000 ether+(i%19)*100_000 ether;
            (uint256 cost,uint256 output)=_launchCostBelow(target);
            buys[i]=NoerraNoerMarket.LaunchBuy(wallet,cost,output,target);
            dollar.mint(wallet,cost);vm.startPrank(wallet);dollar.approve(address(market),cost);
            market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();
        }
        require(vm.revertToState(snapshot),"Atomic preparation reset");
        for(uint256 i;i<count;++i){dollar.mint(buys[i].buyer,buys[i].amountIn);vm.prank(buys[i].buyer);dollar.approve(address(market),buys[i].amountIn);}
    }
    function testAtomicTwentyFourWalletLaunchReturnsAllOutputsAndIndependentSell() public {
        NoerraNoerMarket.LaunchBuy[] memory buys=_prepareAtomicCount(24);
        uint256 beforeGas=gasleft();uint256[] memory outputs=market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        emit log_named_uint("Atomic initialize plus twenty-four buys execution gas",beforeGas-gasleft());
        assertEq(outputs.length,24);assertEq(market.launchBlock(),block.number);
        assertEq(noer.protectionStartBlock(),block.number);assertEq(noer.protectionEndBlock(),block.number+10);
        uint256 fees;
        for(uint256 i;i<24;++i){
            assertEq(noer.balanceOf(buys[i].buyer),outputs[i]);assertGe(outputs[i],buys[i].minimumOut);assertLe(outputs[i],buys[i].maximumOut);
            assertEq(dollar.balanceOf(buys[i].buyer),0);fees+=Math.mulDiv(buys[i].amountIn,2500,10000,Math.Rounding.Ceil);
        }
        PoolKey memory key=market.poolKey();assertEq(market.feeHook().accruedFees(key.toId()),fees);
        uint256 sold=outputs[0]*33/100;vm.startPrank(buys[0].buyer);noer.approve(address(market),sold);
        market.trade(false,sold,1,block.timestamp+120);vm.stopPrank();assertEq(noer.balanceOf(buys[0].buyer),outputs[0]-sold);
        for(uint256 i=1;i<24;++i)assertEq(noer.balanceOf(buys[i].buyer),outputs[i]);
    }
    function testTwentyFourthFailureRollsBackPoolOutputsFeesAndProtectionThenAllowsRetry() public {
        NoerraNoerMarket.LaunchBuy[] memory buys=_prepareAtomicCount(24);uint256 original=buys[23].minimumOut;
        buys[23].minimumOut=buys[23].maximumOut;
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        assertEq(market.lockedLiquidity(),0);assertEq(market.launchBlock(),0);assertEq(market.initialValuation(),0);
        assertEq(noer.protectionStartBlock(),0);assertEq(noer.protectionEndBlock(),0);
        assertEq(noer.balanceOf(address(market)),noer.totalSupply());PoolKey memory key=market.poolKey();
        (uint160 price,,,) = manager.getSlot0(key.toId());assertEq(price,0);assertEq(manager.getLiquidity(key.toId()),0);
        assertEq(market.feeHook().accruedFees(key.toId()),0);
        for(uint256 i;i<24;++i){assertEq(noer.balanceOf(buys[i].buyer),0);assertEq(dollar.balanceOf(buys[i].buyer),buys[i].amountIn);assertEq(dollar.allowance(buys[i].buyer,address(market)),buys[i].amountIn);}
        buys[23].minimumOut=original;market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        for(uint256 i;i<24;++i)assertGe(noer.balanceOf(buys[i].buyer),buys[i].minimumOut);
    }
    function testAtomicLaunchIncludesAllFifteenAndIndependentSell() public {
        NoerraNoerMarket.LaunchBuy[] memory buys=_prepareAtomic();
        uint256 beforeGas=gasleft();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        emit log_named_uint("Atomic initialize plus fifteen buys execution gas",beforeGas-gasleft());
        assertEq(market.launchBlock(),block.number);assertGt(market.lockedLiquidity(),0);
        for(uint256 i;i<15;++i){assertGe(noer.balanceOf(buys[i].buyer),buys[i].minimumOut);assertLe(noer.balanceOf(buys[i].buyer),buys[i].maximumOut);assertEq(dollar.balanceOf(buys[i].buyer),0);}
        uint256 balance=noer.balanceOf(buys[0].buyer);vm.startPrank(buys[0].buyer);noer.approve(address(market),balance*33/100);
        market.trade(false,balance*33/100,1,block.timestamp+120);vm.stopPrank();
        assertEq(noer.balanceOf(buys[0].buyer),balance-balance*33/100);
        for(uint256 i=1;i<15;++i)assertGe(noer.balanceOf(buys[i].buyer),buys[i].minimumOut);
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
    }
    function testLastWalletFailureRevertsLaunchAllPurchasesAndAllFees() public {
        NoerraNoerMarket.LaunchBuy[] memory buys=_prepareAtomic();
        vm.prank(buys[14].buyer);dollar.approve(address(market),0);
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        assertEq(market.lockedLiquidity(),0);assertEq(market.launchBlock(),0);assertEq(noer.protectionEndBlock(),0);
        assertEq(noer.balanceOf(address(market)),noer.totalSupply());
        PoolKey memory key=market.poolKey();assertEq(market.feeHook().accruedFees(key.toId()),0);
        for(uint256 i;i<15;++i){assertEq(noer.balanceOf(buys[i].buyer),0);assertEq(dollar.balanceOf(buys[i].buyer),buys[i].amountIn);}
    }
    function testAtomicLaunchRejectsDuplicateMissingExpiredAndWrongAuthority() public {
        NoerraNoerMarket.LaunchBuy[] memory buys=_prepareAtomic();
        vm.prank(outsider);vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp-1);
        address original=buys[14].buyer;buys[14].buyer=buys[0].buyer;
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);buys[14].buyer=original;
        buys[14].maximumOut=20_000_000 ether;vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,buys,block.timestamp+120);
        NoerraNoerMarket.LaunchBuy[] memory missing=new NoerraNoerMarket.LaunchBuy[](14);
        vm.expectRevert();market.initializeWithBuys(1_000_000_000 ether,missing,block.timestamp+120);
        assertEq(market.lockedLiquidity(),0);
    }
    function testNoerraLaunchFeeIsTwentyFivePercentBothWaysForExactlyTenBlocks() public {
        vm.roll(market.launchBlock());assertEq(market.feeHook().feeBps(),2500);
        dollar.mint(outsider,10e6);vm.startPrank(outsider);dollar.approve(address(market),10e6);
        uint256 tokens=market.trade(true,10e6,1,block.timestamp+120);vm.stopPrank();
        PoolKey memory key=market.poolKey();assertEq(market.feeHook().accruedFees(key.toId()),2500000);
        vm.startPrank(outsider);noer.approve(address(market),tokens);vm.recordLogs();
        uint256 dollars=market.trade(false,tokens,1,block.timestamp+120);vm.stopPrank();
        (uint256 gross,uint256 fee)=_recordedFee();assertEq(fee,Math.mulDiv(gross,2500,10000,Math.Rounding.Ceil));assertEq(dollars,gross-fee);
        vm.roll(market.launchBlock()+9);assertEq(market.feeHook().feeBps(),2500);
        vm.roll(market.launchBlock()+10);assertEq(market.feeHook().feeBps(),175);
        dollar.mint(outsider,10e6);vm.startPrank(outsider);dollar.approve(address(market),10e6);vm.recordLogs();
        market.trade(true,10e6,1,block.timestamp+120);vm.stopPrank();
        (,fee)=_recordedFee();assertEq(fee,175000);
    }
    function testMaximumFifteenWalletLaunchCostIncludingTwentyFivePercentFee() public {
        (vault,market,noer)=NoerraEcosystemFixture.deploy(manager,dollar,operations,operator);
        uint256 price=vm.envOr("NOERRA_ESTIMATE_ETH_USD",uint256(2000e8));
        NoerraPlatformOracleFixture(address(market.ethUsdFeed())).set(int256(price),block.timestamp);
        noer.transfer(address(market),noer.totalSupply());market.initialize(noer.totalSupply());uint256 totalCost;
        uint256 count=vm.envOr("NOERRA_ESTIMATE_WALLETS",uint256(15));uint256 bps=vm.envOr("NOERRA_ESTIMATE_BPS",uint256(199));
        require(count>0 && count<=30 && bps>=180 && bps<=199,"Estimate bounds");
        uint256 target=1_000_000_000 ether*bps/10000+(bps==180?1 ether:0);
        for(uint256 i;i<count;++i){address wallet=vm.addr(5000+i);(uint256 cost,uint256 output)=_launchCostBelow(target);
            dollar.mint(wallet,cost);vm.startPrank(wallet);dollar.approve(address(market),cost);market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();totalCost+=cost;
            assertGe(output,18_000_000 ether);assertLe(output,19_900_000 ether);
            emit log_named_uint("Launch wallet USDC micros",cost);
        }
        emit log_named_uint("ETH USD oracle eight decimals",price);
        emit log_named_uint("Estimated wallet count",count);emit log_named_uint("Each wallet supply basis points",bps);
        emit log_named_uint("Maximum fifteen launch wallets USDC micros",totalCost);
        emit log_named_uint("Buy fee USDC micros",market.feeHook().accruedFees(market.poolKey().toId()));
    }
    function testProposedTwentyFourWalletSplitBudgetsAffordCommonTarget() public {
        uint256[] memory budgets=vm.envOr("NOERRA_SPLIT_BUDGETS",",",new uint256[](0));
        if(budgets.length==0){vm.skip(true);return;}
        require(budgets.length==24,"Twenty-four public budgets");
        (vault,market,noer)=NoerraEcosystemFixture.deploy(manager,dollar,operations,operator);
        uint256 price=vm.envOr("NOERRA_ESTIMATE_ETH_USD",uint256(2000e8));
        NoerraPlatformOracleFixture(address(market.ethUsdFeed())).set(int256(price),block.timestamp);
        noer.transfer(address(market),noer.totalSupply());market.initialize(noer.totalSupply());
        uint256 bps=vm.envOr("NOERRA_ESTIMATE_BPS",uint256(199));require(bps>=180&&bps<=199,"Allocation bounds");
        uint256[] memory targets=vm.envOr("NOERRA_SPLIT_TARGET_BPS",",",new uint256[](0));
        require(targets.length==0||targets.length==24,"Twenty-four target percentages");uint256 totalCost;
        for(uint256 i;i<24;++i){
            uint256 selected=targets.length==0?bps:targets[i];require(selected>=180&&selected<=199,"Per-wallet allocation bounds");
            uint256 target=1_000_000_000 ether*selected/10000+(selected==180?1 ether:0);
            address wallet=vm.addr(6000+i);(uint256 cost,uint256 output)=_launchCostBelow(target);
            emit log_named_uint("Split-wallet order",i+1);emit log_named_uint("Split-wallet USDC budget micros",budgets[i]);emit log_named_uint("Split-wallet buy cost micros",cost);
            assertLe(cost,budgets[i],"Individual split-wallet budget cannot fund target");
            dollar.mint(wallet,cost);vm.startPrank(wallet);dollar.approve(address(market),cost);market.trade(true,cost,output,block.timestamp+120);vm.stopPrank();
            assertGe(output,18_000_000 ether);assertLe(output,19_900_000 ether);totalCost+=cost;
        }
        emit log_named_uint("All twenty-four split wallets total USDC micros",totalCost);
    }
    function testRevenuePaysSeparateUserWalletsAndAgentWithoutAutomatedSpending() public {
        _fund(1000e6);
        assertEq(dollar.balanceOf(operations),500e6);assertEq(dollar.balanceOf(vault.agentTreasury()),100e6);
        assertEq(dollar.balanceOf(operator),400e6);assertEq(dollar.balanceOf(address(vault)),0);
        assertEq(vault.totalRevenue(),1000e6);assertEq(vault.totalOperations(),500e6);
        assertEq(vault.totalAgentFunding(),100e6);assertEq(vault.totalBuybackFunding(),400e6);
        assertEq(noer.balanceOf(address(vault)),0);
        (bool ok,)=address(vault).call(abi.encodeWithSignature("executeBuyback(uint256,uint256,uint256)",1,1,block.timestamp+60));assertFalse(ok);
        vm.startPrank(operator);dollar.approve(address(market),100e6);uint256 bought=market.trade(true,100e6,1,block.timestamp+60);vm.stopPrank();
        assertGt(bought,0);assertEq(noer.balanceOf(operator),bought);assertEq(dollar.balanceOf(operator),300e6);
        uint256 beforeProtocol=dollar.balanceOf(operations);uint256 beforeAgent=dollar.balanceOf(vault.agentTreasury());uint256 beforeBuyback=dollar.balanceOf(operator);
        (uint256 fees,uint256 tokens)=market.collect();assertEq(fees,1750000);assertEq(tokens,0);
        assertEq(dollar.balanceOf(operations)-beforeProtocol,fees/2);assertEq(dollar.balanceOf(vault.agentTreasury())-beforeAgent,fees/10);
        assertEq(dollar.balanceOf(operator)-beforeBuyback,fees-fees/2-fees/10);assertEq(dollar.balanceOf(address(vault)),0);
    }
    function testOutsidersCannotWithdrawPrincipalOrChangeWallets() public {
        _fund(1000e6);
        vm.prank(outsider);vm.expectRevert();vault.receiveRevenue(1);
        (bool ok,)=address(vault).call(abi.encodeWithSignature("withdraw(address,uint256)",outsider,1));assertFalse(ok);
        (ok,)=address(market).call(abi.encodeWithSignature("withdraw(uint256)",1));assertFalse(ok);
        (ok,)=address(vault).call(abi.encodeWithSignature("setBuybackTreasury(address)",outsider));assertFalse(ok);
        market.collect();market.collect();assertEq(vault.totalRevenue(),1000e6);
    }
    function testThreeRecipientsMustBeDistinctAndNonzero() public {
        NoerraQuoter pinnedQuoter=vault.quoter();
        vm.expectRevert("Revenue authority");new NoerraEcosystemVault(dollar,noer,manager,pinnedQuoter,operations,address(0xA2),address(0));
        vm.expectRevert("Separate revenue authorities");new NoerraEcosystemVault(dollar,noer,manager,pinnedQuoter,operations,address(0xA2),operations);
        vm.expectRevert("Separate revenue authorities");new NoerraEcosystemVault(dollar,noer,manager,pinnedQuoter,operations,operator,operator);
    }
    function testTokenOnlyOneEthValuationAndNoUsdcSeed() public view {
        assertEq(market.initialValuation(),2000e6);assertEq(market.LAUNCH_FDV_ETH(),1 ether);
        assertEq(dollar.balanceOf(address(manager)),0);assertEq(dollar.balanceOf(address(market)),0);
        assertEq(noer.balanceOf(address(manager))+noer.balanceOf(address(market)),noer.totalSupply());
        assertEq(noer.balanceOf(address(this)),0);assertGt(market.lockedLiquidity(),0);
        assertEq(noer.protectionStartBlock(),market.launchBlock());assertEq(noer.protectionEndBlock(),market.launchBlock()+10);
    }
    function testFirstTenBlocksCapsWalletAndBuyWithoutClaimsBypass() public {
        vm.roll(market.launchBlock());
        dollar.mint(outsider,100e6);vm.startPrank(outsider);dollar.approve(address(market),100e6);
        vm.expectRevert();market.trade(true,70e6,1,block.timestamp+60);
        uint256 bought=market.trade(true,25e6,1,block.timestamp+60);assertGt(bought,0);assertLe(bought,20_000_000 ether);
        vm.expectRevert();market.trade(true,40e6,1,block.timestamp+60);vm.stopPrank();
        PoolSwapTest router=new PoolSwapTest(manager);dollar.mint(address(this),1e6);dollar.approve(address(router),1e6);
        PoolKey memory key=market.poolKey();bool direction=Currency.unwrap(key.currency0)==address(dollar);
        vm.expectRevert();router.swap(key,SwapParams(direction,-int256(1e6),direction?TickMath.MIN_SQRT_PRICE+1:TickMath.MAX_SQRT_PRICE-1),PoolSwapTest.TestSettings(true,false),"");
        assertEq(manager.balanceOf(address(this),uint160(address(noer))),0);
        vm.roll(market.launchBlock()+9);vm.prank(outsider);vm.expectRevert();market.trade(true,70e6,1,block.timestamp+60);
        vm.roll(market.launchBlock()+10);vm.prank(outsider);market.trade(true,50e6,1,block.timestamp+60);
        assertGt(noer.balanceOf(outsider),20_000_000 ether);
    }
    function testWalletTransferCapAndExactBoundaryThenExpiry() public {
        vm.roll(market.launchBlock());dollar.mint(outsider,100e6);
        vm.startPrank(outsider);dollar.approve(address(market),100e6);uint256 bought=market.trade(true,25e6,1,block.timestamp+60);
        noer.transfer(operations,bought);vm.stopPrank();
        dollar.mint(address(this),50e6);dollar.approve(address(market),50e6);market.trade(true,50e6,1,block.timestamp+60);
        uint256 exact=20_000_000 ether-bought;noer.transfer(operations,exact);assertEq(noer.balanceOf(operations),20_000_000 ether);
        vm.expectRevert("Launch max wallet");noer.transfer(operations,1);
        vm.roll(market.launchBlock()+10);noer.transfer(operations,1);assertEq(noer.balanceOf(operations),20_000_000 ether+1);
    }
    function testFreshOracleRequiredBeforeOneSidedLaunchAndReceiptUsesActualPrice() public {
        (NoerraEcosystemVault fresh,NoerraNoerMarket freshMarket,NoerraRevenueCoin freshCoin)=NoerraEcosystemFixture.deploy(manager,dollar,operations,operator);
        freshCoin.transfer(address(freshMarket),freshCoin.totalSupply());
        NoerraPlatformOracleFixture feed=NoerraPlatformOracleFixture(address(freshMarket.ethUsdFeed()));uint256 fullSupply=freshCoin.totalSupply();
        feed.set(0,block.timestamp);vm.expectRevert("Oracle round");freshMarket.initialize(fullSupply);
        vm.warp(block.timestamp+7201);vm.expectRevert("Oracle round");freshMarket.initialize(fullSupply);
        feed.set(2000e8,block.timestamp-7201);vm.expectRevert("Oracle freshness");freshMarket.initialize(fullSupply);
        feed.set(2500e8,block.timestamp);freshMarket.initialize(fullSupply);assertEq(freshMarket.initialValuation(),2500e6);
        assertEq(dollar.balanceOf(address(freshMarket)),0);assertEq(fresh.totalRevenue(),0);
    }
    function testTaxFreeTransfersAndFeeTokenConversionCannotSellPrincipal() public {
        dollar.mint(outsider, 100e6); vm.startPrank(outsider); dollar.approve(address(market), 100e6);
        uint256 bought = market.trade(true, 100e6, 1, block.timestamp + 60);
        noer.transfer(operations, bought / 4); assertEq(noer.balanceOf(operations), bought / 4);
        noer.approve(address(market), bought / 2); market.trade(false, bought / 2, 1, block.timestamp + 60); vm.stopPrank();
        (uint256 dollars, uint256 tokens) = market.collect(); assertGt(dollars, 0); assertEq(tokens, 0);
        uint256 fees = market.feeTokens(); assertEq(fees, 0);
        uint128 liquidity = market.lockedLiquidity();
        vm.prank(operator); vm.expectRevert("USDC fees only"); market.convertFees(fees + 1, 1, block.timestamp + 60);
        vm.prank(operator); vm.expectRevert("USDC fees only"); market.convertFees(fees, 1, block.timestamp + 60);
        assertEq(market.feeTokens(), 0); assertEq(market.lockedLiquidity(), liquidity);
    }
    function testOneShotBindingAndHookBlocksThirdPartyPoolInitialization() public {
        vm.prank(outsider); vm.expectRevert("One unfunded market binding"); vault.bindMarket(market);
        vm.expectRevert("One unfunded market binding"); vault.bindMarket(market);
        PoolKey memory key = market.poolKey();
        vm.expectRevert(); manager.initialize(key, uint160(1 << 96));
        NoerraNoerFeeHook hook = market.feeHook();
        vm.expectRevert("Canonical pool initialization"); hook.beforeInitialize(address(market), key, 1);
        uint256 supply = noer.totalSupply();
        vm.expectRevert("One bound launch"); market.initialize(supply);
    }
    function testFuzzRevenueAllocationDustAlwaysFunded(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6); _fund(amount);
        assertEq(vault.totalOperations(), amount * 50 / 100);
        assertEq(vault.totalBuybackFunding(), amount - amount * 50 / 100 - amount / 10);
        assertEq(dollar.balanceOf(operator),vault.totalBuybackFunding());assertEq(dollar.balanceOf(vault.agentTreasury()),amount/10);assertEq(dollar.balanceOf(address(vault)),0);
    }
    function testPredictedVaultAndMarketDonationsCannotGriefBindingOrSeedValuation() public {
        NoerraRevenueCoin freshCoin = new NoerraRevenueCoin(address(this));
        (NoerraAgentRegistry freshRegistry,bytes32 freshId,address freshAccount)=NoerraEcosystemFixture.prepareAccount(dollar);
        NoerraEcosystemVault fresh = new NoerraEcosystemVault(dollar, freshCoin, manager, vault.quoter(),
            operations, freshAccount, operator);
        dollar.mint(address(fresh), 1);
        NoerraNoerMarket freshMarket = NoerraEcosystemFixture.deployMarket(manager, dollar, freshCoin, fresh);
        PoolKey memory key = freshMarket.poolKey();
        vm.expectRevert(); manager.initialize(key, uint160(1 << 96));
        fresh.bindMarket(freshMarket);
        NoerraEcosystemFixture.bindAccount(fresh,freshRegistry,freshId);
        freshCoin.transfer(address(freshMarket), freshCoin.totalSupply());
        dollar.mint(address(freshMarket), 100_000e6 + 1);
        freshMarket.initialize(freshCoin.totalSupply());
        assertEq(fresh.totalRevenue(), 0); assertEq(fresh.totalBuybackFunding(), 0);
        assertEq(dollar.balanceOf(address(fresh)), 1);
        assertGe(dollar.balanceOf(address(freshMarket)), 1);
        freshMarket.collect(); assertEq(fresh.totalRevenue(), 0);
    }

    function _generic(PoolSwapTest router, bool buy, bool exactInput, uint256 amount, bool takeClaims)
        internal returns (BalanceDelta delta, uint256 gross, uint256 fee) {
        PoolKey memory key = market.poolKey();
        bool zeroForOne = Currency.unwrap(key.currency0) == (buy ? address(dollar) : address(noer));
        {
            IV4Quoter.QuoteExactSingleParams memory request=IV4Quoter.QuoteExactSingleParams(key,zeroForOne,uint128(amount),"");
            (uint256 quoted,)=exactInput?vault.quoter().quoteExactInputSingle(request):vault.quoter().quoteExactOutputSingle(request);
            vm.recordLogs();
            delta = router.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(takeClaims,false), "");
            int128 input=zeroForOne?delta.amount0():delta.amount1(); int128 output=zeroForOne?delta.amount1():delta.amount0();
            assertEq(exactInput?uint256(uint128(output)):uint256(-int256(input)),quoted);
        }
        (gross,fee)=_recordedFee();
        assertEq(fee,Math.mulDiv(gross,175,10000,Math.Rounding.Ceil));
        int128 cash = Currency.unwrap(key.currency0) == address(dollar) ? delta.amount0() : delta.amount1();
        assertEq(buy ? uint256(-int256(cash)) : uint256(uint128(cash)),buy ? gross : gross-fee);
        assertEq(manager.balanceOf(address(market.feeHook()),uint160(address(noer))),0);
    }
    function _recordedFee() internal returns(uint256 gross,uint256 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs(); uint256 found;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(market.feeHook())
            && logs[i].topics[0] == keccak256("SwapFee(bytes32,uint256,uint256)")) {
            (gross,fee) = abi.decode(logs[i].data,(uint256,uint256)); ++found;
        }
        assertEq(found,1);
    }
    function testGenericRoutersAllFourCasesPayOneGrossUsdcFeeAndNoTokenFee() public {
        _fourCases();
    }
    function _fourCases() internal {
        PoolSwapTest router = new PoolSwapTest(manager);
        dollar.mint(address(this),1000e6); dollar.approve(address(router),type(uint256).max);
        noer.approve(address(router),type(uint256).max);
        uint256 fees;
        (,uint256 gross,uint256 fee) = _generic(router,true,true,100e6,false);
        assertEq(gross,100e6); assertEq(fee,1750000); fees += fee;
        (BalanceDelta delta,,uint256 fee2) = _generic(router,true,false,100_000 ether,false);
        PoolKey memory key = market.poolKey();
        assertEq(Currency.unwrap(key.currency0)==address(noer)?delta.amount0():delta.amount1(),int128(100_000 ether)); fees += fee2;
        (,,uint256 fee3) = _generic(router,false,true,50_000 ether,false); fees += fee3;
        (,,uint256 fee4) = _generic(router,false,false,2e6,false); fees += fee4;
        assertEq(market.feeHook().accruedFees(key.toId()),fees);
        assertEq(manager.balanceOf(address(market.feeHook()),uint160(address(dollar))),fees);
        uint128 liquidity=market.lockedLiquidity(); (uint256 dollars,uint256 tokens)=market.collect();
        assertEq(dollars,fees); assertEq(tokens,0); assertEq(market.feeTokens(),0);
        assertEq(manager.balanceOf(address(market.feeHook()),uint160(address(dollar))),0);
        assertEq(market.feeHook().accruedFees(key.toId()),0); assertEq(market.lockedLiquidity(),liquidity);
        (dollars,tokens)=market.collect(); assertEq(dollars,0); assertEq(tokens,0);
    }
    function testAllFourFeeCasesAndQuotesAlsoWorkWithOppositeCurrencyOrder() public {
        _useOppositeMarket();vm.roll(block.number+10);_fourCases();
    }
    function testLaunchBuyAndSellTaxWorksWithOppositeCurrencyOrder() public {
        _useOppositeMarket();assertEq(market.feeHook().feeBps(),2500);
        dollar.mint(outsider,10e6);vm.startPrank(outsider);dollar.approve(address(market),10e6);vm.recordLogs();
        uint256 tokens=market.trade(true,10e6,1,block.timestamp+120);vm.stopPrank();
        (uint256 gross,uint256 fee)=_recordedFee();assertEq(gross,10e6);assertEq(fee,2500000);
        vm.startPrank(outsider);noer.approve(address(market),tokens);vm.recordLogs();
        uint256 dollars=market.trade(false,tokens,1,block.timestamp+120);vm.stopPrank();
        (gross,fee)=_recordedFee();assertEq(fee,Math.mulDiv(gross,2500,10000,Math.Rounding.Ceil));assertEq(dollars,gross-fee);
        vm.roll(market.launchBlock()+10);assertEq(market.feeHook().feeBps(),175);
    }
    function _useOppositeMarket() internal {
        bool original=address(noer)<address(dollar); NoerraRevenueCoin fresh;
        for(uint256 i;i<128;++i) {
            fresh=new NoerraRevenueCoin(address(this));
            if((address(fresh)<address(dollar))!=original)break;
        }
        assertTrue((address(fresh)<address(dollar))!=original,"Opposite order exercised");
        noer=fresh; NoerraQuoter quoter=new NoerraQuoter(manager);
        (NoerraAgentRegistry freshRegistry,bytes32 freshId,address freshAccount)=NoerraEcosystemFixture.prepareAccount(dollar);
        vault=new NoerraEcosystemVault(dollar,noer,manager,quoter,operations,freshAccount,operator);
        market=NoerraEcosystemFixture.deployMarket(manager,dollar,noer,vault); vault.bindMarket(market);
        NoerraEcosystemFixture.bindAccount(vault,freshRegistry,freshId);
        noer.transfer(address(market),noer.totalSupply());
        market.initialize(noer.totalSupply());
    }
    function testFuzzGrossUsdcFeeRoundingMatchesActualSettlement(uint256 amount) public {
        amount=bound(amount,2,1000e6);PoolSwapTest router=new PoolSwapTest(manager);
        dollar.mint(address(this),amount);dollar.approve(address(router),amount);
        (,uint256 gross,uint256 fee)=_generic(router,true,true,amount,false);
        assertEq(gross,amount);assertEq(fee,Math.mulDiv(amount,175,10000,Math.Rounding.Ceil));
        (uint256 dollars,uint256 tokens)=market.collect();assertEq(dollars,fee);assertEq(tokens,0);
    }
    function testExternalProtocolFeeDoesNotChangeNoerraFeeCurrencyOrBlockTrading() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(market.poolKey(),uint24(100|(100<<12)));
        _fourCases();
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(dollar))),0);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(noer))),0);
        // These externally enabled protocol costs are separate from Noerra's single USDC fee.
        assertEq(manager.balanceOf(address(market.feeHook()),uint160(address(noer))),0);
    }
    function testGenericClaimOutputStillPaysFeeAndOutsiderCannotFlushClaims() public {
        PoolSwapTest router=new PoolSwapTest(manager); dollar.mint(address(this),100e6);
        dollar.approve(address(router),type(uint256).max);
        (BalanceDelta delta,,uint256 fee)=_generic(router,true,true,100e6,true);
        PoolKey memory key=market.poolKey();
        uint256 output=uint256(uint128(Currency.unwrap(key.currency0)==address(noer)?delta.amount0():delta.amount1()));
        assertEq(manager.balanceOf(address(this),uint160(address(noer))),output);
        assertEq(market.feeHook().accruedFees(key.toId()),fee);
        NoerraNoerFeeHook hook=market.feeHook();
        vm.expectRevert("Fee locker only"); hook.withdrawFees(key);
        (uint256 dollars,)=market.collect(); assertEq(dollars,fee);
    }
    function testSpecifiedUsdcPartialPriceLimitRevertsWithoutFeeOrPrincipalChanges() public {
        PoolSwapTest router=new PoolSwapTest(manager); dollar.mint(address(this),1000e6);
        dollar.approve(address(router),type(uint256).max);
        PoolKey memory key=market.poolKey(); bool direction=Currency.unwrap(key.currency0)==address(dollar);
        (uint160 price,,,)=manager.getSlot0(key.toId()); uint256 beforeDollar=dollar.balanceOf(address(this));
        uint256 beforeManagerDollar=dollar.balanceOf(address(manager));
        vm.expectRevert(); router.swap(key,SwapParams(direction,-int256(100e6),direction?price-1:price+1),
            PoolSwapTest.TestSettings(false,false),"");
        assertEq(dollar.balanceOf(address(this)),beforeDollar); assertEq(dollar.balanceOf(address(manager)),beforeManagerDollar);
        assertEq(market.feeHook().accruedFees(key.toId()),0);
        assertEq(manager.balanceOf(address(market.feeHook()),uint160(address(dollar))),0);
        // Exact-output USDC sell must likewise deliver all requested net cash, not a partial output.
        _generic(router,true,true,100e6,false); noer.approve(address(router),type(uint256).max);
        (price,,,)=manager.getSlot0(key.toId()); direction=!direction;
        uint256 accrued=market.feeHook().accruedFees(key.toId());
        vm.expectRevert(); router.swap(key,SwapParams(direction,int256(2e6),direction?price-1:price+1),
            PoolSwapTest.TestSettings(false,false),"");
        assertEq(market.feeHook().accruedFees(key.toId()),accrued);
    }
    function testTokenLpDonationCannotBecomeTradingFeeOrBlockUsdcClaimCollection() public {
        dollar.mint(address(this),100e6); dollar.approve(address(market),100e6);
        uint256 bought=market.trade(true,100e6,1,block.timestamp+60);
        PoolDonateTest donor=new PoolDonateTest(manager); noer.approve(address(donor),bought/4);
        PoolKey memory key=market.poolKey(); bool first=Currency.unwrap(key.currency0)==address(noer);
        donor.donate(key,first?bought/4:0,first?0:bought/4,"");
        uint128 liquidity=market.lockedLiquidity(); (uint256 dollars,uint256 tokens)=market.collect();
        assertEq(dollars,1750000); assertEq(tokens,0); assertEq(market.feeTokens(),0);
        assertEq(market.lockedLiquidity(),liquidity); (dollars,tokens)=market.collect();assertEq(dollars,0);assertEq(tokens,0);
    }
}
