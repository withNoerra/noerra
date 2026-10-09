import type {Abi} from 'viem';
export type EarnedDiemAction='target'|'pause-purchases'|'resume-purchases'|'cooldown'|'claim'|'recover-cash'|'enable-allocations'|'pause-allocations'|'return-allocation';
export interface EarnedDiemPin {address:string;codeHash:string;implementations?:{slot:string;value:string;codeHash:string}[];}
export interface EarnedDiemDescriptor {
  schema:'noerra-earned-diem-reserve/v1';localId:string;agentId:string;reviewedPlanHash:string;
  source:{chainId:1;registry:string;account:string;escrow:string;pins:EarnedDiemPin[];[key:string]:unknown};
  base:{chainId:8453;reserve:string;treasury:string;authority:string;pins:EarnedDiemPin[];[key:string]:unknown};
  limits:{maximumPrincipalWei:string;[key:string]:string|number};
}
export interface EarnedDiemStatus {
  schema?:string;ready:boolean;reasons:string[];descriptor:EarnedDiemDescriptor|null;owner:string|null;generation:string|null;
  source:{allocationsEnabled:boolean;availableEarnedUSDCMicros:string;earnedFeeIncomeUSDCMicros:string}|null;
  base:{purchasesPaused:boolean;targetDiemWei:string;principalWei:string;availableEarnedUSDCMicros:string;cooldownAmountWei:string;cooldownEnd:string}|null;
  actions:EarnedDiemAction[];keeper:{ready:boolean;reasons:string[]};verifiedDomains?:{source:boolean;base:boolean};
}
export interface EarnedDiemReceiptInput {transactionHash:string;action:EarnedDiemAction;value?:string;generation?:string;}
export interface EarnedDiemReceipt {verified:true;finalized:true;transactionHash:string;action:EarnedDiemAction;success:boolean;chainId:1|8453;to:string;data:string;value:'0';reviewedPlanHash:string;}
export const earnedDiemReserveAbi:Abi;
export const earnedDiemEscrowAbi:Abi;
export const earnedDiemActions:readonly EarnedDiemAction[];
export function validateEarnedDiemReceiptInput(input:unknown):EarnedDiemReceiptInput;
export function earnedDiemTransaction(descriptor:EarnedDiemDescriptor,input:Omit<EarnedDiemReceiptInput,'transactionHash'>):{chainId:number;target:string;data:string;value:'0';functionName:string;args:unknown[];abi:Abi;pins:EarnedDiemPin[]};
export class NoerraEarnedDiem {
  constructor(options:{ethereum:{request(input:{method:string;params?:unknown[]|object}):Promise<unknown>};client:{owner?:string|null;earnedDiem(id:string):Promise<EarnedDiemStatus>;earnedDiemReceipt(id:string,input:EarnedDiemReceiptInput):Promise<EarnedDiemReceipt>};agentId:string;storage?:Pick<Storage,'getItem'|'setItem'|'removeItem'>});
  connect():Promise<string>;
  pending():{version:1;agentId:string;owner:string;phase:'awaiting-wallet'|'submitted';intent:{action:EarnedDiemAction;value?:string;generation?:string;planHash:string};transaction:{chainId:number;target:string;data:string;value:'0'};hash?:string;at:number}|null;
  transact(action:EarnedDiemAction,options?:{value?:string}):Promise<EarnedDiemReceipt>;
  reconcile(transactionHash?:string):Promise<EarnedDiemReceipt|null>;
}
