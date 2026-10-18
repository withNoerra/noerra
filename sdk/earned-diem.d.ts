import type {Abi} from 'viem';
/** The brain fund has no creator actions (1.0.0). */
export type EarnedDiemAction=never;
export interface EarnedDiemPin {address:string;codeHash:string;implementations?:{slot:string;value:string;codeHash:string}[];}
export interface EarnedDiemDescriptor {
  schema:'noerra-earned-diem-reserve/v1';localId:string;agentId:string;reviewedPlanHash:string;
  source:{chainId:1;registry:string;account:string;escrow:string;pins:EarnedDiemPin[];[key:string]:unknown};
  base:{chainId:8453;reserve:string;pins:EarnedDiemPin[];[key:string]:unknown};
  limits:{[key:string]:string|number};
}
/** Ethereum escrow side: USDC waiting to bridge, and whether brain fees currently route to agent cash (full or paused). */
export interface BrainFundSourceState {availableUSDC?:string;full?:string|boolean;allocationsEnabled?:string|boolean;totalBridged?:string;frozen?:string|boolean;escrowBound?:string|boolean;[key:string]:unknown}
/** Base reserve side: staked and cooling DIEM (18 decimals), full at 10 DIEM, and any pending platform withdrawal. */
export interface BrainFundBaseState {deployed?:string|boolean;staked?:string;cooling?:string;coolDownEnd?:string;full?:string|boolean;usdc?:string;diem?:string;pending?:{operation:string;amount:string;requestedAt:string;availableAt:string};[key:string]:unknown}
export interface EarnedDiemStatus {
  schema?:string;ready:boolean;reasons:string[];descriptor:EarnedDiemDescriptor|null;owner:string|null;generation:string|null;
  source:BrainFundSourceState|null;base:BrainFundBaseState|null;
  /** Always empty: the brain fund has no creator actions. */
  actions:EarnedDiemAction[];keeper:{ready:boolean;reasons:string[]};verifiedDomains?:{source:boolean;base:boolean};
}
/** Read-only ABI of NoerraEarnedDiemReserve (principal, full, remainingCapacity, CAP, PLATFORM_WITHDRAWAL_DELAY, KEEPER_LIVENESS). */
export const earnedDiemReserveAbi:Abi;
export const BRAIN_FUND_CAP_DIEM:'10';
export const PLATFORM_WITHDRAWAL_DELAY_SECONDS:604800;
export const earnedDiemActions:readonly EarnedDiemAction[];
/** Always throws: there are no creator brain-fund transactions. */
export function validateEarnedDiemReceiptInput(input?:unknown):never;
export class NoerraEarnedDiem {
  constructor(options:{client:{earnedDiem(id:string):Promise<EarnedDiemStatus>};agentId:string});
  /** The owner's verified brain-fund status from the agent service. Sends nothing. */
  status():Promise<EarnedDiemStatus>;
}
