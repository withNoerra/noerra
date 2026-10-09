// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoerraRevenueCoin} from "../personal/NoerraRevenueCoin.sol";
import {NoerraAgentRegistry} from "./NoerraAgents.sol";
import {NoerraQuoter} from "./NoerraQuoter.sol";
import {NoerraNoerFeeHook} from "./NoerraUsdcFeeHook.sol";
import {NoerraAtomicEcosystemVault,NoerraNoerMarket,INoerraPlatformEthUsdFeed,INoerraFlagshipRegistry} from "./NoerraEcosystem.sol";
import {NoerraAtomicCodeHashes} from "./NoerraAtomicCodeHashes.sol";

/// @dev Immutable, non-executable STOP-prefixed constructor bytes. Deploying these
/// containers or the launch factory creates NO token or pool.
contract NoerraAtomicCreationCode {
    constructor(bytes memory creation) {
        require(creation.length > 0 && creation.length < 24576, "Creation code size");
        bytes memory code=abi.encodePacked(hex"00",creation);
        assembly ("memory-safe") { return(add(code,32),mload(code)) }
    }
}
/// @notice Exactly one EOA-owned NOERRA launch: all children, enrollment, permanent
/// liquidity and the exact ordered 24 purchases are one reverting transaction.
/// No public child-deploy, token-only, ordinary-initialize or delegatecall path exists.
contract NoerraAtomicLaunch is ReentrancyGuard {
    struct Configuration {
        address owner; address registry; bytes32 agentId; address agentAccount;
        address manager; address dollar; address quoter; address feed; uint32 maximumAge;
        address operations; address buyback; bytes32 allocationHash; uint256 authorizationNonce;
    }
    address public immutable owner;
    address public immutable registry;
    address public immutable agentAccount;
    bytes32 public immutable agentId;
    bytes32 public immutable allocationHash;
    uint256 public immutable authorizationNonce;
    Configuration public configuration;
    address[4] public codeContainers;
    bool public launched;
    bytes32 private constant TOKEN_SALT=keccak256("NOERRA_ATOMIC_TOKEN");
    bytes32 private constant VAULT_SALT=keccak256("NOERRA_ATOMIC_VAULT");
    bytes32 private constant MARKET_SALT=keccak256("NOERRA_ATOMIC_MARKET");
    event Complete(address indexed token,address indexed vault,address indexed market,address hook,bytes32 allocation,uint256[] outputs);
    constructor(Configuration memory c,address[4] memory containers) {
        require(block.chainid==1 && c.owner!=address(0) && c.registry.code.length>0 && c.agentAccount.code.length>0
            && c.manager.code.length>0 && c.dollar.code.length>0 && c.quoter.code.length>0 && c.feed.code.length>0
            && c.allocationHash!=bytes32(0), "Reviewed launch configuration");
        require(NoerraAgentRegistry(c.registry).deploymentAuthority()==c.owner
            && NoerraAgentRegistry(c.registry).accounts(c.agentId)==c.agentAccount
            && address(NoerraAgentRegistry(c.registry).dollar())==c.dollar, "Original registry binding");
        require(address(NoerraQuoter(c.quoter).poolManager())==c.manager, "Reviewed quoter");
        owner=c.owner;registry=c.registry;agentAccount=c.agentAccount;agentId=c.agentId;
        allocationHash=c.allocationHash;authorizationNonce=c.authorizationNonce;configuration=c;codeContainers=containers;
        for(uint256 i;i<4;++i) require(keccak256(_creation(i))==NoerraAtomicCodeHashes.expected(i), "Reviewed creation bytes");
    }
    function _creation(uint256 i) private view returns(bytes memory code) {
        address container=codeContainers[i];uint256 n=container.code.length;
        require(n>1 && n<=24576,"Immutable code container");
        bytes memory first=new bytes(1);
        assembly ("memory-safe") {extcodecopy(container,add(first,32),0,1)}
        require(first[0]==bytes1(0),"STOP container");
        code=new bytes(n-1);
        assembly ("memory-safe") {extcodecopy(container,add(code,32),1,sub(n,1))}
    }
    function _init(uint256 i,bytes memory args) private view returns(bytes memory) {return abi.encodePacked(_creation(i),args);}
    function _predict(bytes32 salt,bytes memory init) private view returns(address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff",address(this),salt,keccak256(init))))));
    }
    function tokenAddress() public view returns(address) {return _predict(TOKEN_SALT,_init(0,abi.encode(address(this))));}
    function _vaultArgs() private view returns(bytes memory) {
        Configuration memory c=configuration;
        return abi.encode(c.dollar,tokenAddress(),c.manager,c.quoter,c.operations,c.agentAccount,c.buyback,c.owner,c.allocationHash);
    }
    function vaultAddress() public view returns(address) {return _predict(VAULT_SALT,_init(1,_vaultArgs()));}
    function hookAddress(bytes32 salt) public view returns(address) {
        Configuration memory c=configuration;
        return _predict(salt,_init(3,abi.encode(c.manager,c.dollar,tokenAddress(),address(this))));
    }
    function _marketArgs(bytes32 salt) private view returns(bytes memory) {
        Configuration memory c=configuration;
        return abi.encode(c.manager,c.dollar,tokenAddress(),vaultAddress(),hookAddress(salt),c.feed,c.maximumAge);
    }
    function marketAddress(bytes32 salt) public view returns(address) {return _predict(MARKET_SALT,_init(2,_marketArgs(salt)));}
    function _deploy(uint256 i,bytes32 salt,bytes memory args) private returns(address child) {
        bytes memory init=_init(i,args);
        require(init.length<=49152,"Initcode size");
        assembly ("memory-safe") {child:=create2(0,add(init,32),mload(init),salt)}
        require(child!=address(0) && child.code.length<=24576,"Child deployment");
    }
    function launch(bytes32 hookSalt,NoerraNoerMarket.LaunchBuy[] calldata buys,uint256 deadline)
        external nonReentrant returns(uint256[] memory outputs) {
        require(msg.sender==owner && !launched,"One owner launch");
        require(buys.length==24 && keccak256(abi.encode(buys))==allocationHash,"Exact 24 allocations");
        require(block.timestamp<=deadline && deadline<=block.timestamp+5 minutes,"Fresh deadline");
        require(uint160(hookAddress(hookSalt))&0x3fff==0x20cc,"Hook permissions");
        launched=true;
        address token=_deploy(0,TOKEN_SALT,abi.encode(address(this)));
        address vault=_deploy(1,VAULT_SALT,_vaultArgs());
        Configuration memory c=configuration;
        address hook=_deploy(3,hookSalt,abi.encode(c.manager,c.dollar,token,address(this)));
        address market=_deploy(2,MARKET_SALT,_marketArgs(hookSalt));
        NoerraNoerFeeHook(hook).register(market);
        NoerraAtomicEcosystemVault(vault).bindMarket(NoerraNoerMarket(market));
        NoerraAgentRegistry(registry).enrollAtomicFlagshipVault(vault,authorizationNonce);
        NoerraAtomicEcosystemVault(vault).bindAgent(INoerraFlagshipRegistry(registry),agentId);
        NoerraRevenueCoin(token).configureLaunchProtection(market,c.manager);
        require(IERC20(token).transfer(market,1_000_000_000 ether),"Full permanent seed");
        outputs=NoerraNoerMarket(market).initializeWithBuys(1_000_000_000 ether,buys,deadline);
        emit Complete(token,vault,market,hook,allocationHash,outputs);
    }
}
