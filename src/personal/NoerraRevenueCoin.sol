// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
interface INoerraTokenMarket {
    function token() external view returns(address);
    function manager() external view returns(address);
    function deployer() external view returns(address);
    function launchExecutor() external view returns(address);
}

/// @notice One fixed-supply protocol coin. Private workspaces never mint a coin.
contract NoerraRevenueCoin is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant MAX_LAUNCH_HOLDING = 20_000_000 ether;
    uint256 public constant LAUNCH_PROTECTION_BLOCKS = 10;
    address public immutable launchAuthority;
    address public launchMarket;
    address public launchPoolManager;
    uint256 public protectionStartBlock;
    uint256 public protectionEndBlock;

    error InvalidRecipient();

    constructor(address supplyRecipient) ERC20("Noerra", "NOERRA") {
        if (supplyRecipient == address(0)) revert InvalidRecipient();
        launchAuthority = supplyRecipient;
        _mint(supplyRecipient, SUPPLY);
    }
    function configureLaunchProtection(address market, address manager) external {
        require(msg.sender == launchAuthority && launchMarket == address(0), "One launch market");
        require(market.code.length > 0 && manager.code.length > 0
            && INoerraTokenMarket(market).token() == address(this) && INoerraTokenMarket(market).manager() == manager
            && (INoerraTokenMarket(market).deployer() == launchAuthority || INoerraTokenMarket(market).launchExecutor() == launchAuthority), "Canonical launch market");
        launchMarket = market; launchPoolManager = manager;
    }
    function beginLaunchProtection() external {
        require(msg.sender == launchMarket && protectionEndBlock == 0 && balanceOf(launchMarket) == SUPPLY,
            "One full supply launch");
        protectionStartBlock = block.number; protectionEndBlock = block.number + LAUNCH_PROTECTION_BLOCKS;
    }
    function _update(address from, address to, uint256 value) internal override {
        if(protectionEndBlock != 0 && block.number < protectionEndBlock && to != address(0)
            && to != launchMarket && to != launchPoolManager) {
            if(from == launchPoolManager) require(value <= MAX_LAUNCH_HOLDING, "Launch max buy");
            require(balanceOf(to) + (from == to ? 0 : value) <= MAX_LAUNCH_HOLDING, "Launch max wallet");
        }
        super._update(from,to,value);
    }
}
