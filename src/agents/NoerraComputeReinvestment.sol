// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {NoerraDiem} from "./NoerraDiem.sol";

interface IReinvestmentRouter {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata) external payable returns (uint256);
}
interface IReinvestmentPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
}
interface IReinvestmentFactory { function getPool(address,address,uint24) external view returns(address); }

/// @notice Destination for earned compute-market proceeds only. Anyone may turn
///         fees into permanently locked DIEM and hosting cash under immutable
///         price, reserve and daily limits. Never accesses NCC refund backing.
contract NoerraComputeReinvestment is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable dollar;
    IERC20 public immutable diem;
    address public immutable intermediate;
    NoerraDiem public immutable wrapper;
    bytes32 public immutable agentId;
    address public immutable hostingTreasury;
    IReinvestmentRouter public immutable router;
    IReinvestmentPool public immutable first;
    IReinvestmentPool public immutable second;
    bytes32 public immutable routerCodeHash;
    uint256 public immutable reserve;
    uint256 public immutable maximumBatch;
    uint256 public immutable dailyLimit;
    uint32 public constant TWAP_WINDOW = 1800;
    uint256 public constant SLIPPAGE_BPS = 100;
    uint256 public spentDay;
    uint256 public spentToday;
    event Reinvested(uint256 dollars, uint256 hostingDollars, uint256 lockedDiem);

    struct Route { IERC20 dollar; IERC20 diem; address intermediate; IReinvestmentRouter router; IReinvestmentPool first; IReinvestmentPool second; }
    constructor(NoerraDiem wrapper_, bytes32 id, address hosting, Route memory route, uint256 reserve_, uint256 batch, uint256 daily) {
        require(hosting != address(0) && wrapper_.registry().accounts(id) == hosting, "Registered capacity agent");
        require(address(wrapper_.diem()) == address(route.diem) && address(route.dollar) != address(route.diem), "Asset wiring");
        require(address(route.router).code.length > 0 && address(route.first).code.length > 0 && address(route.second).code.length > 0, "Deployed route");
        require(reserve_ > 0 && batch >= 1e6 && batch <= 1000e6 && daily >= batch && daily <= 10000e6, "Finite purchase limits");
        dollar = route.dollar; diem = route.diem; intermediate = route.intermediate; router = route.router;
        first = route.first; second = route.second; wrapper = wrapper_; agentId = id; hostingTreasury = hosting;
        reserve = reserve_; maximumBatch = batch; dailyLimit = daily; routerCodeHash = address(route.router).codehash;
        _pool(first, address(dollar), intermediate, 500); _pool(second, intermediate, address(diem), 10000);
        address factory = first.factory();
        require(factory.code.length > 0 && second.factory() == factory
            && IReinvestmentFactory(factory).getPool(address(dollar), intermediate, 500) == address(first)
            && IReinvestmentFactory(factory).getPool(intermediate, address(diem), 10000) == address(second), "Canonical pools");
    }
    function _pool(IReinvestmentPool pool, address a, address b, uint24 fee) private view {
        require(pool.fee() == fee && (pool.token0() == a && pool.token1() == b || pool.token0() == b && pool.token1() == a), "Pool wiring");
    }
    function _quote(IReinvestmentPool pool, address input, uint256 amount) private view returns (uint256) {
        uint32[] memory times = new uint32[](2); times[0] = TWAP_WINDOW;
        (int56[] memory ticks,) = pool.observe(times); require(ticks.length == 2, "Oracle unavailable");
        int56 delta = ticks[1] - ticks[0]; int56 mean = delta / int56(uint56(TWAP_WINDOW));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) mean--;
        require(mean >= TickMath.MIN_TICK && mean <= TickMath.MAX_TICK, "Oracle tick");
        uint160 sqrt = TickMath.getSqrtPriceAtTick(int24(mean));
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            return input == pool.token0() ? Math.mulDiv(amount, ratio, 1 << 192) : Math.mulDiv(amount, 1 << 192, ratio);
        }
        uint256 ratio128 = Math.mulDiv(sqrt, sqrt, 1 << 64);
        return input == pool.token0() ? Math.mulDiv(amount, ratio128, 1 << 128) : Math.mulDiv(amount, 1 << 128, ratio128);
    }
    function minimumOutput(uint256 amount) public view returns (uint256) {
        uint256 swapAmount = amount - amount * 30 / 100;
        return Math.mulDiv(_quote(second, intermediate, _quote(first, address(dollar), swapAmount)), 10000 - SLIPPAGE_BPS, 10000);
    }
    function invest(uint256 amount, uint256 minimum, uint256 deadline) external nonReentrant {
        require(block.timestamp <= deadline && deadline <= block.timestamp + 120, "Fresh deadline");
        require(address(router).codehash == routerCodeHash, "Router changed");
        require(amount >= 1e6 && amount <= maximumBatch && dollar.balanceOf(address(this)) >= reserve + amount, "Funded batch");
        uint256 floor = minimumOutput(amount); require(floor > 0 && minimum >= floor, "TWAP price floor");
        uint256 today = block.timestamp / 1 days;
        if (today != spentDay) { spentDay = today; spentToday = 0; }
        require(spentToday + amount <= dailyLimit, "Daily purchase limit"); spentToday += amount;
        uint256 hosting = amount * 30 / 100; uint256 swapAmount = amount - hosting;
        uint256 beforeBalance = diem.balanceOf(address(this));
        dollar.forceApprove(address(router), swapAmount);
        router.exactInput(IReinvestmentRouter.ExactInputParams(abi.encodePacked(address(dollar), uint24(500), intermediate, uint24(10000), address(diem)), address(this), swapAmount, minimum));
        dollar.forceApprove(address(router), 0);
        uint256 bought = diem.balanceOf(address(this)) - beforeBalance; require(bought >= minimum, "Actual DIEM delivery");
        diem.forceApprove(address(wrapper), bought); wrapper.wrap(bought, address(this)); diem.forceApprove(address(wrapper), 0);
        wrapper.lockFor(agentId, bought); wrapper.reconcile(agentId);
        dollar.safeTransfer(hostingTreasury, hosting);
        emit Reinvested(amount, hosting, bought);
    }
}
