import test from 'node:test';
import assert from 'node:assert/strict';
import {keccak256,decodeFunctionData} from 'viem';
import {NoerraEarnedDiem,earnedDiemTransaction,earnedDiemActions,validateEarnedDiemReceiptInput} from '../sdk/earned-diem.mjs';
const owner='0x'+'11'.repeat(20),other='0x'+'22'.repeat(20),id='ab'.repeat(16),txHash='0x'+'ab'.repeat(32),zero='0x'+'00'.repeat(32),code='0x6000';
const descriptor={schema:'noerra-earned-diem-reserve/v1',localId:id,agentId:'0x'+'01'.repeat(32),reviewedPlanHash:'0x'+'42'.repeat(32),source:{chainId:1,escrow:'0x'+'33'.repeat(20),pins:[]},base:{chainId:8453,reserve:'0x'+'44'.repeat(20),treasury:'0x'+'55'.repeat(20),pins:[]},limits:{maximumPrincipalWei:String(100n*10n**18n)}};
for(const [domain,target]of [[descriptor.source,descriptor.source.escrow],[descriptor.base,descriptor.base.reserve]])domain.pins=[{address:target,codeHash:keccak256(code),implementations:[{slot:zero,value:zero,codeHash:keccak256('0x')}]}];
function harness(){
 const data=new Map(),storage={getItem:key=>data.get(key)??null,setItem:(key,value)=>data.set(key,value),removeItem:key=>data.delete(key)};
 const status={ready:true,descriptor:structuredClone(descriptor),owner,generation:'3',actions:[...earnedDiemActions]};
 let sends=0,reads=0,currentOwner=owner,chainId=8453,verifyError=null,receiptChange={},walletError=null;
 const client={owner,earnedDiem:async()=>structuredClone(status),earnedDiemReceipt:async(agentId,input)=>{assert.equal(agentId,id);if(verifyError)throw verifyError;const transaction=earnedDiemTransaction(descriptor,input);return {verified:true,finalized:true,transactionHash:input.transactionHash,action:input.action,success:true,chainId:transaction.chainId,to:transaction.target,data:transaction.data,value:'0',reviewedPlanHash:descriptor.reviewedPlanHash,...receiptChange};}};
 const ethereum={request:async()=>[currentOwner]},sdk=new NoerraEarnedDiem({ethereum,client,agentId:id,storage});
 sdk.public={getChainId:async()=>chainId,getBytecode:async({address})=>{assert.notEqual(address,'0x'+'00'.repeat(20));reads++;return code;},getStorageAt:async()=>zero,simulateContract:async request=>({request})};
 sdk.wallet={writeContract:async()=>{sends++;if(walletError)throw walletError;return txHash;}};
 return {sdk,status,data,client,storage,get sends(){return sends;},get reads(){return reads;},set owner(value){currentOwner=value;},set chain(value){chainId=value;},set verifyError(value){verifyError=value;},set receiptChange(value){receiptChange=value;},set walletError(value){walletError=value;}};
}
test('earned reserve target uses reviewed bound, includes generation and permits25 without universal cap',()=>{
 for(const amount of ['0','5000000000000000000','25000000000000000000','99000000000000000000']){
  const row=earnedDiemTransaction(descriptor,{action:'target',value:amount,generation:'3'}),decoded=decodeFunctionData({abi:row.abi,data:row.data});assert.equal(decoded.functionName,'setTarget');assert.deepEqual(decoded.args,[3n,BigInt(amount)]);
 }
 assert.throws(()=>earnedDiemTransaction(descriptor,{action:'target',value:String(101n*10n**18n),generation:'3'}),/reviewed principal bound/);
});
test('every reserve action uses exact source or Base contract and has no selectable recovery recipient',()=>{
 for(const action of earnedDiemActions){const row=earnedDiemTransaction(descriptor,{action,...(['target','cooldown'].includes(action)?{value:'1'}:{}),...(['target','resume-purchases'].includes(action)?{generation:'3'}:{})});assert.equal(row.value,'0');assert.equal(row.chainId,['enable-allocations','pause-allocations','return-allocation'].includes(action)?1:8453);}
 assert.throws(()=>validateEarnedDiemReceiptInput({transactionHash:txHash,action:'claim',recipient:other}),/original/);
 for(const input of [{action:'target',value:'-1',generation:'1'},{action:'target',value:'1',generation:'0'},{action:'cooldown',value:'0'},{action:'claim',generation:'3'},{action:'claim',value:'1'},{action:'target',value:'1.0',generation:'3'},{action:'target',value:String(2n**256n),generation:'3'}])assert.throws(()=>validateEarnedDiemReceiptInput({transactionHash:txHash,...input}));
});
test('verified exact finalized transaction clears original intent, including non-proxy zero slot pins',async()=>{
 const h=harness();await h.sdk.connect();const receipt=await h.sdk.transact('target',{value:'25000000000000000000'});assert.equal(receipt.success,true);assert.equal(h.sends,1);assert.equal(h.reads,2);assert.equal(h.sdk.pending(),null);
});
test('unknown finality retains original amount and generation and reconciliation never sends again',async()=>{
 const h=harness();await h.sdk.connect();h.verifyError=Error('Waiting finalized block');await assert.rejects(h.sdk.transact('target',{value:'25'}),/finalized/);const saved=h.sdk.pending();assert.equal(saved.intent.value,'25');assert.equal(saved.intent.generation,'3');assert.equal(saved.hash,txHash);
 h.status.generation='4';await assert.rejects(h.sdk.transact('claim'),/original reserve action/);assert.equal(h.sends,1);
 h.verifyError=null;await h.sdk.reconcile();assert.equal(h.sends,1);assert.equal(h.sdk.pending(),null);
});
test('wrong target/calldata/chain/plan receipt cannot clear the original action',async()=>{
 for(const change of [{to:other},{data:'0x00000000'},{chainId:1},{value:'1'},{reviewedPlanHash:zero},{transactionHash:zero},{action:'claim'},{verified:false},{finalized:false}]){
  const h=harness();await h.sdk.connect();h.receiptChange=change;await assert.rejects(h.sdk.transact('pause-purchases'),/not finalized/);assert.equal(h.sdk.pending().hash,txHash);assert.equal(h.sends,1);
 }
});
test('wallet decline clears only refused submission; unknown submission requires original hash',async()=>{
 const rejected=harness();await rejected.sdk.connect();rejected.walletError=Object.assign(Error('declined'),{code:4001});await assert.rejects(rejected.sdk.transact('claim'),/declined/);assert.equal(rejected.sdk.pending(),null);
 const unknown=harness();await unknown.sdk.connect();unknown.walletError=Error('connection lost');await assert.rejects(unknown.sdk.transact('claim'),/connection lost/);assert.equal(unknown.sdk.pending().phase,'awaiting-wallet');await assert.rejects(unknown.sdk.reconcile(),/unknown/);await unknown.sdk.reconcile(txHash);assert.equal(unknown.sends,1);assert.equal(unknown.sdk.pending(),null);
});
test('changed account, chain, code, permissions and agent descriptor stop before wallet dispatch',async()=>{
 const cases=[
  h=>{h.owner=other;},
  h=>{h.chain=1;},
  h=>{h.sdk.public.getBytecode=async()=> '0x6001';},
  h=>{h.sdk.public.getStorageAt=async()=> '0x'+'01'.repeat(32);},
  h=>{h.status.ready=false;},
  h=>{h.status.actions=[];},
  h=>{h.status.descriptor.localId='cd'.repeat(16);},
  h=>{h.client.owner=other;},
 ];
 for(const change of cases){const h=harness();await h.sdk.connect();change(h);await assert.rejects(h.sdk.transact('claim'));assert.equal(h.sends,0);assert.equal(h.data.size,0);}
});
test('keeper purchase gate does not remove independently verified emergency actions',async()=>{
 const h=harness();await h.sdk.connect();h.status.actions=['pause-purchases','cooldown'];await assert.rejects(h.sdk.transact('resume-purchases'),/not ready/);await h.sdk.transact('pause-purchases');assert.equal(h.sends,1);
});
test('verified exact reverted receipt clears its journal and reports no applied change',async()=>{
 const h=harness();await h.sdk.connect();h.receiptChange={success:false};await assert.rejects(h.sdk.transact('claim'),/reverted/);assert.equal(h.sdk.pending(),null);
});
test('storage failures and corrupted original journals fail closed before sending',async()=>{
 const h=harness();await h.sdk.connect();h.storage.setItem=()=>{throw Error('storage full');};await assert.rejects(h.sdk.transact('claim'),/storage full/);assert.equal(h.sends,0);
 h.data.set(h.sdk.journalKey,'{');await assert.rejects(h.sdk.transact('claim'),/manual review/);assert.equal(h.sends,0);
});
