// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoerraEcosystemVault, NoerraNoerMarket, NoerraNoerMarketDeployer,INoerraPlatformEthUsdFeed,INoerraFlagshipRegistry} from "../src/agents/NoerraEcosystem.sol";
import {NoerraAgentRegistry, NoerraAgentAccount} from "../src/agents/NoerraAgents.sol";
import {AgentTestVerifier} from "./NoerraAgents.t.sol";
import {NoerraRevenueCoin} from "../src/personal/NoerraRevenueCoin.sol";
import {NoerraQuoter} from "../src/agents/NoerraQuoter.sol";
import {NoerraNoerFeeHook} from "../src/agents/NoerraUsdcFeeHook.sol";
contract NoerraPlatformOracleFixture {
    uint8 public constant decimals=8;
    int256 public answer=2000e8;
    uint256 public updatedAt=block.timestamp;
    function set(int256 value,uint256 updated) external {answer=value;updatedAt=updated;}
    function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80){return(1,answer,updatedAt,updatedAt,1);}
}

library NoerraEcosystemFixture {
    function deploy(IPoolManager manager, IERC20 dollar, address operations, address operator)
        internal returns (NoerraEcosystemVault vault, NoerraNoerMarket market, NoerraRevenueCoin coin) {
        coin = new NoerraRevenueCoin(address(this));
        NoerraQuoter quoter = new NoerraQuoter(manager);
        (NoerraAgentRegistry registry, bytes32 id, address account)=prepareAccount(dollar);
        vault = new NoerraEcosystemVault(dollar, coin, manager, quoter, operations, account, operator);
        market = deployMarket(manager, dollar, coin, vault);
        vault.bindMarket(market);
        registry.enrollAutonomousFlagshipVault(address(vault));
        vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
    }
    function prepareAccount(IERC20 dollar) internal returns (NoerraAgentRegistry registry, bytes32 id, address account) {
        registry = new NoerraAgentRegistry(dollar, new AgentTestVerifier());
        (id, account) = registry.createAccount(address(this),keccak256("fixture identity"),keccak256("fixture build"),50e6,7e6);
        NoerraAgentAccount(account).setRecoveryPolicy(5e6,1e6);
        NoerraAgentAccount(account).approveAutomaticActivation(1,keccak256("fixture startup"),51e6,block.timestamp+1 days,0.001 ether);
    }
    function bindAccount(NoerraEcosystemVault vault, NoerraAgentRegistry registry, bytes32 id) internal {
        registry.enrollAutonomousFlagshipVault(address(vault));
        vault.bindAgent(INoerraFlagshipRegistry(address(registry)),id);
    }
    function deployMarket(IPoolManager manager, IERC20 dollar, IERC20 coin, NoerraEcosystemVault vault)
        internal returns (NoerraNoerMarket market) {
        NoerraNoerMarketDeployer builder = new NoerraNoerMarketDeployer();
        bytes32 initHash = keccak256(abi.encodePacked(type(NoerraNoerFeeHook).creationCode,
            abi.encode(manager, address(dollar), address(coin), address(builder))));
        uint256 salt;
        bytes memory payload=abi.encodePacked(bytes1(0xff),address(builder),bytes32(0),initHash);
        while (true) {
            assembly ("memory-safe") {mstore(add(payload,53),salt)}
            if (uint160(uint256(keccak256(payload))) & 0x3fff == 0x20cc) break;
            ++salt;
        }
        market = builder.deploy(manager, dollar, coin, vault, bytes32(salt),INoerraPlatformEthUsdFeed(address(new NoerraPlatformOracleFixture())),7200);
        if(NoerraRevenueCoin(address(coin)).launchMarket()==address(0))NoerraRevenueCoin(address(coin)).configureLaunchProtection(address(market),address(manager));
    }
}
