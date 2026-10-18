import {parseAbi} from 'viem';

/** Read-only view of an agent's brain fund (NoerraEarnedDiemReserve on Base, fed by its Ethereum NoerraEarnedDiemEscrow).
 * The brain fund has no creator actions: no target, pause, cooldown, claim or cash recovery. 20% of the agent's
 * trading fees (and any deposit) are bridged to Base, bought into DIEM and staked at Venice for its inference, up to
 * 10 DIEM staked. At the cap the escrow routes brain fees to the agent's cash instead. Every step is permissionless.
 * The platform may withdraw staked DIEM from any reserve, only to its fixed address and only 7 days after it asks. */
export const earnedDiemReserveAbi=parseAbi([
  'function principal() view returns(uint256 staked,uint256 cooling,uint256 coolDownEnd)',
  'function full() view returns(bool)',
  'function remainingCapacity() view returns(uint256)',
  'function CAP() view returns(uint256)',
  'function PLATFORM_WITHDRAWAL_DELAY() view returns(uint256)',
  'function KEEPER_LIVENESS() view returns(uint256)',
]);
/** Staked DIEM at which the reserve stops buying (NoerraEarnedDiemReserve.CAP). */
export const BRAIN_FUND_CAP_DIEM='10';
/** Wait between a platform withdrawal request and its completion (NoerraEarnedDiemReserve.PLATFORM_WITHDRAWAL_DELAY). */
export const PLATFORM_WITHDRAWAL_DELAY_SECONDS=7*86400;
/** The brain fund has no creator actions. Kept (empty) so older status payloads can still be checked. */
export const earnedDiemActions=Object.freeze([]);
/** There are no creator brain-fund transactions to verify; every input is refused. */
export function validateEarnedDiemReceiptInput() {
  throw Error('The brain fund has no creator actions to verify.');
}
/** Owner-session status reader for the agent's brain fund. It never sends a transaction. */
export class NoerraEarnedDiem {
  constructor({client,agentId}={}) {
    if(!client?.earnedDiem||!/^[a-f0-9]{32}$/.test(agentId||''))throw Error('Connect the agent owner session first.');
    this.client=client;this.agentId=agentId;
  }
  async status() {
    const value=await this.client.earnedDiem(this.agentId);
    if(!value||typeof value!=='object'||typeof value.ready!=='boolean')throw Error('Verified brain fund status is unavailable.');
    if(value.ready&&value.descriptor?.localId!==this.agentId)throw Error('The brain fund status belongs to another agent.');
    return value;
  }
}
