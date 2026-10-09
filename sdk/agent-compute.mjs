import {getAddress,keccak256,encodeAbiParameters,recoverMessageAddress,parseUnits,erc20Abi,decodeEventLog} from 'viem';
import {AccessMarket} from './access-market.mjs';
import poolAbi from './abi/NoerraComputeMarket.json' with {type:'json'};
import creditsAbi from './abi/NoerraAgentCredits.json' with {type:'json'};
import registryAbi from './abi/NoerraAgentRegistry.json' with {type:'json'};
import accountAbi from './abi/NoerraAgentAccount.json' with {type:'json'};
const same=(a,b)=>getAddress(a)===getAddress(b);
const hash=value=>{if(!/^0x[a-f0-9]{64}$/i.test(value||''))throw Error('Use a 32-byte compute identity.');return value;};
const integer=value=>{if(!/^[0-9]{1,15}$/.test(String(value))||BigInt(value)<=0n)throw Error('Use a positive integer compute amount.');return BigInt(value);};
const dollars=value=>{if(typeof value!=='string'||!/^\d{1,8}(\.\d{1,6})?$/.test(value))throw Error('Use an exact six-decimal dollar amount.');const n=parseUnits(value,6);if(!n)throw Error('Enter a positive amount.');return n;};
const signature=value=>{if(!/^0x[a-f0-9]{130}$/i.test(value||''))throw Error('Compute capacity signature is invalid.');return value;};

/** One pooled purchase. No seller selection, unbounded approval or auto-retry. */
export class NoerraComputePool extends AccessMarket {
  constructor({ethereum,pins,storage=globalThis.localStorage}){
    for(const name of ['market','registry','credits','dollar'])if(!pins?.[name]||!/^0x[a-f0-9]{64}$/i.test(pins[name].codeHash||''))throw Error('Pin every pooled compute contract.');
    if(!pins.meter||!pins.computeTreasury)throw Error('Pin the compute meter and treasury.');
    getAddress(pins.meter);getAddress(pins.computeTreasury);
    super({ethereum,config:{enabled:true,chainId:pins.chainId,address:pins.market.address,codeHash:pins.market.codeHash},storage,supportedChainIds:[1,8453,31337]});this.pins=structuredClone(pins);
  }
  read(address,abi,functionName,args=[],blockNumber){return this.public.readContract({address:getAddress(address),abi,functionName,args,...(blockNumber?{blockNumber}:{})});}
  async check(){
    await super.check();
    for(const name of ['registry','credits','dollar']){const code=await this.public.getBytecode({address:getAddress(this.pins[name].address)});if(!code||keccak256(code)!==this.pins[name].codeHash)throw Error('Compute '+name+' bytecode differs from its pin.');}
    for(const name of ['registry','credits','dollar','meter','computeTreasury'])if(!same(await this.read(this.market,poolAbi,name),this.pins[name]?.address||this.pins[name]))throw Error('Pooled compute wiring differs from its policy.');
    const c=this.pins.credits.address;
    if(!same(await this.read(c,creditsAbi,'settlement'),this.market)||!same(await this.read(c,creditsAbi,'dollar'),this.pins.dollar.address)||!same(await this.read(c,creditsAbi,'registry'),this.pins.registry.address)||await this.read(this.pins.dollar.address,erc20Abi,'decimals')!==6)throw Error('Pool credit backing differs from its policy.');
  }
  async status(){await this.check();const block=await this.public.getBlock(),epoch=block.timestamp/86400n*86400n,row=await this.read(this.market,poolAbi,'epochs',[epoch]);const [creditBalance,dollarBalance]=await Promise.all([this.pins.credits.address,this.pins.dollar.address].map(a=>this.read(a,erc20Abi,'balanceOf',[this.owner])));return {epoch,capacity:row[0],listed:row[1],reserved:row[2],consumed:row[3],priceMicros:row[4],available:row[1]-row[2]-row[3],creditBalance,dollarBalance,expiresAt:epoch+86400n};}
  async approveExact(token,spender,n){if(await this.read(token,erc20Abi,'allowance',[this.owner,spender])<n)await this.transact(token,erc20Abi,'approve',[spender,n]);}
  async mint(value){const n=dollars(value);await this.approveExact(this.pins.dollar.address,this.pins.credits.address,n);return this.transact(this.pins.credits.address,creditsAbi,'mint',[n,this.owner]);}
  redeem(value){return this.transact(this.pins.credits.address,creditsAbi,'redeem',[dollars(value)]);}
  async buy(value,orderId){
    hash(orderId);const s=await this.status();
    if(!s.priceMicros)throw Error('Current-day compute is not available.');
    const units=dollars(value)/s.priceMicros;
    if(!units||units>s.available)throw Error('Choose an amount within available current-day compute.');
    const cost=units*s.priceMicros;
    if(s.creditBalance<cost){const missing=cost-s.creditBalance;await this.approveExact(this.pins.dollar.address,this.pins.credits.address,missing);await this.transact(this.pins.credits.address,creditsAbi,'mint',[missing,this.owner]);}
    await this.approveExact(this.pins.credits.address,this.market,cost);
    const receipt=await this.transact(this.market,poolAbi,'buy',[s.epoch,units,orderId]);
    const event=receipt.logs.filter(l=>same(l.address,this.market)).map(l=>{try{return decodeEventLog({abi:poolAbi,data:l.data,topics:l.topics});}catch{return null;}}).find(e=>e?.eventName==='Bought'&&e.args.orderId===orderId);
    if(!event||!same(event.args.buyer,this.owner)||event.args.units!==units)throw Error('Keep the purchase receipt; its order needs reconciliation.');return {orderId,epoch:s.epoch,units,cost,transactionHash:receipt.transactionHash};
  }
  async order(orderId){await this.check();const r=await this.read(this.market,poolAbi,'orders',[hash(orderId)]);return {buyer:r[0],epoch:r[1],units:r[2],remaining:r[3],paid:r[4]};}
  refund(orderId){return this.transact(this.market,poolAbi,'refund',[hash(orderId)]);}
  claim(epoch,agentId){return this.transact(this.market,poolAbi,'claim',[BigInt(epoch),hash(agentId)]);}
  async authorizeListing(agentId,enabled=true){
    if(typeof enabled!=='boolean')throw Error('Choose whether to authorize automatic listing.');await this.check();
    const account=await this.read(this.pins.registry.address,registryAbi,'accounts',[hash(agentId)]);
    if(!same(await this.read(account,accountAbi,'human'),this.owner))throw Error('Only this agent’s owner may approve its compute market.');
    if(await this.read(account,accountAbi,'recipients',[this.market])!==enabled)await this.transact(account,accountAbi,'setRecipient',[this.market,enabled]);
  }
  async list(statement){
    await this.check();const {agentId,epoch,capacity,price,units}=statement;hash(agentId);
    const e=BigInt(epoch),c=integer(capacity),p=integer(price),u=integer(units),s=await this.status();
    if(e!==s.epoch||c>1_000_000_000n||p>1_000_000_000n||u>c||s.priceMicros&&s.priceMicros!==p)throw Error('List only current-day capacity at the pool price.');
    for(const [tag,types,values,sig]of [['capacity',['uint256','uint256','uint256'],[e,c,p],statement.capacitySignature],['listing',['uint256','bytes32','uint256'],[e,agentId,u],statement.listingSignature]]){
      const digest=keccak256(encodeAbiParameters(['uint256','address','string',...types].map(type=>({type})),[BigInt(this.pins.chainId),this.market,tag,...values]));
      if(!same(await recoverMessageAddress({message:{raw:digest},signature:signature(sig)}),this.pins.meter))throw Error('The pinned compute meter did not sign this listing.');
    }
    const account=await this.read(this.pins.registry.address,registryAbi,'accounts',[agentId]);
    if(!same(await this.read(account,accountAbi,'human'),this.owner))throw Error('Only this agent’s owner may list its compute.');
    if(s.capacity<c)await this.transact(this.market,poolAbi,'open',[e,c,p,statement.capacitySignature]);
    if(!await this.read(account,accountAbi,'recipients',[this.market]))await this.transact(account,accountAbi,'setRecipient',[this.market,true]);
    return this.transact(account,accountAbi,'listComputeOwned',[this.market,e,u,statement.listingSignature]);
  }
}
