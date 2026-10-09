import type {AgentChainPin} from './agent-chain.js';
export interface ComputePoolPins {chainId:1|8453|31337;market:AgentChainPin;registry:AgentChainPin;credits:AgentChainPin;dollar:AgentChainPin;meter:`0x${string}`;computeTreasury:`0x${string}`;}
export interface ComputeListing {agentId:`0x${string}`;epoch:string;capacity:string;price:string;units:string;capacitySignature:`0x${string}`;listingSignature:`0x${string}`;}
export class NoerraComputePool {
 constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};pins:ComputePoolPins;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
 connect():Promise<string>;check():Promise<void>;reconcile():Promise<string>;
 status():Promise<{epoch:bigint;capacity:bigint;listed:bigint;reserved:bigint;consumed:bigint;priceMicros:bigint;available:bigint;creditBalance:bigint;dollarBalance:bigint;expiresAt:bigint}>;
 mint(dollars:string):Promise<unknown>;redeem(dollars:string):Promise<unknown>;
 buy(dollars:string,orderId:`0x${string}`):Promise<{orderId:`0x${string}`;epoch:bigint;units:bigint;cost:bigint;transactionHash:`0x${string}`}>;
 order(orderId:`0x${string}`):Promise<{buyer:string;epoch:bigint;units:bigint;remaining:bigint;paid:bigint}>;
 refund(orderId:`0x${string}`):Promise<unknown>;claim(epoch:string|bigint,agentId:`0x${string}`):Promise<unknown>;
 list(statement:ComputeListing):Promise<unknown>;
 authorizeListing(agentId:`0x${string}`,enabled?:boolean):Promise<void>;
}
