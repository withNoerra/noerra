import {parseAbi,decodeFunctionData,decodeEventLog,keccak256} from 'viem';
const same=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
const digest=v=>typeof v==='string'&&/^0x[a-f0-9]{64}$/i.test(v)&&!/^0x0{64}$/i.test(v);
const address=v=>typeof v==='string'&&/^0x[a-f0-9]{40}$/i.test(v)&&!/^0x0{40}$/i.test(v);
const required=(ok,message)=>{if(!ok)throw Error(message);};
const abi=parseAbi(['function launch(bytes32 hookSalt,uint256 deadline)','function owner() view returns(address)','function registry() view returns(address)','function agentAccount() view returns(address)','function agentId() view returns(bytes32)','function allocationHash() view returns(bytes32)','function launched() view returns(bool)','function tokenAddress() view returns(address)','function vaultAddress() view returns(address)','function hookAddress(bytes32) view returns(address)','function marketAddress(bytes32) view returns(address)','event ScheduledLaunch(address indexed token,address indexed vault,address indexed market,address hook,bytes32 allocation)']);
const boundAbi=parseAbi(['event AgentBound(bytes32 indexed agentId,address indexed account,address indexed registry,bytes32 buildHash)']);
export function validateFlagshipBindingFactory(value){
 required(value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===5&&Object.keys(value).every(k=>['kind','address','codeHash','launchCalldataHash','launchNonce'].includes(k))&&value.kind==='scheduled-launch'&&address(value.address)&&digest(value.codeHash)&&digest(value.launchCalldataHash)&&Number.isSafeInteger(value.launchNonce)&&value.launchNonce>=0,'Pin the exact reviewed scheduled factory binding.');
 return value;
}
/** Exact one-use owner factory transaction and same-receipt account binding.
 * No arbitrary receipt target or user-selected calldata is accepted. */
export async function verifyFlagshipFactoryReceipt({client,flagship:f,receipt,block}){
 const pin=validateFlagshipBindingFactory(f.bindingFactory);
 required(await client.getChainId()===1&&receipt?.status==='success'&&same(receipt.transactionHash,f.bindingHash)&&same(receipt.to,pin.address)&&!receipt.logs?.some(l=>l.removed),'Exact successful original factory receipt required.');
 required(receipt.blockNumber<=block.number,'Wait for finalized scheduled factory binding.');
 const original=await client.getBlock({blockNumber:receipt.blockNumber});
 required(same(original.hash,receipt.blockHash),'Scheduled factory binding was reorganized.');
 for(const blockNumber of [receipt.blockNumber,block.number]){const code=await client.getBytecode({address:pin.address,blockNumber});required(code&&same(keccak256(code),pin.codeHash),'Scheduled factory bytecode differs from its exact pin.');}
 const tx=await client.getTransaction({hash:f.bindingHash});
 required(tx&&same(tx.hash,f.bindingHash)&&tx.chainId===1&&same(tx.from,f.owner)&&same(tx.to,pin.address)&&tx.value===0n&&tx.nonce===pin.launchNonce&&same(tx.blockHash,receipt.blockHash)&&tx.blockNumber===receipt.blockNumber&&same(keccak256(tx.input),pin.launchCalldataHash),'Original owner factory call differs from its captured calldata, nonce or value.');
 const decoded=decodeFunctionData({abi,data:tx.input});
 required(decoded.functionName==='launch'&&decoded.args[1]>=original.timestamp&&decoded.args[1]<=original.timestamp+300n,'Original scheduled launch function or deadline differs.');
 const read=(functionName,args=[])=>client.readContract({address:pin.address,abi,functionName,args,blockNumber:block.number});
 for(const [name,want]of Object.entries({owner:f.owner,registry:f.registry.address,agentAccount:f.account.address,agentId:f.agentId,tokenAddress:f.token.address,vaultAddress:f.ecosystem.address,launched:true}))required(same(await read(name),want),'Scheduled factory authority or child differs: '+name);
 required(same(await read('hookAddress',[decoded.args[0]]),f.feeHook.address)&&same(await read('marketAddress',[decoded.args[0]]),f.market.address),'Original hook salt does not bind the captured children.');
 const logs=(target,definitions,eventName)=>(receipt.logs||[]).filter(l=>same(l.address,target)&&!l.removed).flatMap(l=>{try{const e=decodeEventLog({abi:definitions,topics:l.topics,data:l.data});return e.eventName===eventName?[e]:[];}catch{return [];}});
 const launches=logs(pin.address,abi,'ScheduledLaunch'),bound=logs(f.ecosystem.address,boundAbi,'AgentBound');
 required(launches.length===1&&same(launches[0].args.token,f.token.address)&&same(launches[0].args.vault,f.ecosystem.address)&&same(launches[0].args.market,f.market.address)&&same(launches[0].args.hook,f.feeHook.address)&&same(launches[0].args.allocation,await read('allocationHash')),'Exact factory launch event and immutable allocation required.');
 required(bound.length===1&&same(bound[0].args.agentId,f.agentId)&&same(bound[0].args.account,f.account.address)&&same(bound[0].args.registry,f.registry.address)&&same(bound[0].args.buildHash,f.buildHash),'Factory receipt lacks the exact account binding event.');
 return {factory:pin.address,transactionHash:f.bindingHash,finalized:true};
}
