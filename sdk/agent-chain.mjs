import { getAddress, keccak256, stringToHex, parseUnits, formatUnits, erc20Abi, decodeEventLog, parseAbi, encodeAbiParameters, verifyMessage } from 'viem';
import { AccessMarket } from './access-market.mjs';
import {readAgentStewardship} from './internal/stewardship.mjs';
export {NoerraEarnedDiem} from './earned-diem.mjs';
export {NoerraAgentDiem} from './agent-diem.mjs';
export {NoerraComputePool} from './agent-compute.mjs';
export {NoerraEcosystem,NoerraFlagshipMarket} from './agent-ecosystem.mjs';
export {automaticActivationIntent,automaticActivationCommitment,automaticActivationTemplateHash,canonicalActivationJson} from './internal/automatic-activation-intent.mjs';
import registryAbi from './abi/NoerraAgentRegistry.json' with {type:'json'};
import accountAbi from './abi/NoerraAgentAccount.json' with {type:'json'};
import creditsAbi from './abi/NoerraAgentCredits.json' with {type:'json'};
import launchpadAbi from './abi/NoerraAgentLaunchpad.json' with {type:'json'};
import creationAbi from './abi/NoerraLockedCreation.json' with {type:'json'};
import backersAbi from './abi/NoerraBackers.json' with {type:'json'};
import quoterAbi from './abi/NoerraQuoter.json' with {type:'json'};
import diemLaunchAbi from './abi/NoerraDiemLaunchpad.json' with {type:'json'};
import diemWrapperAbi from './abi/NoerraDiem.json' with {type:'json'};
import diemReaderAbi from './abi/NoerraDiemBackingReader.json' with {type:'json'};
import diemDeployerAbi from './abi/NoerraDiemCreationDeployer.json' with {type:'json'};
import dualLaunchAbi from './abi/NoerraDualLaunchpad.json' with {type:'json'};
import sleepingAbi from './abi/NoerraSleepingLaunchpad.json' with {type:'json'};
import checkoutAbi from './abi/NoerraEthCheckout.json' with {type:'json'};
import brainAbi from './abi/NoerraBrainLaunchpad.json' with {type:'json'};
import authorityAbi from './abi/NoerraAgentAuthorityMessenger.json' with {type:'json'};
const fundingQuoterAbi=parseAbi(['function quoteExactOutputSingle((address tokenIn,address tokenOut,uint256 amount,uint24 fee,uint160 sqrtPriceLimitX96)) returns(uint256 amountIn,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)']);
const ethUsdAbi=parseAbi(['function decimals() view returns(uint8)']);
const protectionAbi=parseAbi(['function manager() view returns(address)','function factory() view returns(address)','function quoter() view returns(address)','function FEE_BPS() view returns(uint256)']);
const cashBuilderAbi=parseAbi(['function launchProtectionHook() view returns(address)','function protectionQuoter() view returns(address)']);
const canonicalFeeAbi=parseAbi(['function FEE() view returns(uint24)','function SWAP_FEE_BPS() view returns(uint256)','function AGENT_BPS() view returns(uint256)','function CREATOR_BPS() view returns(uint256)','function BACKERS_BPS() view returns(uint256)','function ECOSYSTEM_BPS() view returns(uint256)']);
const automaticAbi=parseAbi(['function automaticActivation() view returns(bytes32 intentHash,uint256 policyNonce,uint256 minimumBalance,uint256 expiresAt,uint256 maxStartupGasWei)','function activationPolicyNonce() view returns(uint256)','function approveAutomaticActivation(uint256 expectedGeneration,bytes32 intentHash,uint256 minimumBalance,uint256 expiresAt,uint256 maxStartupGasWei)','function cancelAutomaticActivation()']);
const autonomyAbi=parseAbi(['function autonomousCoreLocked() view returns(bool)','function startupHuman() view returns(address)','function autonomousDailyFloor() view returns(uint256)']);
const stewardshipAbi=parseAbi(['function proposedHuman() view returns(address)','function offerHuman(address next)','function acceptHuman()']);
const zero = '0x' + '0'.repeat(40);
export const agentMetadataHash = id => {if(!/^[a-f0-9]{32}$/.test(id||''))throw Error('Invalid local agent identity.');return keccak256(stringToHex(id));};
const hash32 = value => { if(!/^0x[a-f0-9]{64}$/i.test(value||'')) throw Error('Use a 32-byte commitment.'); return value; };
const amount = (value, decimals) => { if(typeof value!=='string'||!/^\d{1,30}(?:\.\d{1,18})?$/.test(value)||(value.split('.')[1]||'').length>decimals) throw Error('Use an exact decimal string within the asset precision.'); const result=parseUnits(value,decimals); if(result<=0n)throw Error('Enter a positive amount.'); return result; };

/** Wallet-only financial operations. Deployment pins are independently reviewed inputs,
 * never accepted from an untrusted agent response. No transaction is automatically retried.
 */
export class NoerraAgentChain extends AccessMarket {
  constructor({ethereum, pins, storage=globalThis.localStorage}) {
    for(const name of ['registry','credits','launchpad','dollar','manager']) if(!pins?.[name]||!/^0x[a-f0-9]{64}$/i.test(pins[name].codeHash||''))throw Error('Pin every agent financial contract.');
    if(pins.launchMode==='sleeping'&&(!pins.ethUsdFeed||!/^0x[a-f0-9]{64}$/i.test(pins.ethUsdFeed.codeHash||'')||!Number.isInteger(pins.oracleMaximumAge)||pins.oracleMaximumAge<60||pins.oracleMaximumAge>7200))throw Error('Pin the reviewed ETH/USD feed and maximum age.');
    if(pins.launchMode==='sleeping')for(const name of ['cashDeployer','launchProtectionHook','quoter','ecosystemVault'])if(!pins[name]||!/^0x[a-f0-9]{64}$/i.test(pins[name].codeHash||''))throw Error('Pin the canonical launch protection, quoter and ecosystem fee vault.');
    super({ethereum, config:{enabled:true,chainId:pins.chainId,address:pins.launchpad.address,codeHash:pins.launchpad.codeHash},storage,supportedChainIds:new.target===NoerraAgentChain?[1,31337]:[8453,31337]});
    this.pins=structuredClone(pins); this.quoteDecimals=6; this.rewardDecimals=6;
    if(pins.launchMode==='sleeping'){this.marketFunction='cashLaunches';this.pins.providerMode=pins.providerMode??'cash-only';if(!['cash-only','legacy-diem'].includes(this.pins.providerMode))throw Error('Use a reviewed provider deployment mode.');}
  }
  async check() {
    await super.check();
    for(const name of ['registry','credits','dollar','manager']) { const pin=this.pins[name],code=await this.public.getBytecode({address:getAddress(pin.address)}); if(!code||keccak256(code)!==pin.codeHash)throw Error('Agent '+name+' bytecode differs from its pin.'); }
    if(this.pins.quoter){const pin=this.pins.quoter,code=await this.public.getBytecode({address:getAddress(pin.address)});if(!code||keccak256(code)!==pin.codeHash||getAddress(await this.readAt(pin.address,quoterAbi,'poolManager'))!==getAddress(this.pins.manager.address))throw Error('Quote contract differs from the pinned market.');}
    const [registry,credits,manager]=await Promise.all(['registry','credits','manager'].map(name=>this.readAt(this.market,launchpadAbi,name)));
    if([['registry',registry],['credits',credits],['manager',manager]].some(([name,value])=>getAddress(value)!==getAddress(this.pins[name].address)))throw Error('Launchpad wiring differs from the reviewed deployment.');
    const [dollar,creditRegistry,decimals]=await Promise.all([this.readAt(credits,creditsAbi,'dollar'),this.readAt(credits,creditsAbi,'registry'),this.readAt(this.pins.dollar.address,erc20Abi,'decimals')]);
    if(getAddress(dollar)!==getAddress(this.pins.dollar.address)||getAddress(creditRegistry)!==getAddress(registry)||decimals!==6)throw Error('Credit backing wiring differs from its policy.');
    if(this.pins.launchMode==='sleeping'){
      const pin=this.pins.ethUsdFeed,code=await this.public.getBytecode({address:getAddress(pin.address),blockTag:'finalized'});
      const policyRead=(address,abi,functionName)=>this.public.readContract({address:getAddress(address),abi,functionName,blockTag:'finalized'});
      const [feed,age,fdv,blocks,bps,precision]=await Promise.all(['ethUsdFeed','oracleMaximumAge','LAUNCH_FDV_ETH','LAUNCH_PROTECTION_BLOCKS','LAUNCH_MAX_HOLDING_BPS'].map(name=>policyRead(this.market,sleepingAbi,name)).concat([policyRead(pin.address,ethUsdAbi,'decimals')]));
      if(!code||keccak256(code)!==pin.codeHash||getAddress(feed)!==getAddress(pin.address)||Number(age)!==this.pins.oracleMaximumAge||fdv!==10n**18n||Number(blocks)!==10||Number(bps)!==200||precision!==8)throw Error('Opening valuation oracle differs from the reviewed policy.');
      const hook=this.pins.launchProtectionHook,builder=this.pins.cashDeployer;
      for(const p of [hook,builder]){const runtime=await this.public.getBytecode({address:getAddress(p.address),blockTag:'finalized'});if(!runtime||keccak256(runtime)!==p.codeHash)throw Error('Canonical launch protection bytecode changed.');}
      const [sourceHook,sourceBuilder,builderHook,builderQuoter,hookManager,hookFactory,hookQuoter,hookFee]=await Promise.all([policyRead(this.market,sleepingAbi,'launchProtectionHook'),policyRead(this.market,sleepingAbi,'cashDeployer'),policyRead(builder.address,cashBuilderAbi,'launchProtectionHook'),policyRead(builder.address,cashBuilderAbi,'protectionQuoter'),...['manager','factory','quoter','FEE_BPS'].map(field=>policyRead(hook.address,protectionAbi,field))]);
      if([sourceHook,builderHook].some(value=>getAddress(value)!==getAddress(hook.address))||getAddress(sourceBuilder)!==getAddress(builder.address)||[builderQuoter,hookQuoter].some(value=>getAddress(value)!==getAddress(this.pins.quoter.address))||getAddress(hookManager)!==getAddress(this.pins.manager.address)||getAddress(hookFactory)!==this.market||(Number.parseInt(hook.address.slice(-4),16)&0x3fff)!==0x20cc||Number(hookFee)!==175)throw Error('Canonical launch protection wiring changed.');
      const vault=this.pins.ecosystemVault,vaultCode=await this.public.getBytecode({address:getAddress(vault.address),blockTag:'finalized'});
      if(!vaultCode||keccak256(vaultCode)!==vault.codeHash||getAddress(await policyRead(this.market,sleepingAbi,'noerTreasury'))!==getAddress(vault.address))throw Error('Canonical ecosystem fee vault differs from its pin.');
      if(!this.pins.operationsTreasury||getAddress(await policyRead(this.market,sleepingAbi,'protocolTreasury'))!==getAddress(this.pins.operationsTreasury))throw Error('Canonical operations treasury differs from its pin.');
    }
  }
  readAt(address,abi,functionName,args=[]) {return this.public.readContract({address:getAddress(address),abi,functionName,args});}
  async approveExact(token,spender,value) {
    const allowance=await this.readAt(token,erc20Abi,'allowance',[this.owner,spender]);
    if(allowance<value) await this.transact(token,erc20Abi,'approve',[spender,value]);
  }
  async createAccount({signer,metadataHash,buildHash,reserve='5',daily='10'}) {
    if(this.pins.launchMode==='sleeping'&&(!this.pins.buildHash||hash32(buildHash).toLowerCase()!==hash32(this.pins.buildHash).toLowerCase()))throw Error('Use the reviewed starter build for this sleeping deployment.');
    const args=[getAddress(signer),hash32(metadataHash),hash32(buildHash),amount(reserve,6),amount(daily,6)];const receipt=await this.transact(this.pins.registry.address,registryAbi,this.pins.launchMode==='sleeping'?'createAccount':'create',this.pins.launchMode==='sleeping'?args:[...args,'','']);
    for(const log of receipt.logs)if(getAddress(log.address)===getAddress(this.pins.registry.address)){try{const event=decodeEventLog({abi:registryAbi,data:log.data,topics:log.topics});if(event.eventName==='Created')return {...event.args,transactionHash:receipt.transactionHash};}catch{}}
    throw Error('Preserve the confirmed creation receipt '+receipt.transactionHash);
  }
  async creation(agentId) {
    await this.check(); agentId=hash32(agentId);
    const locker=await this.readAt(this.market,this.marketFunction==='cashLaunches'?dualLaunchAbi:launchpadAbi,this.marketFunction||'launches',[agentId]); if(locker===zero)return null;
    const [token,backers,account,liquidity,feeTokens]=await Promise.all(['token','backers','agent','lockedLiquidity','feeTokens'].map(name=>this.readAt(locker,creationAbi,name)));
    if(getAddress(account)!==getAddress(await this.readAt(this.pins.registry.address,registryAbi,'accounts',[agentId])))throw Error('Creation account mismatch.');
    if(this.pins.launchMode==='sleeping'){
      const pool=await this.readAt(locker,creationAbi,'pool'),policy=await Promise.all(['FEE','SWAP_FEE_BPS','AGENT_BPS','CREATOR_BPS','BACKERS_BPS','ECOSYSTEM_BPS'].map(field=>this.readAt(locker,canonicalFeeAbi,field)));
      if(getAddress(pool[4])!==getAddress(this.pins.launchProtectionHook.address)||Number(pool[2])!==0||policy.map(Number).some((value,index)=>value!==[0,175,5000,2000,1000,2000][index])||getAddress(await this.readAt(backers,backersAbi,'credits'))!==getAddress(this.pins.dollar.address))throw Error('Canonical pool fee, reward asset or distribution differs from policy.');
    }
    return {agentId,locker,token,backers,account,liquidity,feeTokens};
  }
  async approveProvider(agentId,recipient) {
    await this.check();const account=await this.readAt(this.pins.registry.address,registryAbi,'accounts',[hash32(agentId)]);
    if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Only the human configures account funding.');
    return this.transact(account,accountAbi,'setRecipient',[getAddress(recipient),true]);
  }
  async recoveryAccount(agentId){await this.check();const account=getAddress(await this.readAt(this.pins.registry.address,registryAbi,'accounts',[hash32(agentId)]));if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Only the owner configures recovery.');return account;}
  async recoveryPolicy(agentId){const account=await this.recoveryAccount(agentId),[reserve,maximumReimbursement,bounty,hostingReserve]=await Promise.all(['recoveryReserve','maxRecoveryReimbursement','recoveryBounty','hostingReserve'].map(name=>this.readAt(account,accountAbi,name)));return {account,reserveMicros:reserve.toString(),maximumReimbursementMicros:maximumReimbursement.toString(),bountyMicros:bounty.toString(),hostingReserveMicros:hostingReserve.toString()};}
  async configureRecovery(agentId,{maximumReimbursement,bounty}){
    const account=await this.recoveryAccount(agentId),maximum=amount(maximumReimbursement,6),reward=/^0(?:\.0{1,6})?$/.test(bounty)?0n:amount(bounty,6),reserve=await this.readAt(account,accountAbi,'hostingReserve');if(maximum+reward>reserve)throw Error('Recovery terms exceed the protected reserve cap.');return this.transact(account,accountAbi,'setRecoveryPolicy',[maximum,reward]);
  }
  async fundRecovery(agentId,dollars){const account=await this.recoveryAccount(agentId),value=amount(dollars,6),[reserve,cap]=await Promise.all(['recoveryReserve','hostingReserve'].map(name=>this.readAt(account,accountAbi,name)));if(reserve+value>cap)throw Error('Recovery funding exceeds the protected reserve cap.');await this.approveExact(this.pins.dollar.address,account,value);return this.transact(account,accountAbi,'fundRecoveryReserve',[value]);}
  async configureSleepingAccount(agentId,{dailyLimitMicros,hostingReserveMicros,recipients}) {
    await this.check();if(this.pins.chainId!==1||this.pins.launchMode!=='sleeping')throw Error('Use the Ethereum sleeping account.');
    const integer=value=>{if(!/^[1-9][0-9]{0,11}$/.test(String(value)))throw Error('Use bounded USDC micros.');return BigInt(value);};
    const daily=integer(dailyLimitMicros),reserve=integer(hostingReserveMicros);if(daily>100_000_000_000n||!Array.isArray(recipients)||recipients.length>8)throw Error('Use a finite startup spending policy.');
    const targets=[...new Set(recipients.map(value=>getAddress(value)))],id=hash32(agentId),account=getAddress(await this.readAt(this.pins.registry.address,registryAbi,'accounts',[id]));
    if(account===zero||targets.some(target=>target===zero||target===account))throw Error('Use the reviewed startup recipients.');
    const verify=async()=>{const [human,signer,generation,currentReserve]=await Promise.all(['human','signer','generation','hostingReserve'].map(field=>this.readAt(account,accountAbi,field)));if(getAddress(human)!==this.owner||getAddress(signer)!==this.owner||generation!==1n||currentReserve!==reserve)throw Error('The sleeping account authority or immutable reserve differs.');};
    await verify();const receipts=[];
    if(await this.readAt(account,accountAbi,'dailyLimit')!==daily){await verify();receipts.push(await this.transact(account,accountAbi,'setDailyLimit',[daily]));}
    for(const target of targets){await verify();if(!await this.readAt(account,accountAbi,'recipients',[target]))receipts.push(await this.transact(account,accountAbi,'setRecipient',[target,true]));}
    await verify();return {agentId:id,account,dailyLimitMicros:String(daily),hostingReserveMicros:String(reserve),recipients:targets,receipts};
  }
  async automaticActivationPolicy(agentId){
    await this.check();if(this.pins.chainId!==1||this.pins.launchMode!=='sleeping')throw Error('Use the Ethereum source account.');
    const id=hash32(agentId),block=await this.public.getBlock({blockTag:'latest'}),read=(address,abi,functionName,args=[])=>this.public.readContract({address,abi,functionName,args,blockNumber:block.number});
    const account=getAddress(await read(this.pins.registry.address,registryAbi,'accounts',[id]));if(account===zero)throw Error('Create the source account first.');
    const [human,signer,generation,build,reserve,recovery,actualId,registry,dollar,tuple,nonce,locked,startupHuman,dailyFloor]=await Promise.all([...['human','signer','generation','buildHash','hostingReserve','recoveryReserve','agentId','registry','dollar'].map(field=>read(account,accountAbi,field)),read(account,automaticAbi,'automaticActivation'),read(account,automaticAbi,'activationPolicyNonce'),...['autonomousCoreLocked','startupHuman','autonomousDailyFloor'].map(field=>read(account,autonomyAbi,field))]);
    if(getAddress(human)!==this.owner||build.toLowerCase()!==hash32(this.pins.buildHash).toLowerCase()||actualId.toLowerCase()!==id.toLowerCase()||getAddress(registry)!==getAddress(this.pins.registry.address)||getAddress(dollar)!==getAddress(this.pins.dollar.address))throw Error('The source account owner, identity or build changed.');
    if(typeof locked!=='boolean'||typeof dailyFloor!=='bigint')throw Error('Verify the account’s autonomous policy.');
    return {agentId:id,account,signer:getAddress(signer),generation:generation.toString(),intentHash:tuple[0],policyNonce:tuple[1].toString(),minimumBalanceMicros:tuple[2].toString(),expiresAt:tuple[3].toString(),maximumStartupGasWei:tuple[4].toString(),protectedReserveMicros:(reserve+recovery).toString(),currentPolicyNonce:nonce.toString(),autonomousCoreLocked:locked,startupHuman:getAddress(startupHuman),autonomousDailyFloorMicros:dailyFloor.toString(),state:locked?'locked':tuple[0]==='0x'+'0'.repeat(64)?'not-approved':block.timestamp>tuple[3]?'expired':'approved'};
  }
  async approveAutomaticActivation(agentId,{intentHash,minimumBalanceMicros,expiresAt,maximumStartupGasWei}){
    const policy=await this.automaticActivationPolicy(agentId);
    const exact=value=>{if(typeof value!=='string'||! /^[1-9][0-9]{0,16}$/.test(value))throw Error('Use exact positive activation bounds.');return BigInt(value);};
    const minimum=exact(minimumBalanceMicros),gas=exact(maximumStartupGasWei),intent=hash32(intentHash),block=await this.public.getBlock({blockTag:'latest'});
    if(policy.autonomousCoreLocked||policy.generation!=='1'||policy.signer!==this.owner||minimum<=BigInt(policy.protectedReserveMicros)||minimum>100000000000n||gas>10000000000000000n||intent==='0x'+'0'.repeat(64)||!Number.isSafeInteger(expiresAt)||BigInt(expiresAt)<=block.timestamp||BigInt(expiresAt)>block.timestamp+30n*86400n)throw Error('Review the original source, funding threshold, 30-day expiry and startup gas cap before launching.');
    return this.transact(policy.account,automaticAbi,'approveAutomaticActivation',[1n,intent,minimum,BigInt(expiresAt),gas]);
  }
  async cancelAutomaticActivation(agentId){const policy=await this.automaticActivationPolicy(agentId);if(policy.autonomousCoreLocked)throw Error('A launched agent’s autonomous startup cannot be cancelled.');return this.transact(policy.account,automaticAbi,'cancelAutomaticActivation',[]);}
  async stewardship(binding){
    await this.check();const current=await readAgentStewardship({client:this.public,policy:{...this.pins.registry,buildHash:this.pins.buildHash},binding});
    const proposedHuman=getAddress(await this.public.readContract({address:getAddress(binding.account),abi:stewardshipAbi,functionName:'proposedHuman',blockNumber:BigInt(current.blockNumber)}));
    return {...current,account:getAddress(binding.account),proposedHuman};
  }
  async offerStewardship(binding,next){
    const current=await this.stewardship(binding),recipient=getAddress(next);
    if(current.steward!==this.owner.toLowerCase()||recipient===zero||recipient.toLowerCase()===current.steward)throw Error('Only the current steward can propose a different wallet or multisig.');
    return this.transact(current.account,stewardshipAbi,'offerHuman',[recipient]);
  }
  async acceptStewardship(binding){
    const current=await this.stewardship(binding);
    if(current.proposedHuman.toLowerCase()!==this.owner.toLowerCase())throw Error('Use the proposed steward wallet to accept the transfer.');
    return this.transact(current.account,stewardshipAbi,'acceptHuman',[]);
  }
  async replaceAgentSteward(binding,next,{reasonHash}){
    const current=await this.stewardship(binding),recipient=getAddress(next),reason=hash32(reasonHash),authority=getAddress(await this.public.readContract({address:this.pins.registry.address,abi:registryAbi,functionName:'deploymentAuthority',blockNumber:BigInt(current.blockNumber)}));
    if(authority!==this.owner||!current.autonomous||recipient===zero||recipient.toLowerCase()===current.steward||reason==='0x'+'0'.repeat(64))throw Error('Only the platform deployment authority can reassign a launched agent with a recorded reason.');
    return this.transact(this.pins.registry.address,registryAbi,'replaceAgentSteward',[binding.agentId,recipient,reason]);
  }
  /** Transfer a human-controlled sleeping account to its accepting protected starter.
   * Acceptance proves possession of the destination signer; the caller must verify
   * the starter's hardware and deployment policy before selecting that destination. */
  async handoverSleeping(agentId,{nextSigner,destination,acceptance,expectedGeneration,buildHash,signerGasWei=0n}) {
    await this.check();if(this.pins.chainId!==1||this.pins.launchMode!=='sleeping')throw Error('Use the Ethereum sleeping account.');
    const id=hash32(agentId),target=getAddress(nextSigner),scope=hash32(destination),build=hash32(buildHash);
    if(hash32(this.pins.buildHash).toLowerCase()!==build.toLowerCase())throw Error('Use the reviewed starter build.');
    if(scope==='0x'+'0'.repeat(64)||target===zero||target===this.owner||typeof signerGasWei!=='bigint'||signerGasWei<0n||signerGasWei>10_000_000_000_000_000n)throw Error('Choose a distinct starter signer and bounded startup gas.');
    const account=getAddress(await this.readAt(this.pins.registry.address,registryAbi,'accounts',[id]));if(account===zero)throw Error('Create the source account first.');
    const [human,signer,generation,actualBuild,actualId,dollar,registry]=await Promise.all(['human','signer','generation','buildHash','agentId','dollar','registry'].map(field=>this.readAt(account,accountAbi,field)));
    if(getAddress(human)!==this.owner||getAddress(signer)!==this.owner||generation!==1n||String(expectedGeneration)!=='1'||actualBuild.toLowerCase()!==build.toLowerCase()||actualId.toLowerCase()!==id.toLowerCase()||getAddress(dollar)!==getAddress(this.pins.dollar.address)||getAddress(registry)!==getAddress(this.pins.registry.address))throw Error('The sleeping account authority changed.');
    const commitment=keccak256(encodeAbiParameters(['uint256','address','bytes32','uint256','bytes32','address','bytes32'].map(type=>({type})),[1n,account,id,generation,build,target,scope]));
    if(!await verifyMessage({address:target,message:{raw:commitment},signature:acceptance}))throw Error('The starter has not accepted this exact source account.');
    const receipt=await this.transact(account,accountAbi,'handover',[generation,target,scope,acceptance],{value:signerGasWei});
    const events=receipt.logs.filter(log=>!log.removed&&getAddress(log.address)===account).map(log=>{try{return decodeEventLog({abi:accountAbi,data:log.data,topics:log.topics});}catch{return null;}}).filter(Boolean);
    if(events.filter(event=>event.eventName==='Rotation'&&getAddress(event.args.oldSigner)===this.owner&&getAddress(event.args.newSigner)===target&&event.args.generation===2n).length!==1||events.filter(event=>event.eventName==='Handover'&&event.args.destination.toLowerCase()===scope.toLowerCase()&&event.args.generation===2n).length!==1)throw Error('Preserve the confirmed handover receipt '+receipt.transactionHash);
    return {agentId:id,account,signer:target,generation:'2',destination:scope,buildHash:build,transactionHash:receipt.transactionHash,receipt,state:'activation-pending'};
  }
  async launch(agentId,{name,symbol,seed}) {
    if(this.pins.launchMode==='sleeping')throw Error('Use the gas-only sleeping launch for this Ethereum deployment.');
    await this.check(); const value=amount(seed,6); if(value<100_000_000n||value>1_000_000_000_000n)throw Error('Supply $100–$1,000,000 of liquidity. It remains permanently locked.');
    if(typeof name!=='string'||!name.trim()||name.length>48||typeof symbol!=='string'||!symbol.trim()||symbol.length>12)throw Error('Choose a valid token name and symbol.');
    const id=hash32(agentId),account=await this.readAt(this.pins.registry.address,registryAbi,'accounts',[id]);
    if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Only the agent owner can launch its token.');
    await this.approveExact(this.pins.dollar.address,this.market,value);
    return this.transact(this.market,launchpadAbi,'launch',[id,name,symbol,value]);
  }
  async quoteSleeping(agentId,{name,symbol,initialValuation:callerValuation}) {
    await this.check();if(this.pins.launchMode!=='sleeping'||![1,31337].includes(this.pins.chainId))throw Error('Pin an Ethereum sleeping launch deployment.');
    if(typeof name!=='string'||!name.trim()||new TextEncoder().encode(name).length>48||typeof symbol!=='string'||!symbol.trim()||new TextEncoder().encode(symbol).length>12)throw Error('Choose a valid token name and symbol.');
    if(callerValuation!==undefined)throw Error('The opening valuation is fixed by the reviewed launch policy.');
    const id=hash32(agentId),block=await this.public.getBlock({blockTag:'latest'});
    const read=(functionName,args=[])=>this.public.readContract({address:this.market,abi:sleepingAbi,functionName,args,blockNumber:block.number});
    const [[token,sqrtPriceX96,lower,upper],value]=await Promise.all([read('quoteSleeping',[id,name,symbol]),read('initialPoolNotional')]);
    return {agentId:id,name,symbol,initialValuation:formatUnits(value,6),initialFdvEth:'1',protectionBlocks:10,maxHoldingBps:200,token,sqrtPriceX96,lower,upper,quoteDeposit:'0',state:'sleeping'};
  }
  async launchSleeping(agentId,{name,symbol,sqrtPriceX96,lower,upper,acknowledgePermanentLiquidity=false}) {
    await this.check();if(this.pins.launchMode!=='sleeping'||![1,31337].includes(this.pins.chainId))throw Error('Pin an Ethereum sleeping launch deployment.');
    if(!acknowledgePermanentLiquidity)throw Error('Acknowledge permanent Ethereum token liquidity.');
    const id=hash32(agentId);if(typeof sqrtPriceX96!=='bigint'||sqrtPriceX96<=0n||!Number.isInteger(lower)||!Number.isInteger(upper))throw Error('Use a fresh sleeping quote.');
    const activation=await this.automaticActivationPolicy(id),recovery=await this.recoveryPolicy(id);
    if(activation.state!=='approved'||BigInt(recovery.maximumReimbursementMicros)<=0n)throw Error('Approve autonomous startup and its recovery allowance before launching the token.');
    const fresh=await this.quoteSleeping(id,{name,symbol});if(sqrtPriceX96!==fresh.sqrtPriceX96||lower!==fresh.lower||upper!==fresh.upper)throw Error('The opening quote changed. Request a fresh fixed-policy quote.');
    const receipt=await this.transact(this.market,sleepingAbi,'launchSleeping',[id,name,symbol,sqrtPriceX96,lower,upper]);
    for(const log of receipt.logs)if(getAddress(log.address)===this.market){try{const event=decodeEventLog({abi:sleepingAbi,data:log.data,topics:log.topics});if(event.eventName==='SleepingLaunched'&&event.args.agentId===id)return {...event.args,receipt,transactionHash:receipt.transactionHash,state:'sleeping'};}catch{}}
    throw Error('Preserve the confirmed sleeping launch receipt '+receipt.transactionHash);
  }
  async dispatchBrain(agentId) {
    if(this.pins.providerMode==='cash-only')throw Error('Base agent-token markets are disabled for cash-only provider payments.');
    if(this.pins.launchMode!=='sleeping')throw Error('Use an Ethereum sleeping launch deployment.');
    return this.transact(this.market,sleepingAbi,'dispatchBrain',[hash32(agentId)]);
  }
  async checkCheckout() {
    await this.check();if(![1,31337].includes(this.pins.chainId))throw Error('ETH checkout is on Ethereum.');
    for(const name of ['checkout','fundingRouter','weth','fundingQuoter']){
      const pin=this.pins[name];if(!pin||!/^0x[a-f0-9]{64}$/i.test(pin.codeHash||''))throw Error('Pin the full ETH checkout route.');
      const code=await this.public.getBytecode({address:getAddress(pin.address)});if(!code||keccak256(code)!==pin.codeHash)throw Error('ETH checkout '+name+' code changed.');
    }
    for(const [field,name]of [['registry','registry'],['dollar','dollar'],['router','fundingRouter'],['weth','weth']])if(getAddress(await this.readAt(this.pins.checkout.address,checkoutAbi,field))!==getAddress(this.pins[name].address))throw Error('ETH checkout route changed.');
    if(await this.readAt(this.pins.checkout.address,checkoutAbi,'poolFee')!==500)throw Error('ETH checkout fee changed.');
  }
  async quoteBudget(agentId,{dollars,slippageBps=100}) {
    await this.checkCheckout();if(!Number.isInteger(slippageBps)||slippageBps<1||slippageBps>500)throw Error('Use slippage between0.01% and5%.');
    const exact=amount(dollars,6);if(exact<1_000_000n||exact>100_000_000_000n)throw Error('Budget must be between1 and100,000 USDC.');
    const {result}=await this.public.simulateContract({address:this.pins.fundingQuoter.address,abi:fundingQuoterAbi,functionName:'quoteExactOutputSingle',args:[{tokenIn:this.pins.weth.address,tokenOut:this.pins.dollar.address,amount:exact,fee:500,sqrtPriceLimitX96:0n}]});
    const maximum=(result[0]*BigInt(10000+slippageBps)+9999n)/10000n;if(maximum<=0n||maximum>10n**19n)throw Error('Quote exceeds the ETH budget bound.');
    const block=await this.public.getBlock();return {agentId:hash32(agentId),dollars,quotedEth:formatUnits(result[0],18),maximumEth:formatUnits(maximum,18),deadline:block.timestamp+120n,slippageBps,state:'quoted'};
  }
  async fundBudget(agentId,{dollars,maximumEth,deadline}) {
    await this.checkCheckout();if(typeof deadline!=='bigint')throw Error('Use the deadline from the reviewed budget quote.');
    return this.transact(this.pins.checkout.address,checkoutAbi,'fund',[hash32(agentId),amount(dollars,6),deadline],{value:amount(maximumEth,18)});
  }
  async syncAuthority(agentId) {
    if(this.pins.providerMode==='cash-only')throw Error('Base agent authority mirrors are disabled for cash-only provider payments.');
    await this.check();const pin=this.pins.authorityMessenger;if(!pin||keccak256(await this.public.getBytecode({address:pin.address}))!==pin.codeHash||getAddress(await this.readAt(pin.address,authorityAbi,'registry'))!==getAddress(this.pins.registry.address))throw Error('Pin the Ethereum authority messenger.');
    return this.transact(pin.address,authorityAbi,'sync',[hash32(agentId)]);
  }
  async trade(agentId,{buy,input,minimumOutput}) {
    const creation=await this.creation(agentId); if(!creation)throw Error('This agent has no token market.');
    if(typeof buy!=='boolean')throw Error('Choose buy or sell.');
    const value=amount(input,buy?this.quoteDecimals:18),minimum=amount(minimumOutput,buy?18:this.quoteDecimals);
    await this.approveExact(buy?this.quoteToken||this.pins.dollar.address:creation.token,creation.locker,value);
    const block=await this.public.getBlock();
    return this.transact(creation.locker,creationAbi,'trade',[buy,value,minimum,block.timestamp+300n]);
  }
  async quote(agentId,{buy,input,slippageBps=100}) {
    if(!this.pins.quoter)throw Error('Configure an independently pinned v4 quoter.');
    if(typeof buy!=='boolean'||!Number.isSafeInteger(slippageBps)||slippageBps<1||slippageBps>500)throw Error('Use slippage between 0.01% and 5%.');
    const creation=await this.creation(agentId);if(!creation)throw Error('No token market.');
    const value=amount(input,buy?this.quoteDecimals:18);if(value>=(1n<<127n))throw Error('Quote amount exceeds swap bounds.');
    const tuple=await this.readAt(creation.locker,creationAbi,'pool');
    const poolKey={currency0:tuple[0],currency1:tuple[1],fee:tuple[2],tickSpacing:tuple[3],hooks:tuple[4]};
    const inputToken=buy?this.quoteToken||this.pins.dollar.address:creation.token;
    const {result}=await this.public.simulateContract({address:this.pins.quoter.address,abi:quoterAbi,functionName:'quoteExactInputSingle',args:[{poolKey,zeroForOne:getAddress(inputToken)===getAddress(poolKey.currency0),exactAmount:value,hookData:'0x'}]});
    const minimum=result[0]*BigInt(10000-slippageBps)/10000n;if(minimum<=0n)throw Error('Trade is too small.');
    return {output:formatUnits(result[0],buy?18:this.quoteDecimals),minimumOutput:formatUnits(minimum,buy?18:this.quoteDecimals),slippageBps};
  }
  async feeConversionQuote(agentId,{input,slippageBps=50}){
    if(this.pins.launchMode==='sleeping')throw Error('Canonical trading fees are collected in USDC; no token-fee conversion is needed.');
    const creation=await this.creation(agentId);if(!creation||amount(input,18)>creation.feeTokens)throw Error('Only collected fee tokens can be converted.');
    return this.quote(agentId,{buy:false,input,slippageBps});
  }
  async convertFees(agentId,{input,minimumOutput}){
    if(this.pins.launchMode==='sleeping')throw Error('Canonical trading fees are collected in USDC; no token-fee conversion is needed.');
    const creation=await this.creation(agentId);if(!creation)throw Error('No token market.');
    if(getAddress(await this.readAt(creation.account,accountAbi,'human'))!==this.owner)throw Error('Only the owner selects fee conversion terms.');
    const value=amount(input,18);if(value>creation.feeTokens)throw Error('Only collected fee tokens can be converted.');
    const block=await this.public.getBlock();return this.transact(creation.locker,creationAbi,'convertFees',[value,amount(minimumOutput,this.quoteDecimals),block.timestamp+120n]);
  }
  async back(agentId,tokens,{acknowledgePermanentLock=false}={}) {
    if(!acknowledgePermanentLock)throw Error('Backing permanently locks these tokens. Explicitly acknowledge it first.');
    const creation=await this.creation(agentId); if(!creation)throw Error('This agent has no token.'); const value=amount(tokens,18);
    await this.approveExact(creation.token,creation.backers,value);return this.transact(creation.backers,backersAbi,'back',[value]);
  }
  async backerStatus(agentId){
    const creation=await this.creation(agentId);if(!creation)throw Error('No market.');
    const [tokens,backed,pending]=await Promise.all([this.readAt(creation.token,erc20Abi,'balanceOf',[this.owner]),this.readAt(creation.backers,backersAbi,'balanceOf',[this.owner]),this.readAt(creation.backers,backersAbi,'pending',[this.owner])]);
    const pendingRewards=formatUnits(pending,this.rewardDecimals),rewardAsset=this.pins.launchMode==='sleeping'?'USDC':this.rewardDecimals===18?'nDIEM':'NCC';
    return {tokens:formatUnits(tokens,18),backedTokens:formatUnits(backed,18),pendingRewards,rewardAsset,pendingCredits:pendingRewards};
  }
  async collect(agentId) {const creation=await this.creation(agentId);if(!creation)throw Error('No market.');return this.transact(creation.locker,creationAbi,'collect',[]);}
  async claimCredits(agentId) {const creation=await this.creation(agentId);if(!creation)throw Error('No backers.');return this.transact(creation.backers,backersAbi,'claim',[]);}
  claimRewards(agentId){return this.claimCredits(agentId);}
  async mintCredits(dollars) {await this.check();const value=amount(dollars,6);await this.approveExact(this.pins.dollar.address,this.pins.credits.address,value);return this.transact(this.pins.credits.address,creditsAbi,'mint',[value,this.owner]);}
  activateCredits(agentId,dollars) {return this.transact(this.pins.credits.address,creditsAbi,'activate',[hash32(agentId),amount(dollars,6)]);}
}

/** Independently pinned nDIEM market. Backer rewards are nDIEM; NCC remains
 * dollar-backed and cannot be minted from a DIEM-priced asset.
 */
export class NoerraDiemMarket extends NoerraAgentChain {
  constructor({ethereum,pins,storage=globalThis.localStorage}) {
    if(pins?.enabled===false)throw Error('Base agent-token markets are disabled for cash-only provider payments.');
    if(![8453,31337].includes(pins?.chainId))throw Error('Use the reviewed Base nDIEM deployment.');
    for(const name of ['registry','wrapper','diem','reader','launchpad','manager','deployer'])if(!pins?.[name]||!/^0x[a-f0-9]{64}$/i.test(pins[name].codeHash||''))throw Error('Pin the full nDIEM market deployment.');
    super({ethereum,pins:{...pins,credits:pins.wrapper,dollar:pins.wrapper},storage});
    this.quoteDecimals=18;this.rewardDecimals=18;
  }
  async check() {
    await AccessMarket.prototype.check.call(this);
    for(const name of ['registry','wrapper','diem','reader','manager','deployer']){
      const pin=this.pins[name],code=await this.public.getBytecode({address:getAddress(pin.address)});
      if(!code||keccak256(code)!==pin.codeHash)throw Error('nDIEM '+name+' bytecode differs from its pin.');
    }
    for(const name of ['registry','wrapper','manager'])if(getAddress(await this.readAt(this.market,diemLaunchAbi,name))!==getAddress(this.pins[name].address))throw Error('nDIEM factory wiring changed.');
    if(getAddress(await this.readAt(this.market,diemLaunchAbi,'creationDeployer'))!==getAddress(this.pins.deployer.address))throw Error('nDIEM creation deployer changed.');
    for(const name of ['wrapper','manager'])if(getAddress(await this.readAt(this.pins.deployer.address,diemDeployerAbi,name))!==getAddress(this.pins[name].address))throw Error('nDIEM creation deployer wiring changed.');
    for(const [name,pin] of [['registry','registry'],['diem','diem'],['backingReader','reader']])if(getAddress(await this.readAt(this.pins.wrapper.address,diemWrapperAbi,name))!==getAddress(this.pins[pin].address))throw Error('nDIEM collateral wiring changed.');
    for(const [name,pin] of [['factory','launchpad'],['manager','manager'],['registry','registry']])if(getAddress(await this.readAt(this.pins.reader.address,diemReaderAbi,name))!==getAddress(this.pins[pin].address))throw Error('nDIEM position reader changed.');
    if(await this.readAt(this.pins.wrapper.address,erc20Abi,'decimals')!==18)throw Error('nDIEM precision changed.');
    if(this.pins.quoter){const p=this.pins.quoter;if(keccak256(await this.public.getBytecode({address:p.address}))!==p.codeHash||getAddress(await this.readAt(p.address,quoterAbi,'poolManager'))!==getAddress(this.pins.manager.address))throw Error('Quote contract differs from the pinned market.');}
  }
  async launch(agentId,{name,symbol,seed,acknowledgePermanentLiquidity=false}) {
    if(this.pins.sourceChainId===1)throw Error('This brain market uses the bridged Ethereum token. Finalize its canonical delivery instead.');
    if(acknowledgePermanentLiquidity!==true)throw Error('Explicitly acknowledge permanent liquidity before launch.');
    await this.check();const value=amount(seed,18);
    if(value<100000000000000n||value>100000000000000000000000n)throw Error('Supply 0.0001–100,000 nDIEM of permanent liquidity.');
    if(typeof name!=='string'||!name.trim()||name.length>48||typeof symbol!=='string'||!symbol.trim()||symbol.length>12)throw Error('Choose a valid token name and symbol.');
    const id=hash32(agentId),account=await this.readAt(this.pins.registry.address,registryAbi,'accounts',[id]);
    if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Only the agent owner can launch its token.');
    await this.approveExact(this.pins.wrapper.address,this.market,value);
    return this.transact(this.market,diemLaunchAbi,'launch',[id,name,symbol,value]);
  }
  async reconcileCompute(agentId){await this.check();return this.transact(this.pins.wrapper.address,diemWrapperAbi,'reconcile',[hash32(agentId)]);}
  async createAccount(input){if(this.pins.sourceChainId===1)throw Error('Create the agent account on Ethereum and relay its canonical authority.');return super.createAccount(input);}
  async finalizeBrain(agentId){if(this.pins.sourceChainId!==1)throw Error('Use the canonical Ethereum-to-Base brain deployment.');await this.check();return this.transact(this.market,brainAbi,'finalize',[hash32(agentId)]);}
  async mintCredits(){throw Error('Wrap DIEM with NoerraAgentDiem. nDIEM is not a dollar credit.');}
  async activateCredits(){throw Error('Allocate DIEM with NoerraAgentDiem. nDIEM is not a dollar credit.');}
}

/** Atomic launch with USDC hosting funds and permanently activated renewable
 * compute. Both market views retain independently checked deployment pins.
 */
export class NoerraDualMarket extends NoerraDiemMarket {
  constructor(options){
    super(options);
    for(const name of ['credits','dollar','cashDeployer'])if(!options.pins[name]||!/^0x[a-f0-9]{64}$/i.test(options.pins[name].codeHash||''))throw Error('Pin the dual cash market and credit backing.');
    this.pins=structuredClone(options.pins);this.cashDollar=structuredClone(options.pins.dollar);this.side='brain';this.quoteToken=this.pins.wrapper.address;
  }
  async check(){
    await NoerraDiemMarket.prototype.check.call(this);
    for(const name of ['credits','dollar','cashDeployer']){const pin=this.pins[name];if(keccak256(await this.public.getBytecode({address:pin.address}))!==pin.codeHash)throw Error('Dual '+name+' bytecode differs from its pin.');}
    for(const name of ['credits','cashDeployer'])if(getAddress(await this.readAt(this.market,dualLaunchAbi,name))!==getAddress(this.pins[name].address))throw Error('Dual launch wiring changed.');
    for(const name of ['wrapper','manager'])if(getAddress(await this.readAt(this.pins.cashDeployer.address,diemDeployerAbi,name))!==getAddress(this.pins[name].address))throw Error('Cash builder wiring changed.');
    if(getAddress(await this.readAt(this.pins.credits.address,creditsAbi,'dollar'))!==getAddress(this.pins.dollar.address)||getAddress(await this.readAt(this.pins.credits.address,creditsAbi,'registry'))!==getAddress(this.pins.registry.address)||await this.readAt(this.pins.dollar.address,erc20Abi,'decimals')!==6)throw Error('Dual credit backing changed.');
  }
  selectMarket(side){
    if(!['cash','brain'].includes(side))throw Error('Choose the cash or brain market.');
    this.side=side;this.marketFunction=side==='cash'?'cashLaunches':'launches';this.quoteDecimals=side==='cash'?6:18;this.rewardDecimals=this.quoteDecimals;
    // Trading inherited from the wallet SDK reads the selected quote token.
    this.quoteToken=side==='cash'?this.cashDollar.address:this.pins.wrapper.address;
    return this;
  }
  async launch(agentId,{name,symbol,cashSeed,diemSeed,activation='0.1',operatingCash,startupGas='0.001',acknowledgePermanentLiquidity=false}){
    if(acknowledgePermanentLiquidity!==true)throw Error('Acknowledge permanent liquidity and activation before launch.');
    // Keep the deployment dollar pin distinct from the active trading quote.
    await this.check(); const id=hash32(agentId),cash=amount(cashSeed,6),brain=amount(diemSeed,18),locked=amount(activation,18),operating=amount(operatingCash,6);
    if(cash<100_000_000n||cash>1_000_000_000_000n||brain<100_000_000_000_000n||brain>100_000n*10n**18n||locked<10n**17n)throw Error('Supply the required cash, nDIEM and permanent activation funds.');
    if(typeof name!=='string'||!name.trim()||name.length>48||typeof symbol!=='string'||!symbol.trim()||symbol.length>12)throw Error('Choose a valid token name and symbol.');
    const account=await this.readAt(this.pins.registry.address,registryAbi,'accounts',[id]);
    if(account===zero||getAddress(await this.readAt(account,accountAbi,'human'))!==this.owner)throw Error('Only the agent owner can launch.');
    if(operating<(await this.readAt(account,accountAbi,'hostingReserve'))+10_000_000n)throw Error('Fund the hosting reserve and startup cash.');
    const gas=amount(startupGas,18);if(gas<100_000_000_000_000n||gas>10_000_000_000_000_000n)throw Error('Fund 0.0001–0.01 ETH of startup gas.');
    await this.approveExact(this.cashDollar.address,this.market,cash+operating);await this.approveExact(this.pins.wrapper.address,this.market,brain+locked);
    return this.transact(this.market,dualLaunchAbi,'launch',[id,name,symbol,{cashSeed:cash,diemSeed:brain,activation:locked,operatingCash:operating}],{value:gas});
  }
  mintCredits(dollars){return NoerraAgentChain.prototype.mintCredits.call(this,dollars);}
  activateCredits(agentId,dollars){return NoerraAgentChain.prototype.activateCredits.call(this,agentId,dollars);}
}
