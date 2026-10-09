// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "./NoerraAgents.sol";

interface INoerraExactOutputRouter {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function refundETH() external payable;
    function WETH9() external view returns (address);
}

/// @notice One bounded ETH payment buys exact Ethereum USDC into the owner's registered agent.
/// @dev It does not attest Base funding, token delivery, inference, hosting or runtime activation.
/// Router, WETH, USDC and their proxy dependencies require independent reviewed deployment pins.
contract NoerraEthCheckout is ReentrancyGuard {
    using SafeERC20 for IERC20;
    NoerraAgentRegistry public immutable registry;
    IERC20 public immutable dollar;
    INoerraExactOutputRouter public immutable router;
    address public immutable weth;
    uint24 public constant poolFee = 500;
    uint256 public operationNonce;
    event BudgetFunded(
        uint256 indexed nonce,
        bytes32 indexed agentId,
        address indexed human,
        address account,
        uint256 dollars,
        uint256 ethSpent,
        uint256 ethRefunded
    );

    constructor(NoerraAgentRegistry registry_, INoerraExactOutputRouter router_, address weth_) {
        require(
            address(registry_).code.length > 0 && address(router_).code.length > 0 && weth_.code.length > 0,
            "Ethereum checkout pins"
        );
        require(router_.WETH9() == weth_ && address(registry_.dollar()).code.length > 0, "Ethereum swap wiring");
        registry = registry_;
        dollar = registry_.dollar();
        router = router_;
        weth = weth_;
    }

    receive() external payable {
        require(msg.sender == address(router), "Router refund only");
    }

    function fund(bytes32 id, uint256 exactDollars, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 spent, uint256 refunded)
    {
        address account = registry.accounts(id);
        require(account != address(0) && NoerraAgentAccount(account).human() == msg.sender, "Agent human only");
        require(
            msg.value > 0 && msg.value <= 10 ether && exactDollars >= 1e6 && exactDollars <= 100_000e6, "Budget bounds"
        );
        require(block.timestamp <= deadline && deadline <= block.timestamp + 5 minutes, "Fresh deadline");
        uint256 originalEth = address(this).balance - msg.value;
        uint256 beforeDollar = dollar.balanceOf(address(this));
        spent = router.exactOutputSingle{value: msg.value}(
            INoerraExactOutputRouter.ExactOutputSingleParams(
                weth, address(dollar), poolFee, address(this), exactDollars, msg.value, 0
            )
        );
        require(
            spent <= msg.value && dollar.balanceOf(address(this)) - beforeDollar == exactDollars,
            "Exact purchased budget"
        );
        router.refundETH();
        refunded = address(this).balance - originalEth;
        require(refunded >= msg.value - spent, "Complete router refund");
        uint256 nonce = ++operationNonce;
        uint256 beforeAccount = dollar.balanceOf(account);
        dollar.safeTransfer(account, exactDollars);
        require(dollar.balanceOf(account) - beforeAccount == exactDollars, "Exact account funding");
        if (refunded > 0) {
            (bool ok,) = msg.sender.call{value: refunded}("");
            require(ok, "Owner refund");
        }
        emit BudgetFunded(nonce, id, msg.sender, account, exactDollars, spent, refunded);
    }
}
