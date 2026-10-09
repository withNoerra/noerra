import {encodeAbiParameters,getAddress,keccak256,stringToHex} from 'viem';

const zeroHash='0x'+'0'.repeat(64),zeroAddress='0x'+'0'.repeat(40);
const digest=value=>{if(!/^0x[a-f0-9]{64}$/i.test(value||'')||value.toLowerCase()===zeroHash)throw Error('Use a nonzero activation commitment.');return value.toLowerCase();};
const address=value=>{const result=getAddress(value);if(result.toLowerCase()===zeroAddress)throw Error('Use a nonzero activation identity.');return result.toLowerCase();};
const integer=(value,maximum)=>{if(typeof value!=='string'||! /^(0|[1-9][0-9]{0,77})$/.test(value)||BigInt(value)>maximum)throw Error('Use exact bounded activation integers.');return BigInt(value);};
const seconds=value=>{if(!Number.isSafeInteger(value)||value<=0)throw Error('Use a Unix-seconds activation expiry.');return value;};

/** One browser/server representation. No coercion, getters or JSON omissions. */
export function canonicalActivationJson(value){
 const stack=new Set();let entries=0;
 const normalize=(item,depth)=>{
  if(++entries>20000||depth>32)throw Error('Bound the activation configuration.');
  if(item===null||typeof item==='string'||typeof item==='boolean')return item;
  if(typeof item==='number'){if(!Number.isSafeInteger(item)||Object.is(item,-0))throw Error('Use safe integer JSON numbers or exact decimal strings.');return item;}
  if(typeof item!=='object'||stack.has(item)||(!Array.isArray(item)&&Object.getPrototypeOf(item)!==Object.prototype&&Object.getPrototypeOf(item)!==null))throw Error('Use plain acyclic activation JSON.');
  stack.add(item);let result;
  if(Array.isArray(item)){if(Reflect.ownKeys(item).some(key=>key!=='length'&&!/^(0|[1-9][0-9]*)$/.test(String(key))))throw Error('Use plain JSON arrays.');result=[];for(let i=0;i<item.length;i++){const field=Object.getOwnPropertyDescriptor(item,String(i));if(!field||!('value'in field))throw Error('Use complete JSON arrays.');result.push(normalize(field.value,depth+1));}}
  else{result=Object.create(null);for(const key of Reflect.ownKeys(item).sort()){const field=Object.getOwnPropertyDescriptor(item,key);if(typeof key!=='string'||!field.enumerable||!('value'in field))throw Error('Use ordinary JSON data fields.');result[key]=normalize(field.value,depth+1);}}
  stack.delete(item);return result;
 };
 const json=JSON.stringify(normalize(value,0));if(new TextEncoder().encode(json).length>1048576)throw Error('Bound the activation configuration.');return json;
}
export const automaticActivationTemplateHash=template=>keccak256(stringToHex(canonicalActivationJson(template)));

export function automaticActivationIntent({binding,localId,config,template,minimumBalanceMicros,expiresAt,maximumStartupGasWei}){
 if(binding?.chainId!==1||binding.generation!=='1'||address(binding.owner)!==address(binding.signer)||! /^[a-f0-9]{32}$/.test(localId||''))throw Error('Use the original human-owned Ethereum source.');
 const minimum=integer(minimumBalanceMicros,100000n*1000000n),gas=integer(maximumStartupGasWei,10000000000000000n);if(minimum===0n||gas===0n)throw Error('Approve positive bounded activation funding and gas.');
 const validated=JSON.parse(canonicalActivationJson(config)),configHash=automaticActivationTemplateHash(validated),templateHash=automaticActivationTemplateHash(template);
 const intent={version:1,chainId:1,owner:address(binding.owner),account:address(binding.account),localId,agentId:digest(binding.agentId),buildHash:digest(binding.buildHash),config:validated,configHash,templateHash,minimumBalanceMicros:minimum.toString(),expiresAt:seconds(expiresAt),maximumStartupGasWei:gas.toString()};
 return {...intent,intentHash:automaticActivationTemplateHash(intent)};
}

/** EIP-191 payload used by the approved account and measured candidate signer. */
export function automaticActivationCommitment({binding,approval,nextSigner,destination}){
 if(binding?.chainId!==1)throw Error('Use the Ethereum activation domain.');
 const generation=integer(String(binding.generation),2n**256n-1n),nonce=integer(String(approval.policyNonce),2n**256n-1n);if(generation===0n||nonce===0n)throw Error('Pin the activation generation and approval nonce.');
 return keccak256(encodeAbiParameters(['bytes32','uint256','address','bytes32','uint256','bytes32','bytes32','uint256','uint256','uint256','uint256','address','bytes32'].map(type=>({type})),[
  keccak256(stringToHex('NOERRA_AUTOMATIC_ACTIVATION_V1')),1n,address(binding.account),digest(binding.agentId),generation,digest(binding.buildHash),digest(approval.intentHash),nonce,integer(approval.minimumBalanceMicros,100000n*1000000n),BigInt(seconds(approval.expiresAt)),integer(approval.maximumStartupGasWei,10000000000000000n),address(nextSigner),digest(destination)
 ]));
}
