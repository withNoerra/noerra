// Client-side stewardship reader shared by the SDK and the agent runtime (the runtime keeps an identical copy).
import {getAddress,keccak256,parseAbi} from 'viem';

const accountAbi=parseAbi(['function registry() view returns(address)','function agentId() view returns(bytes32)','function human() view returns(address)','function signer() view returns(address)','function buildHash() view returns(bytes32)','function generation() view returns(uint256)','function autonomousCoreLocked() view returns(bool)','function startupHuman() view returns(address)','function stewardshipRevision() view returns(uint256)','function platformStewardshipRevision() view returns(uint256)']);
const registryAbi=parseAbi(['function accounts(bytes32) view returns(address)']);
const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.toLowerCase()===b.toLowerCase();

/** Canonical Multicall3 (same address on Ethereum mainnet and Base). */
export const MULTICALL3_ADDRESS='0xcA11bde05977b3631167028862bE2a173976CA11';
/** Fields that can never change for a pinned binding (chain id, registry code, registry/agentId/buildHash, the registry entry)
 * are re-verified at most every STEWARDSHIP_PIN_REFRESH_MS per client; the fields that can change (human, signer, generation,
 * lock, startup human, revisions) are read at the latest block on every call, in one Multicall3 eth_call when the client
 * supports it. Authorization never uses a stale steward. */
export const STEWARDSHIP_PIN_REFRESH_MS=180000;
const STATIC=['registry','agentId','buildHash'],MUTABLE=['human','signer','generation','autonomousCoreLocked','startupHuman'],REVISIONS=['stewardshipRevision','platformStewardshipRevision'];
const pins=new WeakMap();

/** Several view calls at one block: one Multicall3 eth_call when available, otherwise individual reads. Each result is {ok,value|error}. */
export async function readContractsAt(client,contracts,{blockNumber}){
  if(typeof client.multicall==='function'){
    const rows=await client.multicall({contracts,blockNumber,allowFailure:true,multicallAddress:MULTICALL3_ADDRESS});
    if(!Array.isArray(rows)||rows.length!==contracts.length)throw Error('Multicall returned a different number of results.');
    return rows.map(row=>row?.status==='success'?{ok:true,value:row.result}:{ok:false,error:row?.error||Error('Multicall read failed.')});
  }
  return Promise.all(contracts.map(contract=>client.readContract({...contract,blockNumber}).then(value=>({ok:true,value}),error=>({ok:false,error}))));
}

/** Stewardship changes user authority, never the original custody/key domain. */
export async function readAgentStewardship({client,policy,binding,pinRefreshMs=STEWARDSHIP_PIN_REFRESH_MS,now=Date.now}) {
  if(binding?.chainId!==1||!/^0x[a-f0-9]{40}$/i.test(binding.account||'')||!/^0x[a-f0-9]{64}$/i.test(binding.agentId||'')||!/^0x[a-f0-9]{64}$/i.test(policy?.codeHash||'')||!same(binding.buildHash,policy.buildHash)||!Number.isSafeInteger(pinRefreshMs)||pinRefreshMs<0)throw Error('Pin the original Ethereum account before changing stewardship.');
  let cache=pins.get(client);if(!cache){cache=new Map();pins.set(client,cache);}
  const key=[policy.address,policy.codeHash,binding.account,binding.agentId,binding.buildHash].map(value=>String(value).toLowerCase()).join(':'),pinnedAt=cache.get(key),at=now();
  const pinned=Number.isSafeInteger(pinnedAt)&&at>=pinnedAt&&at-pinnedAt<pinRefreshMs;
  if(!pinned&&await client.getChainId()!==1)throw Error('Pin the original Ethereum account before changing stewardship.');
  const block=await client.getBlock({blockTag:'latest'});
  if(!pinned&&keccak256(await client.getBytecode({address:policy.address,blockNumber:block.number}))!==policy.codeHash)throw Error('Stewardship registry pin changed.');
  const batched=typeof client.multicall==='function',account=functionName=>({address:binding.account,abi:accountAbi,functionName});
  const calls=[...MUTABLE.map(account),...(pinned?[]:[...STATIC.map(account),{address:policy.address,abi:registryAbi,functionName:'accounts',args:[binding.agentId]}]),...(batched?REVISIONS.map(account):[])];
  const results=await readContractsAt(client,calls,{blockNumber:block.number}),value=index=>{const row=results[index];if(!row.ok)throw row.error;return row.value;};
  const [human,signer,generation,locked,startupHuman]=MUTABLE.map((_,i)=>value(i));
  if(!pinned){const [registry,id,build,registered]=[0,1,2,3].map(i=>value(MUTABLE.length+i));if(!same(registry,policy.address)||!same(registered,binding.account)||!same(id,binding.agentId)||!same(build,binding.buildHash))throw Error('The finalized agent authority differs from its retained custody binding.');}
  if(!same(signer,binding.signer)||generation!==BigInt(binding.generation)||typeof locked!=='boolean'||!/^0x[a-f0-9]{40}$/i.test(human)||/^0x0{40}$/i.test(human)||!(locked?same(startupHuman,binding.owner):same(human,binding.owner)))throw Error('The finalized agent authority differs from its retained custody binding.');
  const offset=calls.length-REVISIONS.length;
  const [revision,platformRevision]=locked?batched?[value(offset),value(offset+1)]:await Promise.all(REVISIONS.map(name=>client.readContract({...account(name),blockNumber:block.number}))):[0n,0n];
  if(typeof revision!=='bigint'||typeof platformRevision!=='bigint'||platformRevision<0n||platformRevision>revision)throw Error('The finalized stewardship revision is invalid.');
  if(!pinned)cache.set(key,at);
  return {steward:getAddress(human).toLowerCase(),autonomous:locked,revision:String(revision),platformRevision:String(platformRevision),blockNumber:String(block.number),blockHash:block.hash};
}
