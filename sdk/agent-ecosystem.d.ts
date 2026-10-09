import type {AgentChainPin} from './agent-chain.js';
export interface EcosystemPins {chainId:1;vault:AgentChainPin;market:AgentChainPin;noer:AgentChainPin;dollar:AgentChainPin;manager:AgentChainPin;quoter:AgentChainPin;feeHook:AgentChainPin;operationsTreasury:`0x${string}`;agentTreasury:`0x${string}`;buybackTreasury:`0x${string}`;noerLaunch:NoerraLaunch;}
export interface NoerraLaunch {kind:'token-only';transactionHash:`0x${string}`;block:string;tokens:string;dollars:'0';initialFdvEth:'1000000000000000000';valuationMicros:string;sqrtPriceX96:string;liquidity:string;tickLower:number;tickUpper:number;oracle:AgentChainPin;oracleMaximumAge:number;}
export interface EcosystemStatus {totalRevenue:string;totalOperations:string;totalAgentFunding:string;totalBuybackFunding:string;liquidity:bigint;feeTokens:string;}
export class NoerraEcosystem {
 constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};pins:EcosystemPins;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
 connect():Promise<string>;check():Promise<void>;reconcile():Promise<string>;status():Promise<EcosystemStatus>;
 quote(input:{buy:boolean;input:string;slippageBps?:number}):Promise<{output:string;minimumOutput:string;slippageBps:number}>;
 trade(input:{buy:boolean;input:string;minimumOutput:string}):Promise<unknown>;collect():Promise<unknown>;
}
export interface FlagshipDescriptor {kind:'platform-noerra';chainId:1;localId:string;metadataHash:`0x${string}`;agentId:`0x${string}`;owner:`0x${string}`;operationsTreasury:`0x${string}`;buybackTreasury:`0x${string}`;buildHash:`0x${string}`;hostingReserveMicros:string;dailyLimitMicros:string;registry:AgentChainPin;account:AgentChainPin;token:AgentChainPin;market:AgentChainPin;feeHook:AgentChainPin;ecosystem:AgentChainPin;dollar:AgentChainPin;manager:AgentChainPin;quoter:AgentChainPin;creationHash:`0x${string}`;bindingHash:`0x${string}`;block:string;}
export interface FlagshipPolicy extends FlagshipDescriptor {enabled:true;ecosystemPins:EcosystemPins;}
export class NoerraFlagshipMarket extends NoerraEcosystem {
 constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};policy:FlagshipPolicy;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
 balances():Promise<{tokens:string;dollars:string}>;
}
