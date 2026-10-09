export function newRoomRequestId(now=Date.now()){const seconds=Math.floor(now/1000);if(!Number.isSafeInteger(seconds)||seconds<1||seconds>0xffffffff)throw Error('Use a valid room message timestamp.');return seconds.toString(16).padStart(8,'0')+Array.from(crypto.getRandomValues(new Uint8Array(12)),value=>value.toString(16).padStart(2,'0')).join('');}
export class NoerraAgentsClient {
  constructor({ origin, fetcher = fetch }) {
    const url = new URL(origin);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1')) throw Error('Use HTTPS or loopback.');
    if (url.pathname !== '/' || url.username || url.password || url.search || url.hash) throw Error('Use a service origin.');
    this.origin = url.origin; this.fetcher = fetcher.bind(globalThis); this.token = null;
  }
  async request(path, input) {
    const response = await this.fetcher(this.origin + '/api/agents' + path, { method: input === undefined ? 'GET' : 'POST', redirect: 'error', credentials: 'omit', signal: AbortSignal.timeout(180000),
      headers: { ...(input === undefined ? {} : { 'content-type': 'application/json', ...(typeof window === 'undefined' ? { origin: this.origin } : {}) }), ...(this.token ? { authorization: 'Bearer ' + this.token } : {}) }, ...(input === undefined ? {} : { body: JSON.stringify(input) }) });
    let value; try { value = await response.json(); } catch { throw Error('Agent service is unavailable. Please try again shortly.'); }
    if (response.ok && value === null && input?.action === 'disconnect' && /^\/[a-f0-9]{32}\/telegram-control$/.test(path)) return null;
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Agent service returned an invalid response.');
    if (!response.ok) throw Error(typeof value.error === 'string' ? value.error : 'Agent service is unavailable. Please try again shortly.'); return value;
  }
  config() { return this.request('/config'); }
  directory() { return this.request('/directory'); }
  publicProfile(id) { return this.request('/public/'+this.id(id)); }
  publicStewardship(id){return this.request('/public/'+this.id(id)+'/stewardship');}
  computeStatus(){return this.request('/compute');}
  computeListing(id,units){return this.request('/'+this.id(id)+'/compute-list',{units});}
  computeRun(input){return this.request('/compute/run',input);}
  computeRecover(input){return this.request('/compute/reconcile',input);}
  recoveryJobs(){return this.request('/recovery/jobs');}
  recoveryStatus(jobId){return this.request('/recovery/jobs/'+this.recoveryId(jobId));}
  requestRecovery(id){return this.request('/'+this.id(id)+'/recover-computer',{});}
  recoveryId(value){if(!/^0x[a-f0-9]{64}$/.test(value||''))throw Error('Invalid recovery job identity.');return value;}
  async authorizeRecovery(wallet,action,input){
    if(!this.owner||!wallet?.request)throw Error('Connect the operator wallet first.');
    const challenge=await this.request('/recovery/'+action+'-challenge',{...input,operator:this.owner});
    const message='0x'+Array.from(new TextEncoder().encode(challenge.message),byte=>byte.toString(16).padStart(2,'0')).join('');
    const signature=await wallet.request({method:'personal_sign',params:[message,this.owner]});
    return this.request('/recovery/'+action,{...input,operator:this.owner,authorization:{nonce:challenge.nonce,signature}});
  }
  claimRecovery(wallet,jobId,terms){return this.authorizeRecovery(wallet,'claim',{jobId:this.recoveryId(jobId),terms});}
  beginRecovery(wallet,input){return this.authorizeRecovery(wallet,'begin',input);}
  renewRecovery(wallet,input){return this.authorizeRecovery(wallet,'renew',input);}
  releaseRecovery(wallet,input){return this.authorizeRecovery(wallet,'release',input);}
  recoveryEvidence(action,input){if(!['lease','reservation','success','complete'].includes(action))throw Error('Unsupported recovery evidence.');return this.request('/recovery/'+action,input);}
  chatHistory(id){return this.request('/public/'+this.id(id)+'/chat');}
  chat(id,task,requestId){return this.request('/public/'+this.id(id)+'/chat',{task,requestId});}
  roomMessages(id,{before,limit=30}={}){if(!Number.isSafeInteger(limit)||limit<1||limit>50||before!==undefined&&(!Number.isSafeInteger(before)||before<1))throw Error('Use a valid room page.');const query=new URLSearchParams({limit:String(limit),...(before===undefined?{}:{before:String(before)})});return this.request('/public/'+this.id(id)+'/room?'+query);}
  sendRoom(id,text,requestId){if(typeof text!=='string'||!text.trim()||text.length>1500||!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Use a message up to 1500 characters and a stable request ID.');return this.request('/public/'+this.id(id)+'/room',{text,requestId});}
  recoverRoom(id,requestId){if(!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Use the original room request ID.');return this.request('/public/'+this.id(id)+'/room/recover',{requestId});}
  suggestIdea(id,input){return this.request('/public/'+this.id(id)+'/lab-idea',input);}
  reviewIdea(id,ideaId,action){return this.request('/'+this.id(id)+'/lab-review',{ideaId:this.id(ideaId),action});}
  researchIdea(id,ideaId){return this.request('/'+this.id(id)+'/lab-run',{ideaId:this.id(ideaId)});}
  publishLabReport(id,reportId){return this.request('/'+this.id(id)+'/lab-publish',{reportId:this.id(reportId)});}
  async connect(wallet, address) {
    const challenge = await this.request('/challenge', { address });
    const data='0x'+Array.from(new TextEncoder().encode(challenge.message),value=>value.toString(16).padStart(2,'0')).join('');
    const signature = await wallet.request({ method: 'personal_sign', params: [data, address] });
    const result = await this.request('/authenticate', { nonce: challenge.nonce, signature }); this.token = result.token;this.owner=result.owner; return result;
  }
  async connectSynthetic() { const result = await this.request('/synthetic-session', {}); this.token = result.token;this.owner=result.owner; return result; }
  async disconnect() { try { if (this.token) await this.request('/logout', {}); } finally { this.token = null;this.owner=null; } }
  list() { return this.request(''); }
  create(config) { return this.request('', config); }
  createSleeping(config,requestId){if(!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Keep a stable sleeping market request ID.');return this.request('/sleeping',{config,requestId});}
  createFlagship(config,requestId){if(!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Keep a stable flagship setup request ID.');return this.request('/sleeping',{config,requestId,flagship:true});}
  sleepingPolicy(id){return this.request('/'+this.id(id)+'/sleeping-policy',{});}
  quoteAutomaticActivation(id,expiresAt){return expiresAt===undefined?this.request('/'+this.id(id)+'/automatic-activation'):this.request('/'+this.id(id)+'/automatic-activation-quote',{expiresAt});}
  bindAutomaticActivation(id,input){return this.request('/'+this.id(id)+'/automatic-activation',input);}
  cancelAutomaticActivation(id,input){return this.request('/'+this.id(id)+'/automatic-activation-cancel',input);}
  startSleeping(id,requestId){return this.request('/'+this.id(id)+'/sleeping-start',{requestId});}
  sleepingStatus(id){return this.request('/'+this.id(id)+'/sleeping-status',{});}
  bindSleepingAccount(id,transactionHash){return this.request('/'+this.id(id)+'/sleeping-account',{transactionHash});}
  bindSleepingBudget(id,transactionHash){return this.request('/'+this.id(id)+'/sleeping-budget',{transactionHash});}
  bindSleepingMarket(id,transactionHash){return this.request('/'+this.id(id)+'/sleeping-market',{transactionHash});}
  launch(config,requestId) {if(!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Use a stable launch request ID.');return this.request('/launch',{config,requestId});}
  launchStatus(id) {return this.request('/launch/'+this.id(id));}
  launches() {return this.request('/launch');}
  get(id) { return this.request('/' + this.id(id)); }
  modelCatalog(id){return this.request('/'+this.id(id)+'/model-catalog');}
  previewModelCatalog(id,additions){return this.request('/'+this.id(id)+'/model-catalog/preview',{additions});}
  approveModelCatalog(id,grant,signature){return this.request('/'+this.id(id)+'/model-catalog',{grant,signature});}
  update(id, config) { return this.request('/' + this.id(id) + '/configure', config); }
  control(id, action) { return this.request('/' + this.id(id) + '/control', { action }); }
  run(id, task, requestId) { return this.request('/' + this.id(id) + '/run', { task, requestId }); }
  fund(id, evidence) { return this.request('/' + this.id(id) + '/fund', evidence); }
  funding(id) { return this.request('/' + this.id(id) + '/funding', {}); }
  computer(id,input) {return this.request('/'+this.id(id)+'/computer',input);}
  acceptSourceAccount(id,input){return this.request('/'+this.id(id)+'/accept-source-account',input);}
  bindTransferredSource(id,evidence){return this.request('/'+this.id(id)+'/bind-source-account',evidence);}
  bindAccount(id,transactionHash) { return this.request('/' + this.id(id) + '/bind-account', {transactionHash}); }
  runReceipt(id,requestId){if(!/^[a-f0-9]{32}$/.test(requestId||''))throw Error('Use the original run request identity.');return this.request('/'+this.id(id)+'/run-receipt/'+requestId);}
  reconcile(id, requestId) { return this.request('/' + this.id(id) + '/reconcile', { requestId }); }
  publish(id, draftId) { return this.request('/' + this.id(id) + '/publish', { draftId }); }
  backup(id) { return this.request('/' + this.id(id) + '/backup', {}); }
  remoteCheckpoint(id,{reconcile=false}={}) { return this.request('/' + this.id(id) + '/remote-checkpoint', {reconcile}); }
  restoreRemote(id) { return this.request('/' + this.id(id) + '/restore-remote', {}); }
  connectTelegram(id,token) { return this.request('/' + this.id(id) + '/telegram-connect', {token}); }
  controlTelegram(id,action,requestId) { return this.request('/' + this.id(id) + '/telegram-control', {action,requestId}); }
  beginSocialOAuth(id,input){return this.request('/'+this.id(id)+'/social-x-begin',input);}
  connectSocial(id,token,refresh){return this.request('/'+this.id(id)+'/social-connect',{token,...(refresh?{refresh}:{})});}
  disconnectSocial(id){return this.request('/'+this.id(id)+'/social-disconnect',{});}
  publishSocial(id,input){return this.request('/'+this.id(id)+'/social-publish',input);}
  recoverSocial(id,input){return this.request('/'+this.id(id)+'/social-recover',input);}
  automateSocial(id,input){return this.request('/'+this.id(id)+'/social-automation',input);}
  automateNativePosts(id,input){return this.request('/'+this.id(id)+'/native-automation',input);}
  automateSocialReplies(id,input){return this.request('/'+this.id(id)+'/social-replies',input);}
  requestRemix(id,input){return this.request('/public/'+this.id(id)+'/remix',input);}
  myRemixes(id){return this.request('/public/'+this.id(id)+'/remix');}
  configureRemixes(id,enabled){return this.request('/'+this.id(id)+'/remix-policy',{enabled});}
  reviewRemix(id,input){return this.request('/'+this.id(id)+'/remix-review',input);}
  generateMedia(id,input){return this.request('/'+this.id(id)+'/media',input);}
  recoverMedia(id,requestId){return this.request('/'+this.id(id)+'/media-recover',{requestId});}
  publishMedia(id,requestId,published){return this.request('/'+this.id(id)+'/media-publish',{requestId,published});}
  mediaAsset(id,requestId){return this.request('/'+this.id(id)+'/media-asset',{requestId});}
  automateMedia(id,input){return this.request('/'+this.id(id)+'/media-automation',input);}
  archive(id, requestIds) { return this.request('/' + this.id(id) + '/archive', { requestIds }); }
  restore(encrypted) { return this.request('/restore', { encrypted }); }
  restoreMemory(snapshot) { return this.request('/restore-memory', { snapshot }); }
  forget(id, memoryId) { return this.request('/' + this.id(id) + '/forget', { memoryId }); }
  id(value) { if (!/^[a-f0-9]{32}$/.test(value || '')) throw Error('Invalid agent identity.'); return value; }
}
