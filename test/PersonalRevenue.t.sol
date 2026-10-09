// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraRevenuePool} from "../src/personal/NoerraRevenuePool.sol";

contract RejectRevenue {
    NoerraRevenuePool public pool;

    constructor(NoerraRevenuePool pool_) {
        pool = pool_;
    }

    function enter(IERC20 coin) external {
        coin.approve(address(pool), 10 ether);
        pool.stake(10 ether);
    }

    function claim() external {
        pool.claim();
    }

    function exit() external {
        pool.unstake(10 ether);
    }

    receive() external payable {
        revert();
    }
}

contract ReenterRevenue {
    NoerraRevenuePool public immutable pool;
    bool public nestedClaimSucceeded;
    bool public nestedExitSucceeded;
    constructor(NoerraRevenuePool pool_) { pool = pool_; }
    function enter(IERC20 coin) external { coin.approve(address(pool), 10 ether); pool.stake(10 ether); }
    function claim() external { pool.claim(); }
    receive() external payable {
        (nestedClaimSucceeded,) = address(pool).call(abi.encodeCall(pool.claim, ()));
        (nestedExitSucceeded,) = address(pool).call(abi.encodeCall(pool.unstake, (10 ether)));
    }
}

contract PersonalRevenueTest is Test {
    NoerraRevenueCoin coin;
    NoerraRevenuePool pool;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        coin = new NoerraRevenueCoin(address(this));
        pool = new NoerraRevenuePool(coin, treasury);
        coin.transfer(alice, 100 ether);
        coin.transfer(bob, 100 ether);
        vm.prank(alice);
        coin.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        coin.approve(address(pool), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function testSingleFixedSupplyCoinAndNoTransferTax() public view {
        assertEq(coin.totalSupply(), 1_000_000_000 ether);
        assertEq(coin.balanceOf(alice), 100 ether);
        assertEq(coin.symbol(), "NOERRA");
    }

    function testRevenueOnlyAccruesWhenActuallyDeposited() public {
        vm.prank(alice);
        pool.stake(10 ether);
        assertEq(pool.earned(alice), 0);
        pool.depositRevenue{value: 1 ether}(keccak256("synthetic service invoice"));
        assertEq(pool.earned(alice), 1 ether);
        vm.prank(alice);
        pool.claim();
        assertEq(alice.balance, 1 ether);
        assertEq(pool.totalClaimed(), 1 ether);
        vm.prank(alice);
        pool.claim();
        assertEq(alice.balance, 1 ether);
    }

    function testLateStakerCannotCaptureEarlierRevenueAndPrincipalAlwaysWithdraws() public {
        vm.prank(alice);
        pool.stake(10 ether);
        pool.depositRevenue{value: 1 ether}(bytes32(0));
        vm.prank(bob);
        pool.stake(10 ether);
        assertEq(pool.earned(bob), 0);
        pool.depositRevenue{value: 2 ether}(bytes32(0));
        assertEq(pool.earned(alice), 2 ether);
        assertEq(pool.earned(bob), 1 ether);
        vm.prank(alice);
        pool.unstake(10 ether);
        assertEq(coin.balanceOf(alice), 100 ether);
        assertEq(pool.earned(alice), 2 ether);
        vm.prank(alice);
        pool.claim();
        assertEq(alice.balance, 2 ether);
    }

    function testEmptyPoolRevenueDoesNotBecomeFirstStakerWindfall() public {
        pool.depositRevenue{value: 1 ether}(bytes32(0));
        vm.prank(alice);
        pool.stake(10 ether);
        assertEq(pool.earned(alice), 0);
        vm.expectRevert(NoerraRevenuePool.InvalidConfiguration.selector);
        pool.claimTreasury();
        vm.prank(treasury);
        pool.claimTreasury();
        assertEq(treasury.balance, 1 ether);
    }

    function testRejectedPayoutNeverBlocksTokenPrincipalAndDoesNotLoseCredit() public {
        RejectRevenue reject = new RejectRevenue(pool);
        coin.transfer(address(reject), 10 ether);
        reject.enter(coin);
        pool.depositRevenue{value: 1 ether}(bytes32(0));
        vm.expectRevert(NoerraRevenuePool.TransferFailed.selector);
        reject.claim();
        assertEq(pool.earned(address(reject)), 1 ether);
        reject.exit();
        assertEq(coin.balanceOf(address(reject)), 10 ether);
    }

    function testFuzzRevenueCannotPayMoreThanReceived(uint96 aliceStake, uint96 bobStake, uint96 revenue) public {
        uint256 a = bound(aliceStake, 1, 100 ether);
        uint256 b = bound(bobStake, 1, 100 ether);
        uint256 income = bound(revenue, 1, 50 ether);
        vm.prank(alice);
        pool.stake(a);
        vm.prank(bob);
        pool.stake(b);
        pool.depositRevenue{value: income}(bytes32(0));
        assertLe(pool.earned(alice) + pool.earned(bob), income);
        vm.prank(alice);
        pool.claim();
        vm.prank(bob);
        pool.claim();
        assertLe(pool.totalClaimed(), pool.totalDeposited());
        vm.prank(alice);
        pool.unstake(a);
        vm.prank(bob);
        pool.unstake(b);
        assertEq(pool.totalStaked(), 0);
        assertEq(coin.balanceOf(address(pool)), 0);
        assertEq(address(pool).balance + pool.totalClaimed(), pool.totalDeposited());
    }

    function testPayoutCallbackCannotReenterClaimOrPrincipalExit() public {
        ReenterRevenue attacker = new ReenterRevenue(pool);
        coin.transfer(address(attacker), 10 ether);
        attacker.enter(coin);
        pool.depositRevenue{value: 1 ether}(bytes32(0));
        attacker.claim();
        assertFalse(attacker.nestedClaimSucceeded());
        assertFalse(attacker.nestedExitSucceeded());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(pool.staked(address(attacker)), 10 ether);
        assertEq(pool.earned(address(attacker)), 0);
        assertEq(pool.totalClaimed(), 1 ether);
    }

    function testFuzzMixedStakeExitDepositAndClaimRemainSolvent(uint256 seed) public {
        for (uint256 i; i < 64; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = seed & 1 == 0 ? alice : bob;
            uint256 action = (seed >> 1) % 4;
            uint256 amount = 1 + (seed >> 4) % 1 ether;
            if (action == 0 && coin.balanceOf(actor) >= amount) {
                vm.prank(actor); pool.stake(amount);
            } else if (action == 1 && pool.staked(actor) > 0) {
                amount = bound(amount, 1, pool.staked(actor));
                vm.prank(actor); pool.unstake(amount);
            } else if (action == 2) {
                pool.depositRevenue{value: amount}(bytes32(seed));
            } else if (action == 3) {
                vm.prank(actor); pool.claim();
            }
            assertEq(pool.totalStaked(), pool.staked(alice) + pool.staked(bob));
            assertEq(coin.balanceOf(address(pool)), pool.totalStaked());
            assertLe(pool.earned(alice) + pool.earned(bob) + pool.treasuryCredit(), address(pool).balance);
            assertEq(pool.totalClaimed() + address(pool).balance, pool.totalDeposited());
        }
        uint256 remainingAlice = pool.staked(alice);
        uint256 remainingBob = pool.staked(bob);
        if (remainingAlice != 0) { vm.prank(alice); pool.unstake(remainingAlice); }
        if (remainingBob != 0) { vm.prank(bob); pool.unstake(remainingBob); }
        assertEq(coin.balanceOf(alice), 100 ether);
        assertEq(coin.balanceOf(bob), 100 ether);
    }
}
