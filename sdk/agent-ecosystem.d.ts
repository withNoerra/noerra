export interface FlagshipFactoryBinding {kind:'scheduled-launch';address:`0x${string}`;codeHash:`0x${string}`;launchCalldataHash:`0x${string}`;launchNonce:number;}
import type {AgentChainPin,CurrentTradeFee} from './agent-chain.js';
export interface EcosystemPins {chainId:1;vault:AgentChainPin;market:AgentChainPin;noer:AgentChainPin;dollar:AgentChainPin;manager:AgentChainPin;quoter:AgentChainPin;feeHook:AgentChainPin;operationsTreasury:`0x${string}`;agentTreasury:`0x${string}`;noerLaunch:NoerraLaunch;}
export interface NoerraLaunch {kind:'token-only';launchProtectionBlocks?:10|25;transactionHash:`0x${string}`;block:string;tokens:string;dollars:'0';initialFdvEth:'1000000000000000000';valuationMicros:string;sqrtPriceX96:string;liquidity:string;tickLower:number;tickUpper:number;oracle:AgentChainPin;oracleMaximumAge:number;}
export interface EcosystemStatus {totalRevenue:string;totalOperations:string;totalAgentFunding:string;totalBrainFunding:string;liquidity:bigint;feeTokens:string;}
export class NoerraEcosystem {
 constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};pins:EcosystemPins;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
 connect():Promise<string>;check():Promise<void>;reconcile():Promise<string>;status():Promise<EcosystemStatus>;
 /** The output already pays NOERRA's fee in force at `quotedBlock` (25% at launch falling to 2% over 25 blocks, then 2%). */
 quote(input:{buy:boolean;input:string;slippageBps?:number}):Promise<{output:string;minimumOutput:string;slippageBps:number}&CurrentTradeFee>;
 trade(input:{buy:boolean;input:string;minimumOutput:string}):Promise<unknown>;collect():Promise<unknown>;
}
export interface FlagshipDescriptor {bindingFactory?:FlagshipFactoryBinding;kind:'platform-noerra';launchProtectionBlocks?:10|25;chainId:1;localId:string;metadataHash:`0x${string}`;agentId:`0x${string}`;owner:`0x${string}`;operationsTreasury:`0x${string}`;buildHash:`0x${string}`;hostingReserveMicros:string;dailyLimitMicros:string;registry:AgentChainPin;account:AgentChainPin;token:AgentChainPin;market:AgentChainPin;feeHook:AgentChainPin;ecosystem:AgentChainPin;dollar:AgentChainPin;manager:AgentChainPin;quoter:AgentChainPin;creationHash:`0x${string}`;bindingHash:`0x${string}`;block:string;}
export interface FlagshipPolicy extends FlagshipDescriptor {enabled:true;ecosystemPins:EcosystemPins;}
export class NoerraFlagshipMarket extends NoerraEcosystem {
 constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};policy:FlagshipPolicy;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
 balances():Promise<{tokens:string;dollars:string}>;
}
