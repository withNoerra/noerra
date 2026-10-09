// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraAgentRegistry, NoerraAgentAccount, NoerraAgentCredits, IAgentRegistry, IAgentRecoveryVerifier} from "../src/agents/NoerraAgents.sol";
import {NoerraAgentLaunchpad, NoerraLockedCreation, NoerraBackers} from "../src/agents/NoerraLaunchpad.sol";

contract LaunchDollar is ERC20 {
    constructor() ERC20("Dollar", "USD") {}
    function decimals() public pure override returns(uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract NoerraLaunchpadTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    LaunchDollar dollar;
    NoerraAgentRegistry registry;
    NoerraAgentCredits credits;
    NoerraAgentLaunchpad launchpad;
    NoerraLockedCreation locker;
    PoolManager manager;
    bytes32 agentId;
    address account;
    address human = address(0xa1);
    address trader = address(0xb1);
    address runtime = address(0xc1);
    address protocol = address(0xd1);
    address noer = address(0xe1);

    function setUp() public {
        dollar = new LaunchDollar(); manager = new PoolManager(address(this));
        registry = new NoerraAgentRegistry(dollar, IAgentRecoveryVerifier(address(0)));
        credits = new NoerraAgentCredits(dollar, IAgentRegistry(address(registry)), address(0));
        launchpad = new NoerraAgentLaunchpad(registry, credits, manager, protocol, noer);
        dollar.mint(human, 10000e6); dollar.mint(trader, 10000e6);
        vm.startPrank(human);
        (agentId, account) = registry.create(runtime, keccak256("metadata"), keccak256("build"), 5e6, 10e6, "", "");
        dollar.approve(address(launchpad), 1000e6);
        locker = launchpad.launch(agentId, "Fieldnotes", "NOTES", 1000e6);
        vm.stopPrank();
    }

    function _buy(uint256 amount) internal returns(uint256 bought) {
        vm.startPrank(trader); dollar.approve(address(locker), amount);
        bought = locker.trade(true, amount, 1, block.timestamp + 60); vm.stopPrank();
    }

    function _liquidity() internal view returns(uint128) {
        (Currency c0,Currency c1,uint24 fee,int24 spacing,IHooks hook) = locker.pool();
        PoolKey memory key = PoolKey({currency0:c0,currency1:c1,fee:fee,tickSpacing:spacing,hooks:hook});
        return IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    function testEntireSupplyLockedAndRealBuySell() public {
        IERC20 token = locker.token();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(human), 0); assertEq(token.balanceOf(account), 0);
        assertGt(locker.lockedLiquidity(), 0); assertEq(_liquidity(), locker.lockedLiquidity());
        uint256 bought = _buy(100e6); assertGt(bought, 0);
        vm.startPrank(trader); token.approve(address(locker), bought);
        uint256 sold = locker.trade(false, bought, 1, block.timestamp + 60); vm.stopPrank();
        assertGt(sold, 0); assertLt(sold, 100e6);
        uint128 liquidity = locker.lockedLiquidity(); locker.collect();
        assertEq(_liquidity(), liquidity); assertEq(locker.lockedLiquidity(), liquidity);
        assertGt(dollar.balanceOf(account), 0); assertEq(credits.balanceOf(account), 0);
        assertGt(dollar.balanceOf(protocol), 0); assertGt(dollar.balanceOf(noer), 0);
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply());
        assertGt(locker.feeTokens(), 0);
    }

    function testBackersOnlyReceiveActualFundedCredits() public {
        uint256 bought = _buy(100e6); NoerraBackers backers = locker.backers();
        vm.startPrank(trader); locker.token().approve(address(backers), bought);
        backers.back(bought); vm.expectRevert("Soulbound"); backers.transfer(human, 1); vm.stopPrank();
        locker.collect();
        uint256 pending = backers.pending(trader); assertGt(pending, 0);
        vm.prank(trader); uint256 claimed = backers.claim(); assertEq(claimed, pending);
        assertEq(credits.balanceOf(trader), pending);
        vm.prank(trader); credits.activate(agentId, pending);
        assertEq(credits.balanceOf(trader), 0);
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply());
        assertEq(_liquidity(), locker.lockedLiquidity());
    }

    function testFeeConversionCannotSellPrincipal() public {
        uint256 bought = _buy(100e6);
        vm.startPrank(trader); locker.token().approve(address(locker), bought);
        locker.trade(false, bought / 2, 1, block.timestamp + 60); vm.stopPrank();
        locker.collect(); uint256 fees = locker.feeTokens(); assertGt(fees, 0);
        vm.expectRevert("Agent policy"); locker.convertFees(fees, 1, block.timestamp + 60);
        vm.prank(runtime); vm.expectRevert("Fee bounds"); locker.convertFees(fees + 1, 1, block.timestamp + 60);
        vm.prank(runtime); uint256 received = locker.convertFees(fees, 1, block.timestamp + 60);
        assertGt(received, 0); assertEq(locker.feeTokens(), 0); assertEq(_liquidity(), locker.lockedLiquidity());
    }

    function testSlippageDeadlineOwnershipAndCallback() public {
        vm.startPrank(trader); dollar.approve(address(locker), 10e6);
        vm.expectRevert("Slippage"); locker.trade(true, 10e6, type(uint128).max, block.timestamp + 60);
        vm.expectRevert("Fresh deadline"); locker.trade(true, 10e6, 1, block.timestamp + 1 days);
        vm.expectRevert("Agent human only"); launchpad.launch(agentId, "Copy", "COPY", 1000e6); vm.stopPrank();
        vm.prank(human); vm.expectRevert("One creation token"); launchpad.launch(agentId, "Copy", "COPY", 1000e6);
        vm.expectRevert("Manager callback"); locker.unlockCallback(abi.encode(uint8(1), false, uint256(0), human));
        // There is no method that can decrease liquidity, rescue tokens, or replace the manager.
        vm.prank(human); (bool ok,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256)", 1)); assertFalse(ok);
    }

    function testFuzzFeeRoutingAndLockedPrincipal(uint256 input) public {
        input = bound(input, 1e6, 5000e6);
        uint256 bought = _buy(input);
        vm.startPrank(trader); locker.token().approve(address(locker), bought);
        locker.trade(false, bought / 2, 1, block.timestamp + 60); vm.stopPrank();
        uint128 liquidity = locker.lockedLiquidity();
        (uint256 collected,) = locker.collect();
        assertEq(dollar.balanceOf(account), collected * 20 / 100 * 2);
        assertEq(credits.balanceOf(account), 0);
        assertEq(dollar.balanceOf(protocol), collected * 20 / 100);
        assertEq(dollar.balanceOf(noer), collected - collected * 20 / 100 * 3 - collected * 30 / 100);
        assertEq(dollar.balanceOf(address(credits)), credits.totalSupply());
        assertEq(_liquidity(), liquidity);
    }
    function testOwnTreasuryCreditsCannotBeRedirected() public {
        vm.startPrank(trader); dollar.approve(address(credits), 5e6); credits.mint(5e6, account); vm.stopPrank();
        uint256 before = dollar.balanceOf(trader);
        vm.prank(trader); credits.activateAccount(agentId, 5e6);
        assertEq(dollar.balanceOf(account), 5e6); assertEq(dollar.balanceOf(trader), before);
        assertEq(credits.balanceOf(account), 0); assertEq(credits.totalSupply(), 0);
        vm.prank(trader); vm.expectRevert(); credits.activateAccount(agentId, 1);
    }
}
