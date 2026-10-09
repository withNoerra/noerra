import {createPublicClient,createWalletClient,custom,encodeFunctionData,getAddress,keccak256,parseAbi} from 'viem';

export const earnedDiemReserveAbi=parseAbi([
  'function setTarget(uint256 expectedGeneration,uint256 target)',
  'function pausePurchases()',
  'function resumePurchases(uint256 expectedGeneration,bytes32 planHash)',
  'function initiateRecovery(uint256 amount)',
  'function claimRecovery()',
  'function recoverCash()',
]);
export const earnedDiemEscrowAbi=parseAbi([
  'function enableAllocations(bytes32 planHash)',
  'function pauseAllocations()',
  'function returnAllocation()',
]);
export const earnedDiemActions=Object.freeze(['target','pause-purchases','resume-purchases','cooldown','claim','recover-cash','enable-allocations','pause-allocations','return-allocation']);
const uint=value=>typeof value==='string'&&/^(0|[1-9][0-9]{0,77})$/.test(value)&&BigInt(value)<2n**256n;
const hash=value=>typeof value==='string'&&/^0x[a-fA-F0-9]{64}$/.test(value);
const address=value=>typeof value==='string'&&/^0x[a-fA-F0-9]{40}$/.test(value)&&!/^0x0{40}$/.test(value);
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.toLowerCase()===b.toLowerCase();
export function validateEarnedDiemReceiptInput(input) {
  if(!input||Object.getPrototypeOf(input)!==Object.prototype||Object.keys(input).some(key=>!['transactionHash','action','value','generation'].includes(key))||!hash(input.transactionHash)||!earnedDiemActions.includes(input.action))throw Error('Use the original earned-DIEM transaction receipt.');
  const quantity=['target','cooldown'].includes(input.action),generation=['target','resume-purchases'].includes(input.action);
  if(quantity?!uint(input.value):input.value!==undefined)throw Error('Use the exact original DIEM amount in base units.');
  if(generation?!uint(input.generation)||input.generation==='0':input.generation!==undefined)throw Error('Use the exact original creator generation.');
  if(input.action==='cooldown'&&input.value==='0')throw Error('Choose a positive recovery amount.');
  return {...input};
}
export function earnedDiemTransaction(descriptor,{action,value,generation}) {
  validateEarnedDiemReceiptInput({transactionHash:'0x'+'00'.repeat(32),action,...(value===undefined?{}:{value}),...(generation===undefined?{}:{generation})});
  if(descriptor?.schema!=='noerra-earned-diem-reserve/v1'||descriptor.source?.chainId!==1||descriptor.base?.chainId!==8453||!hash(descriptor.reviewedPlanHash)||!address(descriptor.base.reserve)||!address(descriptor.source.escrow)||!address(descriptor.base.treasury)||!uint(descriptor.limits?.maximumPrincipalWei))throw Error('A reviewed earned-DIEM deployment is required.');
  const source=['enable-allocations','pause-allocations','return-allocation'].includes(action),domain=source?descriptor.source:descriptor.base;
  const mapping={
    target:['setTarget',[BigInt(generation||0),BigInt(value||0)]],
    'pause-purchases':['pausePurchases',[]],
    'resume-purchases':['resumePurchases',[BigInt(generation||0),descriptor.reviewedPlanHash]],
    cooldown:['initiateRecovery',[BigInt(value||0)]],
    claim:['claimRecovery',[]],
    'recover-cash':['recoverCash',[]],
    'enable-allocations':['enableAllocations',[descriptor.reviewedPlanHash]],
    'pause-allocations':['pauseAllocations',[]],
    'return-allocation':['returnAllocation',[]],
  };
  if(action==='target'&&BigInt(value)>BigInt(descriptor.limits.maximumPrincipalWei))throw Error('The target exceeds this deployment’s reviewed principal bound.');
  const [functionName,args]=mapping[action],abi=source?earnedDiemEscrowAbi:earnedDiemReserveAbi,target=getAddress(source?domain.escrow:domain.reserve);
  if(!Array.isArray(domain.pins)||!domain.pins.length||!domain.pins.some(pin=>equal(pin.address,target))||domain.pins.some(pin=>!address(pin.address)||!hash(pin.codeHash)||pin.implementations!==undefined&&(!Array.isArray(pin.implementations)||pin.implementations.some(row=>!hash(row.slot)||!hash(row.value)||!hash(row.codeHash)))))throw Error('The earned-DIEM deployment pins are incomplete.');
  return {chainId:domain.chainId,target,abi,functionName,args,data:encodeFunctionData({abi,functionName,args}),value:'0',pins:domain.pins};
}
/** Wallet actions retain the original intent until the runtime proves its exact finalized receipt. */
export class NoerraEarnedDiem {
  constructor({ethereum,client,agentId,storage=globalThis.localStorage}) {
    if(!ethereum?.request||!client?.earnedDiem||!client?.earnedDiemReceipt||!/^[a-f0-9]{32}$/.test(agentId))throw Error('Connect the agent owner session first.');
    this.ethereum=ethereum;this.client=client;this.agentId=agentId;this.storage=storage;
    this.public=createPublicClient({transport:custom(ethereum)});this.wallet=createWalletClient({transport:custom(ethereum)});this.busy=false;
  }
  async connect() {
    const [owner]=await this.ethereum.request({method:'eth_requestAccounts'});this.owner=getAddress(owner);
    if(!equal(this.owner,this.client.owner))throw Error('Use the wallet connected to this agent workspace.');
    return this.owner;
  }
  get journalKey(){if(!this.owner)throw Error('Connect the creator wallet first.');return 'noerra-earned-diem:'+this.agentId+':'+this.owner.toLowerCase();}
  pending(){const raw=this.storage?.getItem(this.journalKey);if(!raw)return null;try{const row=JSON.parse(raw);if(row?.version!==1||row.agentId!==this.agentId||!equal(row.owner,this.owner)||!['awaiting-wallet','submitted'].includes(row.phase)||!earnedDiemActions.includes(row.intent?.action)||!hash(row.intent?.planHash)||!address(row.transaction?.target)||!/^0x[0-9a-f]+$/i.test(row.transaction?.data)||row.transaction?.value!=='0'||![1,8453].includes(row.transaction?.chainId)||row.hash!==undefined&&!hash(row.hash))throw Error();return row;}catch{throw Error('The saved earned-DIEM action needs manual review. It will not be resent.');}}
  async check(transaction){
    if(!equal(this.owner,this.client.owner))throw Error('The workspace wallet changed. Reconnect.');
    const [owner]=await this.ethereum.request({method:'eth_accounts'});
    if(!equal(owner,this.owner))throw Error('The connected wallet changed. Reconnect.');
    if(await this.public.getChainId()!==transaction.chainId)throw Error('Switch your wallet to '+(transaction.chainId===1?'Ethereum':'Base')+' for this action.');
    for(const pin of transaction.pins){
      const code=await this.public.getBytecode({address:pin.address});
      if(!code||!equal(keccak256(code),pin.codeHash))throw Error('The earned-DIEM contract code changed. Refresh its reviewed deployment.');
      for(const implementation of pin.implementations||[]){
        const slot=await this.public.getStorageAt({address:pin.address,slot:implementation.slot});
        if(!equal(slot,implementation.value))throw Error('The earned-DIEM infrastructure implementation changed.');
        if(/^0x0{64}$/.test(implementation.value))continue;
        const implementationAddress='0x'+implementation.value.slice(-40);
        const implementationCode=await this.public.getBytecode({address:implementationAddress});
        if(!implementationCode||!equal(keccak256(implementationCode),implementation.codeHash))throw Error('The earned-DIEM infrastructure implementation code changed.');
      }
    }
  }
  lock(work){const locks=globalThis.navigator?.locks;return locks?locks.request('noerra-earned-diem:'+this.agentId+':'+this.owner,{ifAvailable:true},lock=>{if(!lock)throw Error('Another tab is handling this reserve.');return work();}):work();}
  async transact(action,{value}={}){
    return this.lock(async()=>{
      if(this.busy)throw Error('Wait for the pending reserve action.');this.busy=true;
      try{
        if(this.pending())throw Error('Reconcile the original reserve action before sending another.');
        const status=await this.client.earnedDiem(this.agentId);
        if(status.ready!==true||status.descriptor?.localId!==this.agentId||!equal(status.owner,this.owner)||!status.actions?.includes(action))throw Error('This reserve action is not ready. Refresh the verified deployment status.');
        const generation=['target','resume-purchases'].includes(action)?status.generation:undefined;
        const intent={action,...(value===undefined?{}:{value}),...(generation===undefined?{}:{generation}),planHash:status.descriptor.reviewedPlanHash};
        const transaction=earnedDiemTransaction(status.descriptor,intent);
        await this.check(transaction);
        const {request}=await this.public.simulateContract({account:this.owner,address:transaction.target,abi:transaction.abi,functionName:transaction.functionName,args:transaction.args,value:0n});
        await this.check(transaction);
        if(!this.storage)throw Error('Browser transaction storage is unavailable.');
        if(this.pending())throw Error('Another reserve action is unresolved.');
        const row={version:1,agentId:this.agentId,owner:this.owner,phase:'awaiting-wallet',intent,transaction:{chainId:transaction.chainId,target:transaction.target,data:transaction.data,value:'0'},at:Date.now()};
        this.storage.setItem(this.journalKey,JSON.stringify(row));
        let transactionHash;
        try{transactionHash=await this.wallet.writeContract({...request,chain:null});}
        catch(error){if(error.code===4001||error.cause?.code===4001)this.storage.removeItem(this.journalKey);throw error;}
        if(!hash(transactionHash))throw Error('Wallet submission outcome is unknown. Inspect the original wallet action.');
        row.hash=transactionHash;row.phase='submitted';this.storage.setItem(this.journalKey,JSON.stringify(row));
        return await this.verify(row);
      }finally{this.busy=false;}
    });
  }
  async verify(row){
    const {action,value,generation}=row.intent;
    const receipt=await this.client.earnedDiemReceipt(this.agentId,{transactionHash:row.hash,action,...(value===undefined?{}:{value}),...(generation===undefined?{}:{generation})});
    if(receipt?.verified!==true||receipt.finalized!==true||!equal(receipt.transactionHash,row.hash)||receipt.action!==action||typeof receipt.success!=='boolean'||receipt.chainId!==row.transaction.chainId||!equal(receipt.to,row.transaction.target)||!equal(receipt.data,row.transaction.data)||receipt.value!==row.transaction.value||!equal(receipt.reviewedPlanHash,row.intent.planHash))throw Error('The original reserve transaction is not finalized yet. Keep its receipt and check again.');
    this.storage.removeItem(this.journalKey);
    if(!receipt.success)throw Error('The original reserve transaction reverted. No reserve change was applied.');
    return receipt;
  }
  async reconcile(transactionHash){
    return this.lock(async()=>{
      if(this.busy)throw Error('Wait for the pending reserve action.');this.busy=true;
      try{
        const [owner]=await this.ethereum.request({method:'eth_accounts'});
        if(!equal(owner,this.owner)||!equal(this.owner,this.client.owner))throw Error('Reconnect the original creator wallet.');
        const row=this.pending();if(!row)return null;
        if(transactionHash!==undefined){
          if(!hash(transactionHash)||row.hash&&!equal(row.hash,transactionHash))throw Error('Keep the original transaction hash.');
          row.hash=transactionHash;row.phase='submitted';this.storage.setItem(this.journalKey,JSON.stringify(row));
        }
        if(!row.hash)throw Error('Wallet submission is unknown. Enter the original transaction hash from wallet history; this action will not be resent.');
        return await this.verify(row);
      }finally{this.busy=false;}
    });
  }
}
