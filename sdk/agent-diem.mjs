import {getAddress,keccak256,parseAbi,erc20Abi,parseUnits,formatUnits} from 'viem';
import {AccessMarket} from './access-market.mjs';
import wrapperAbi from './abi/NoerraDiem.json' with {type:'json'};
const readerAbi=parseAbi(['function poolBackingPage(uint256,uint256) view returns(uint256 subtotal,uint256 next)']);
const registryAbi=parseAbi(['function accounts(bytes32) view returns(address)']);
const accountAbi=parseAbi(['function human() view returns(address)']);
const diemAbi=parseAbi(['function stakedInfos(address) view returns(uint256 amountStaked,uint256 coolDownEnd,uint256 coolDownAmount)']);
const zero='0x'+'0'.repeat(40);
const id=value=>{if(!/^0x[a-f0-9]{64}$/i.test(value||''))throw Error('Invalid onchain agent identity.');return value;};
const amount=value=>{if(typeof value!=='string'||!/^\d{1,10}(?:\.\d{1,18})?$/.test(value)||parseUnits(value,18)<=0n)throw Error('Enter a positive DIEM amount with at most 18 decimals.');return parseUnits(value,18);};

/** Wallet-reviewed DIEM wrapping and permanent agent allocation. Each step has
 * its own durable wallet receipt, rather than silently repeating a funding flow.
 */
export class NoerraAgentDiem extends AccessMarket {
  constructor({ethereum,pins,storage}) {
    for(const name of ['wrapper','diem','registry'])if(!/^0x[a-f0-9]{40}$/i.test(pins?.[name]?.address||'')||!/^0x[a-f0-9]{64}$/i.test(pins[name].codeHash||''))throw Error('Pin the agent DIEM deployment.');
    if(pins.reader&&(!/^0x[a-f0-9]{40}$/i.test(pins.reader.address||'')||!/^0x[a-f0-9]{64}$/i.test(pins.reader.codeHash||'')))throw Error('Pin the pool backing reader.');
    super({ethereum,config:{enabled:true,chainId:pins.chainId,address:pins.wrapper.address,codeHash:pins.wrapper.codeHash},storage,supportedChainIds:[8453,31337]});this.pins=structuredClone(pins);
  }
  readAt(address,abi,functionName,args=[]){return this.public.readContract({address:getAddress(address),abi,functionName,args});}
  async check(){
    await super.check();for(const name of ['diem','registry'])if(keccak256(await this.public.getBytecode({address:this.pins[name].address}))!==this.pins[name].codeHash)throw Error('DIEM deployment pin changed.');
    const [diem,registry,decimals]=await Promise.all([this.readAt(this.market,wrapperAbi,'diem'),this.readAt(this.market,wrapperAbi,'registry'),this.readAt(this.pins.diem.address,erc20Abi,'decimals')]);
    if(getAddress(diem)!==getAddress(this.pins.diem.address)||getAddress(registry)!==getAddress(this.pins.registry.address)||decimals!==18)throw Error('DIEM deployment wiring changed.');
  }
  async poolBackingPage(start=0n,maximum=64){
    if(typeof start!=='bigint'||start<0n||start>=2n**256n||!Number.isSafeInteger(maximum)||maximum<1||maximum>64||!this.pins.reader)throw Error('Use a pinned reader, nonnegative cursor and page size from 1 to 64.');
    await this.check();
    if(keccak256(await this.public.getBytecode({address:this.pins.reader.address}))!==this.pins.reader.codeHash||getAddress(await this.readAt(this.market,wrapperAbi,'backingReader'))!==getAddress(this.pins.reader.address))throw Error('Pool backing reader pin or wiring changed.');
    const [subtotal,next]=await this.readAt(this.pins.reader.address,readerAbi,'poolBackingPage',[start,BigInt(maximum)]);
    return {subtotal:formatUnits(subtotal,18),next};
  }
  async status(agentId){
    await this.check();const agent=id(agentId),[vault,locked,wrapped,diem]=await Promise.all([this.readAt(this.market,wrapperAbi,'vaults',[agent]),this.readAt(this.market,wrapperAbi,'lockedTreasury',[agent]),this.readAt(this.market,erc20Abi,'balanceOf',[this.owner]),this.readAt(this.pins.diem.address,erc20Abi,'balanceOf',[this.owner])]);
    const stake=vault===zero?[0n,0n,0n]:await this.readAt(this.pins.diem.address,diemAbi,'stakedInfos',[vault]);
    return {vault,locked:formatUnits(locked,18),wrapped:formatUnits(wrapped,18),diem:formatUnits(diem,18),staked:formatUnits(stake[0],18),cooldown:formatUnits(stake[2],18),cooldownEndsAt:stake[1]};
  }
  async wrap(value){const n=amount(value);await this.check();const allowance=await this.readAt(this.pins.diem.address,erc20Abi,'allowance',[this.owner,this.market]);if(allowance<n)await this.transact(this.pins.diem.address,erc20Abi,'approve',[this.market,n]);return this.transact(this.market,wrapperAbi,'wrap',[n,this.owner]);}
  async lockFor(agentId,value,{acknowledgePermanentLock=false}={}){
    if(!acknowledgePermanentLock)throw Error('This allocation cannot be withdrawn. Acknowledge the permanent lock.');
    await this.check();const agent=id(agentId),account=await this.readAt(this.pins.registry.address,registryAbi,'accounts',[agent]);
    if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Select an agent owned by your connected wallet.');
    return this.transact(this.market,wrapperAbi,'lockFor',[agent,amount(value)]);
  }
  reconcileAgent(agentId){return this.transact(this.market,wrapperAbi,'reconcile',[id(agentId)]);}
  redeem(value){return this.transact(this.market,wrapperAbi,'redeem',[amount(value)]);}
  claim(){return this.transact(this.market,wrapperAbi,'claim',[]);}
}
