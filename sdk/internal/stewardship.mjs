import {getAddress,keccak256,parseAbi} from 'viem';

const accountAbi=parseAbi(['function registry() view returns(address)','function agentId() view returns(bytes32)','function human() view returns(address)','function signer() view returns(address)','function buildHash() view returns(bytes32)','function generation() view returns(uint256)','function autonomousCoreLocked() view returns(bool)','function startupHuman() view returns(address)','function stewardshipRevision() view returns(uint256)','function platformStewardshipRevision() view returns(uint256)']);
const registryAbi=parseAbi(['function accounts(bytes32) view returns(address)']);
const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.toLowerCase()===b.toLowerCase();

/** Stewardship changes user authority, never the original custody/key domain. */
export async function readAgentStewardship({client,policy,binding}) {
  if(binding?.chainId!==1||!/^0x[a-f0-9]{40}$/i.test(binding.account||'')||!/^0x[a-f0-9]{64}$/i.test(binding.agentId||'')||!/^0x[a-f0-9]{64}$/i.test(policy?.codeHash||'')||!same(binding.buildHash,policy.buildHash)||await client.getChainId()!==1)throw Error('Pin the original Ethereum account before changing stewardship.');
  const block=await client.getBlock({blockTag:'finalized'});
  if(keccak256(await client.getBytecode({address:policy.address,blockNumber:block.number}))!==policy.codeHash)throw Error('Stewardship registry pin changed.');
  const read=functionName=>client.readContract({address:binding.account,abi:accountAbi,functionName,blockNumber:block.number});
  const [registry,id,human,signer,build,generation,locked,startupHuman,registered]=await Promise.all(['registry','agentId','human','signer','buildHash','generation','autonomousCoreLocked','startupHuman'].map(read).concat([client.readContract({address:policy.address,abi:registryAbi,functionName:'accounts',args:[binding.agentId],blockNumber:block.number})]));
  if(!same(registry,policy.address)||!same(registered,binding.account)||!same(id,binding.agentId)||!same(build,binding.buildHash)||!same(signer,binding.signer)||generation!==BigInt(binding.generation)||typeof locked!=='boolean'||!/^0x[a-f0-9]{40}$/i.test(human)||/^0x0{40}$/i.test(human)||!(locked?same(startupHuman,binding.owner):same(human,binding.owner)))throw Error('The finalized agent authority differs from its retained custody binding.');
  const [revision,platformRevision]=locked?await Promise.all(['stewardshipRevision','platformStewardshipRevision'].map(read)):[0n,0n];
  if(typeof revision!=='bigint'||typeof platformRevision!=='bigint'||platformRevision<0n||platformRevision>revision)throw Error('The finalized stewardship revision is invalid.');
  return {steward:getAddress(human).toLowerCase(),autonomous:locked,revision:String(revision),platformRevision:String(platformRevision),blockNumber:String(block.number),blockHash:block.hash};
}
