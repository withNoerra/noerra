// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAgentRegistry} from "../src/agents/NoerraAgents.sol";
import {NoerraCrosschainReinvestment, INoerraEarnedComputeMarket} from "../src/agents/NoerraCrosschainReinvestment.sol";

contract ReinvestmentDollar is ERC20 {
    address public blocked;
    constructor() ERC20("Fixture dollar", "USD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function blockRecipient(address who) external {
        blocked = who;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(blocked == address(0) || to != blocked, "Recipient blocked");
        super._update(from, to, amount);
    }
}

contract ReinvestmentRegistry is IAgentRegistry {
    mapping(bytes32 => address) public accounts;

    function set(bytes32 id, address account) external {
        accounts[id] = account;
    }
}

contract EarnedMarketFixture {
    IERC20 public dollar;
    IAgentRegistry public registry;
    address public computeTreasury;

    constructor(IERC20 dollar_, IAgentRegistry registry_) {
        dollar = dollar_;
        registry = registry_;
    }

    function bind(address value) external {
        computeTreasury = value;
    }
}

contract HostingFixture {}

contract NoerraCrosschainReinvestmentTest is Test {
    ReinvestmentDollar dollar;
    ReinvestmentRegistry registry;
    EarnedMarketFixture market;
    NoerraCrosschainReinvestment treasury;
    address hosting;
    address keeper = address(0xBEEF);
    bytes32 id = keccak256("capacity");

    function setUp() public {
        dollar = new ReinvestmentDollar();
        registry = new ReinvestmentRegistry();
        hosting = address(new HostingFixture());
        registry.set(id, hosting);
        market = new EarnedMarketFixture(dollar, registry);
        treasury = new NoerraCrosschainReinvestment(
            dollar, registry, INoerraEarnedComputeMarket(address(market)), id, hosting, keeper, 50e6, 100e6, 200e6
        );
        market.bind(address(treasury));
        dollar.mint(address(treasury), 500e6);
    }

    function testFuzzConservationAndFixedDestinations(uint256 amount) public {
        amount = bound(amount, 1e6, 100e6);
        vm.prank(keeper);
        (uint256 nonce, uint256 bridge, uint256 host) = treasury.disburseBatch(amount);
        assertEq(nonce, 1);
        assertEq(host, amount * 30 / 100);
        assertEq(bridge, amount - host);
        assertEq(dollar.balanceOf(hosting), host);
        assertEq(dollar.balanceOf(keeper), bridge);
        assertEq(dollar.balanceOf(address(treasury)) + bridge + host, 500e6);
        assertEq(treasury.spentToday(), amount);
        assertEq(treasury.computeEarnings(), 500e6 - amount);
        assertEq(treasury.provider(), keeper);
        assertEq(treasury.payment(), address(dollar));
    }

    function testKeeperOnlyAndNoArbitraryDestination() public {
        vm.expectRevert("Dedicated keeper only");
        treasury.disburseBatch(1e6);
        assertEq(treasury.batchNonce(), 0);
    }

    function testReserveAndMinimumPreserved() public {
        dollar.burn(address(treasury), 449e6);
        vm.startPrank(keeper);
        vm.expectRevert("Funded batch");
        treasury.disburseBatch(1e6 - 1);
        vm.expectRevert("Funded batch");
        treasury.disburseBatch(1e6 + 1);
        treasury.disburseBatch(1e6);
        vm.stopPrank();
        assertEq(dollar.balanceOf(address(treasury)), 50e6);
    }

    function testDailyCapResetAndMonotonicNonce() public {
        vm.startPrank(keeper);
        treasury.disburseBatch(100e6);
        treasury.disburseBatch(100e6);
        vm.expectRevert("Daily purchase limit");
        treasury.disburseBatch(1e6);
        vm.warp(block.timestamp + 1 days);
        treasury.disburseBatch(100e6);
        vm.stopPrank();
        assertEq(treasury.batchNonce(), 3);
        assertEq(treasury.spentToday(), 100e6);
    }

    function testSecondTransferFailureRollsBackBothAndNonce() public {
        dollar.blockRecipient(keeper);
        vm.prank(keeper);
        vm.expectRevert("Recipient blocked");
        treasury.disburseBatch(10e6);
        assertEq(dollar.balanceOf(hosting), 0);
        assertEq(dollar.balanceOf(address(treasury)), 500e6);
        assertEq(treasury.batchNonce(), 0);
        assertEq(treasury.spentToday(), 0);
    }

    function testMarketAndRegistryBindingFailClosed() public {
        market.bind(address(0));
        vm.prank(keeper);
        vm.expectRevert("Earned market wiring");
        treasury.disburseBatch(1e6);
        market.bind(address(treasury));
        registry.set(id, address(0x123));
        vm.prank(keeper);
        vm.expectRevert("Capacity agent changed");
        treasury.disburseBatch(1e6);
    }
}
