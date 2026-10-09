export interface AgentConfiguration {
  name: string; purpose: string; model: string;
  avatar?: string | null;
  description?: string; category?: 'research' | 'writing' | 'character' | 'building' | 'other';
  dailyMicros: number; requestMicros: number;
  tools: ('memory' | 'journal' | 'web' | 'computer')[]; intervalMs?: number;
  publicProfile?: boolean; autoJournal?: boolean;
  surplus?: {enabled: boolean; keepMicros: number; maximumUnits: number; afterHour: number} | null;
  lab?: LabPolicy | null;
  chat?: {enabled: boolean; /** Legacy saved configuration only; room identity uses name and description. */ publicPrompt?: string; minimumTokens: number; dailyMicros: number; walletDailyMicros: number} | null;
}
export interface AgentEntry { id: string; text: string; at: number; source: string; published?: boolean; }
export function newRoomRequestId(now?:number):string;
export interface BackerRoomMessage {id:string;sequence:number;wallet:`0x${string}`;text:string;at:number;reply:null|{status:'pending'|'completed'|'uncertain'|'unavailable'|'invalid-output'|'cancelled';answer?:string};}
export interface BackerRoomPage {messages:BackerRoomMessage[];nextBefore:number|null;limits:{messageCharacters:number;retainedMessages:number};mention:'@agent';}
export interface LabPolicy {enabled:true;mission:string;sources?:string[];intervalMs?:number;maximumDailyTasks?:number;autoResearch?:boolean;autoPublish?:boolean;acceptSuggestions?:boolean;autoAccept?:boolean;}
export interface LabIdea {id:string;title:string;brief:string;status:'pending'|'queued'|'running'|'completed'|'blocked'|'rejected';at:number;reportId?:string;}
export interface LabReport {id:string;ideaId:string;title:string;text:string;at:number;sources:{url:string;sha256:string}[];execution:AgentRun['execution']|null;}
export interface PublicLab {enabled:true;mission:string;acceptSuggestions:boolean;ideas:LabIdea[];reports:LabReport[];}
export interface OwnedLab {version:1;ideas:(LabIdea&{wallet:string;runId?:string})[];reports:(LabReport&{published:boolean})[];days:Record<string,number>;nextAt:number;}
export interface AgentRun {
  id: string; prompt: string; status: 'reserved' | 'dispatched' | 'uncertain' | 'cancelled' | 'completed' | 'invalid-output' | 'archived';
  cap: number; actualMicros?: number; answer?: string; at: number; sources?: {url: string; sha256: string}[];
  backer?: `0x${string}`;
  publicContext?: boolean;
  publicSources?: boolean;
  labContext?: boolean;labReport?:string;
  execution?: {harness: 'noerra-bounded' | 'hermes-metered'; steps: number; reason: 'finished' | 'limit' | 'interrupted' | 'tool-denied' | 'invalid-output'};
}
export interface AgentMarketMetrics {
  fdvUsd:string; marketCapUsd:string; priceUsd:string; totalSupply:string;
  circulatingSupply:string; excludedBackedSupply:string; excludedDeadSupply:string;
  marketCapBasis:'fixed-supply-less-permanent-backing-and-dead';
  source:'ethereum-cash-pool'; basis:'total-supply'; symbol:string; at:number; block:string;
}
export interface AgentProfile {
  id: string; name: string; model: string; status: string;
  mode: 'synthetic' | 'production'; createdAt: number; generation: number;
  publicProfile: boolean; journal: AgentEntry[]; pulse: number;
  avatar: boolean;
  socialLinks?:{provider:'x';username:string;url:string}[];
  marketMetrics?: AgentMarketMetrics|null;
  description: string; category: string;
  chat: {enabled: true; minimumTokens: number} | null;
  market: {kind?:'platform-noerra';token?:string;locker?:string;chainId: number; agentId: `0x${string}`; account: `0x${string}`} | null;
  media?: PublishedMedia[];
  remixes?: {enabled:boolean};
  lab?: PublicLab|null;
}
export interface AgentTelegramConnection {
  provider: 'telegram'; username: string; status: 'pairing' | 'paired'; enabled: boolean;
  pairedChat: string | null;
  expiresAt: number | null; lastCheckedAt: number; problem: string | null;
  deliveries: {requestId: string; status: string; at: number; sentAt?: number}[];
}
export interface AgentComputer {
  status: string; provider: string | null; leaseId: string | null;
  fundingAddress?: string | null; providerAddress?: string | null;
  generation?: number; deposit?: number; denom?: 'uact';
  pricePerBlock?: string | null; remainingBlocks?: number | null;
  checkedAt?: number | null; fundingRequired?: boolean;
}
export interface AgentGasFunding {
  enabled: boolean; spentMicros: string;
  pending: {id:string;stage:'withdraw'|'approve'|'swap'|'clear';hash:string|null}|null;
  receipts: {id:string;swapHash?:string;withdrawalHash?:string;status:'failed'|'refilled';dollars:string;ethWei:string;at:number}[];
}
export interface OwnedAgent extends Omit<AgentProfile,'media'|'lab'> {
  lab?:OwnedLab|null;
  fundedActivation?: {stage:'waiting'|'started'|'cancelled';policy:string;createdAt:number;at?:number}|null;
  media: AgentMediaJob[];
  remixRequests?: RemixRequest[];
  owner: string; steward?: string; autonomousCoreLocked?: boolean; config: AgentConfiguration; cashMicros: number; creditMicros: number;
  creditDay: number; heldCashMicros: number; heldCreditMicros: number; todayMicros: number;
  memory: AgentEntry[]; drafts: AgentEntry[]; runs: AgentRun[]; nextAt: number;
  computer: AgentComputer;
  checkpoint: { hash: string; at: number; generation: number; storage?: 'arweave'; id?: string; digest?: string; chainHash?: `0x${string}` } | null;
  flagship?:boolean; sleeping?: boolean; runtimeAuthority?: boolean; activation?:{requestId:string;agentId:string;createdAt:number;requirements:Record<string,unknown>}|null; budgets?:{transactionHash:string;dollars:string;finalized:true}[];
  sourceAccount?: OwnedAgent['chainAccount'];
  automaticActivation?: {requestId:string;transactionHash:string;intent:import('./agent-chain.js').AutomaticActivationIntent;requirements:Record<string,unknown>;state:'waiting-launch'|'waiting-fees'|'waiting-operator'|'starting'|'started'|'waiting-reconciliation'|'cancelled'|'expired'|'revoked';createdAt:number;balanceMicros?:string;collectionStatus?:string;cancellationHash?:string;renewable?:boolean;feeBudget?:{kind:'trading-fees';chainId:1;transactionHash:string;blockNumber:string;blockHash:string;locker:string;account:string;agentCashMicros:string;dollars:string;finalized:true;state:'treasury-funded';runtime:'activation-pending'}}|null;
  sleepingMarket?: {kind?:'platform-noerra';chainId:1;transactionHash:string;token:string;locker:string;backers:string|null;bridgeReserve:string;baseToken:string;allocation?:'ethereum-only';baseState:'not-required'|'not-observed'|'pending'|'finalized';state:'sleeping';finalized:true;progress?:{sourceChainId:1;providerChainId:8453;sourceBlock?:string;baseBlock?:string;allocation?:'ethereum-only';authority:'ethereum'|'pending'|'finalized';tokenDelivery:'not-required'|'pending'|'finalized';brainMarket:'not-required'|'pending'|'finalized';providerQuota:'not-observed';computer:'not-started';state:'sleeping'}}|null;
  chainAccount: {chainId: number; account: `0x${string}`; agentId: `0x${string}`; owner: `0x${string}`; signer: `0x${string}`; generation: string; buildHash: `0x${string}`; creationHash: `0x${string}`} | null;
  connections: (AgentTelegramConnection | AgentSocialConnection)[]; mediaAutomation?:MediaAutomation|null;
}
export interface AgentLaunch {agentId:string;requestId:string;status:'accepted'|'predicted'|'prepared'|'committing'|'booting'|'ready'|'transferred'|'closed'|'expired';createdAt:number;expiresAt:number;sourceTransfer?:boolean;sourceBound?:boolean;}
export interface RecoveryTerms {recipient:`0x${string}`;reimbursementMicros:string;bountyMicros:string;leaseCommitment:`0x${string}`;deadline:number;}
export interface RecoveryBudgetPolicy {
  maximumReimbursementMicros:string; bountyMicros:string; targetMicros:string;
}
export interface SourceBudgetPolicy {
  minimumFundingMicros:string; dailyLimitMicros:string; hostingReserveMicros:string;
  immutableReserveMicros:string; bootstrapMicros:string; operatingMicros:string;
  hostingTargetMicros:string; gasMicros:string; recovery?:RecoveryBudgetPolicy;
}
export interface RecoveryJob {jobId:`0x${string}`;operationId:string;status:string;scope:{agentId:string;owner:string};binding:NonNullable<OwnedAgent['chainAccount']>;source:{appId:string;composeHash:string;buildHash:string};latest:{sequence:number;digest:string;bindingHash:string};stream:string;lease:Record<string,string>|null;availableMicros:string;claim:{claimId:`0x${string}`;operator:string;terms:RecoveryTerms;leaseUntil:number;started:boolean;launch:Record<string,unknown>|null}|null;settlement?:Record<string,unknown>;}
export interface AgentModelAddition { id: string; model: string; provider: string; }
export interface AgentModelGrant { agentId: string; owner: string; revision: number; previousHash: string; additions: AgentModelAddition[]; expiresAt: number; }
export interface AgentCatalogModel { id: string; name: string; inputPrice: number; outputPrice: number; context: number; privacy: string; inferenceProvider: string; }
export interface AgentModelCatalog { agentId: string; revision: number; hash: string; policyHash: string; models: AgentCatalogModel[]; checkedAt: number; paidAvailabilityTested: false; }
export interface AgentModelCatalogPreview { grant: AgentModelGrant; typedData: {domain: {name: string; version: string; chainId: number; salt: string}; types: Record<string, {name: string; type: string}[]>; primaryType: string; message: {agentId: string; owner: string; revision: number; previousHash: string; additionsHash: string; expiresAt: number}}; models: AgentCatalogModel[]; checkedAt: number; paidAvailabilityTested: false; }
export class NoerraAgentsClient {
  owner?:string|null;
  suggestIdea(id:string,input:{requestId:string;title:string;brief:string;publicConsent:true}):Promise<LabIdea|{id:string;status:string;at:number;archived:true}>;
  reviewIdea(id:string,ideaId:string,action:'accept'|'reject'):Promise<LabIdea>;
  researchIdea(id:string,ideaId:string):Promise<LabIdea>;
  publishLabReport(id:string,reportId:string):Promise<LabReport&{published:boolean}>;
  constructor(options: { origin: string; fetcher?: typeof fetch });
  launch(config:AgentConfiguration,requestId:string):Promise<AgentLaunch>;
  launchStatus(id:string):Promise<AgentLaunch>;
  launches():Promise<{launches:AgentLaunch[]}>;
  config(): Promise<{ ownerModelCatalog?:boolean; publicOrigin?:string; flagship?:import('./agent-ecosystem.js').FlagshipDescriptor|null; dedicatedLaunch?: boolean; sleepingMarkets?: boolean; fundedActivation?: boolean; operatorRecovery?:boolean; mode: 'synthetic' | 'production'; models: { id: string; name?: string }[]; tools: string[]; auth: string; externalTools: boolean; funding: boolean; recovery: boolean; remoteCheckpoints: boolean; telegram: boolean; social: boolean; socialOAuth?:{callback:string}|null; media: {models: Record<'image'|'video'|'audio',string[]>&{imageEdit?:string[]};maximumRequestMicros:number}|null; computePool: boolean; computeSupplier?: boolean; computers: {provider: string; denom: string; minimumDeposit: number; maximumDeposit: number} | null; privacy: string }>;
  directory(): Promise<{ agents: AgentProfile[] }>;
  publicProfile(id:string): Promise<AgentProfile>;
  publicStewardship(id:string): Promise<{version:1;binding:import("./agent-chain.js").AutomaticActivationBinding;steward:string;autonomousCoreLocked:boolean;proposedHuman:string;blockNumber:string;blockHash:string}>;
  computeStatus(): Promise<{epoch:number;expiresAt:number;priceMicros:number;availableUnits:number;pins:import('./agent-compute.js').ComputePoolPins}>;
  computeListing(id:string,units:number):Promise<import('./agent-compute.js').ComputeListing>;
  computeRun(input:{orderId:`0x${string}`;requestId:string;model:string;task:string}):Promise<ComputeResult>;
  computeRecover(input:{orderId:`0x${string}`;requestId:string}):Promise<ComputeResult>;
  recoveryJobs():Promise<{jobs:RecoveryJob[]}>;
  recoveryStatus(jobId:`0x${string}`):Promise<RecoveryJob>;
  requestRecovery(id:string):Promise<RecoveryJob|{status:'current';agentId:string}>;
  claimRecovery(wallet:{request(options:{method:string;params:unknown[]}):Promise<string>},jobId:`0x${string}`,terms:RecoveryTerms):Promise<RecoveryJob>;
  beginRecovery(wallet:{request(options:{method:string;params:unknown[]}):Promise<string>},input:{jobId:`0x${string}`;claimId:`0x${string}`;launch:{appId:string;composeHash:string;operationId:string;nonce:string}}):Promise<RecoveryJob>;
  renewRecovery(wallet:{request(options:{method:string;params:unknown[]}):Promise<string>},input:{jobId:`0x${string}`;claimId:`0x${string}`}):Promise<RecoveryJob>;
  releaseRecovery(wallet:{request(options:{method:string;params:unknown[]}):Promise<string>},input:{jobId:`0x${string}`;claimId:`0x${string}`}):Promise<RecoveryJob>;
  recoveryEvidence(action:'lease'|'reservation'|'success'|'complete',input:Record<string,unknown>):Promise<RecoveryJob>;
  computer(id: string,input: {action: 'prepare' | 'provision' | 'reconcile' | 'close'; deposit?: number; maximumPrice?: string}): Promise<OwnedAgent>;
  chatHistory(id: string): Promise<{messages: Pick<AgentRun,'id'|'status'|'at'|'prompt'|'answer'|'actualMicros'>[]}>;
  chat(id: string,task: string,requestId: string): Promise<Pick<AgentRun,'id'|'status'|'at'|'prompt'|'answer'|'actualMicros'>>;
  roomMessages(id:string,page?:{before?:number;limit?:number}):Promise<BackerRoomPage>;
  sendRoom(id:string,text:string,requestId:string):Promise<{message:BackerRoomMessage;duplicate:boolean}>;
  recoverRoom(id:string,requestId:string):Promise<{message:BackerRoomMessage;duplicate:true}>;
  connect(wallet: { request(options: { method: string; params: unknown[] }): Promise<string> }, address: string): Promise<{ owner: string; expiresAt: number }>;
  connectSynthetic(): Promise<{ owner: string; expiresAt: number }>;
  disconnect(): Promise<void>; list(): Promise<{ agents: OwnedAgent[] }>;
  startSleeping(id:string,requestId:string):Promise<AgentLaunch>;
  sleepingStatus(id:string):Promise<OwnedAgent>;
  sleepingPolicy(id:string):Promise<{chainId:1;providerChainId:8453;minimumBudgetMicros:string;hostingReserveMicros:string;dailyLimitMicros:string;bootstrapMicros:string;hostingMicros:string;cashMicros:string;gasRefillMicros:string;recoveryReserveMicros:string;startupGasWei:string;networkGas:'additional';activation:'pending-finalized-evidence'}>;
  quoteAutomaticActivation(id:string,expiresAt?:number):Promise<import('./agent-chain.js').AutomaticActivationIntent&{requirements:Record<string,unknown>;state:string;renewable?:boolean;replaces?:{transactionHash:string;requestId:string;intentHash:string}}>;
  bindAutomaticActivation(id:string,input:{transactionHash:`0x${string}`;requestId:string;expiresAt:number}):Promise<OwnedAgent>;
  cancelAutomaticActivation(id:string,input:{transactionHash:`0x${string}`}):Promise<OwnedAgent>;
  acceptSourceAccount(id:string,input:{creationHash:string;nonce:string;destination:string}):Promise<{hardwareVerified:true;nonce:string;destination:`0x${string}`;buildHash:`0x${string}`;scope:{agentId:string;owner:string};binding:NonNullable<OwnedAgent['chainAccount']>;nextSigner:`0x${string}`;acceptance:`0x${string}`;requiredRecipients:`0x${string}`[];sourceBudgetPolicy:SourceBudgetPolicy}>;
  bindTransferredSource(id:string,evidence:{creationHash:string;handoverHash:string;destination:string}):Promise<NonNullable<OwnedAgent['chainAccount']>>;
  createFlagship(config:AgentConfiguration,requestId:string):Promise<OwnedAgent>;
  createSleeping(config:AgentConfiguration,requestId:string):Promise<OwnedAgent>;
  bindSleepingAccount(id:string,transactionHash:`0x${string}`):Promise<OwnedAgent>;
  bindSleepingBudget(id:string,transactionHash:`0x${string}`):Promise<OwnedAgent & {budget:{transactionHash:string;chainId:1;account:string;dollars:string;ethSpent:string;ethRefunded:string;nonce:string;finalized:true;state:'treasury-funded';runtime:'activation-pending'}}>;
  bindSleepingMarket(id:string,transactionHash:`0x${string}`):Promise<OwnedAgent>;
  create(config: AgentConfiguration): Promise<OwnedAgent>; get(id: string): Promise<OwnedAgent>;
  modelCatalog(id: string): Promise<AgentModelCatalog>;
  previewModelCatalog(id: string, additions: AgentModelAddition[]): Promise<AgentModelCatalogPreview>;
  approveModelCatalog(id: string, grant: AgentModelGrant, signature: string): Promise<AgentModelCatalog>;
  update(id: string, config: AgentConfiguration): Promise<OwnedAgent>;
  control(id: string, action: 'start' | 'pause'): Promise<OwnedAgent>;
  run(id: string, task: string, requestId: string): Promise<AgentRun>;
  fund(id: string, evidence: unknown): Promise<OwnedAgent>;
  funding(id: string): Promise<{ bootstrap?:{enabled:boolean;sourceChainId:1;providerChainId:8453;status:string;gasStage?:string|null;diemStage?:string|null;providerQuotaConfirmed:boolean;paymentRoute?:string}|null; chainId: number; asset: string; token: string; recipient: string; runtimeSigner?: string; fundingMode?: 'surplus-cash' | 'prepaid-usdc' | 'vault-diem' | 'vault-diem-with-cash'; vaultPolicy?: Record<string,unknown> | null; minimumMicros: number; reserveMicros: number; privacy: string; gas?: AgentGasFunding | null; hosting?: {enabled:boolean;status:string;spentMicros:string;gasReservedWei:string;pending:{id:string;stage:string;hash:string|null}|null;receipts:unknown[]}|null; accountPolicy: Record<string,unknown> | null; binding: OwnedAgent['chainAccount']; renewable?: {source: 'provider-diem-balance'; allowance: {creditMicros: number; providerMicros: number; creditDay: number; observedAt: number; expiresAt: number} | null} | null }>;
  bindAccount(id: string,transactionHash: `0x${string}`): Promise<{chainId: number; account: string; agentId: string; owner: string; signer: string; generation: string; buildHash: string; creationHash: string}>;
  reconcile(id: string, requestId: string): Promise<AgentRun>;
  publish(id: string, draftId: string): Promise<AgentEntry>;
  backup(id: string): Promise<{ encrypted: string; hash: string; at: number; generation: number }>;
  remoteCheckpoint(id: string,options?: {reconcile?: boolean}): Promise<NonNullable<OwnedAgent['checkpoint']>>;
  restoreRemote(id: string): Promise<OwnedAgent>;
  connectTelegram(id: string,token: string): Promise<AgentTelegramConnection & {pairingUrl: string}>;
  controlTelegram(id: string,action: 'enable' | 'disable' | 'disconnect' | 'dismiss-delivery' | 'retry-delivery',requestId?: string): Promise<AgentTelegramConnection | null>;
  beginSocialOAuth(id:string,input:{clientId:string;clientSecret?:string;username:string;media?:boolean}):Promise<{url:string;callback:string;expiresAt:number}>;
  connectSocial(id:string,token:string,refresh?:SocialRefreshInput):Promise<AgentSocialConnection>;
  disconnectSocial(id:string):Promise<AgentSocialConnection>;
  publishSocial(id:string,input:{requestId:string;text:string;reviewedSha256:string;replyTo?:string|null;media?:{requestId:string;sha256:string}}):Promise<SocialPost>;
  recoverSocial(id:string,input:{requestId:string;postId?:string}):Promise<SocialPost>;
  /** Explicit owner renewal of a completed, unposted original reply; never regenerates inference. */
  recoverSocial(id:string,input:{requestId:string;resumeReply:true}):Promise<{requestId:string;status:'drafting';replyTo:string;resumed:true}>;
  automateSocial(id:string,input:SocialAutomationInput):Promise<AgentSocialConnection>;
  automateSocialReplies(id:string,input:SocialReplyPolicyInput):Promise<AgentSocialConnection>;
  generateMedia(id:string,input:MediaInput):Promise<AgentMediaJob>;
  recoverMedia(id:string,requestId:string):Promise<AgentMediaJob>;
  publishMedia(id:string,requestId:string,published:boolean):Promise<AgentMediaJob>;
  mediaAsset(id:string,requestId:string):Promise<{metadata:MediaMetadata;base64:string}>;
  automateMedia(id:string,input:MediaAutomationInput):Promise<MediaAutomation|null>;
  requestRemix(id:string,input:RemixInput):Promise<RemixRequest>;
  myRemixes(id:string):Promise<{requests:RemixRequest[]}>;
  configureRemixes(id:string,enabled:boolean):Promise<{enabled:boolean}>;
  reviewRemix(id:string,input:{requestId:string;action:'generate'|'reject';model?:string;maximumMicros?:number}):Promise<RemixRequest>;
  archive(id: string, requestIds?: string[]): Promise<{ archived: number; runs: AgentRun[] }>;
  restore(encrypted: string): Promise<OwnedAgent>; forget(id: string, memoryId: string): Promise<void>;
  restoreMemory(snapshot: unknown): Promise<OwnedAgent>;
}
export interface ComputeResult {requestId:string;orderId:`0x${string}`;status:'dispatched'|'uncertain'|'awaiting-settlement'|'completed'|'not-dispatched'|'reverted'|'refundable';actualMicros:number;chargedUnits:number;answer?:string;transactionHash?:`0x${string}`;cashbackMicros?:number;}

export interface SocialPost {requestId:string;text:string;replyTo?:string|null;status:'sending'|'processing'|'published'|'uncertain'|'rejected';at:number;postId?:string;failure?:{category:'credits-required'|'rate-limit'|'auth'|'access'|'invalid'|'rejected';httpStatus?:number;at:number};media?:{requestId:string;sha256:string;mime:string;size:number};upload?:{status:string;mediaId?:string;expiresAt?:number;nextCheckAt?:number};}
export interface SocialRefreshInput {clientId:string;refreshToken:string;clientSecret?:string;expiresAt?:number;scopes?:('users.read'|'tweet.read'|'tweet.write'|'offline.access'|'media.write')[];}
export interface SocialPublicIdentity {name:string;description:string;}
export interface AgentSocialConnection {provider:'x';username:string;userId:string;enabled:boolean;posts:SocialPost[];safety?:{replyApproved:boolean;blocked:boolean;cooldownUntil:number|null;reason:'rate-limit'|'authorization'|'credits-required'|null};authorization?:{renewable:boolean;expiresAt:number|null;error?:string}|null;automation?:SocialAutomationInput&{attempted:number;nextAt:number;pending:unknown;revision:number;publicIdentity?:SocialPublicIdentity}|null;replies?:SocialReplyPolicyInput&{attempted:number;nextAt:number;cursor:string|null;pending:unknown;mentions:SocialMention[];todayReplies:number;/** Dispatches in the current UTC-hour bucket; absent on older servers. */ currentHourReplies?:number;revision:number;publicIdentity?:SocialPublicIdentity;error?:string}|null;}
export type SocialPostingPolicyInput = {enabled:false}|{enabled:true;publicBrief:string;/** Integer milliseconds >=10,000; current time plus interval must remain a safe integer. */ intervalMs:number;/** Finite batch 1–128; continuous operation ignores the batch ceiling. */ maximumPosts:number;/** Creator-set positive safe integer per UTC day; omitted defaults to 3. */ maximumDailyPosts?:number;continuous?:boolean};
/** Backward-compatible name for the original-post scheduling policy. */
export type SocialAutomationInput = SocialPostingPolicyInput;
export type SocialReplyPolicyInput = {enabled:false}|{enabled:true;publicBrief:string;/** Integer milliseconds >=10,000; current time plus interval must remain a safe integer. */ intervalMs:number;/** Finite batch 1–10,000; continuous operation ignores the batch ceiling. */ maximumReplies:number;/** Creator-set positive safe integer per UTC day; omitted defaults to 12. */ maximumDailyReplies?:number;/** Positive safe integer per UTC-hour bucket; omitted or null adds no hourly cap. */ maximumHourlyReplies?:number|null;/** Minimum milliseconds between reply dispatch attempts. New policies default to 0; omission on renewal preserves approved spacing. */ minimumReplyIntervalMs?:number;continuous?:boolean;/** Owner-selected fresh cutoff: skips undrafted backlog without discarding original requests or delivery journals. */ startFromNow?:boolean};
export interface SocialMention {id:string;text:string;authorId:string;status:string;requestId?:string;postId?:string;}
export interface RemixInput {requestId:string;parentRequestId:string;brief:string;publicConsent:true;}
export interface RemixRequest {requestId:string;parentRequestId:string;brief:string;contributor:`0x${string}`;at:number;status:'pending'|'reviewing'|'rejected'|AgentMediaJob['status'];published:boolean;}
export interface MediaInput {requestId:string;kind:'image'|'video'|'audio';model:string;prompt:string;maximumMicros:number;useAvatar?:boolean;parentRequestId?:string;}
export interface MediaMetadata {mime:string;sha256:string;size:number;chunks:number;kind:MediaInput['kind'];}
export interface PublishedMedia {requestId:string;kind:MediaInput['kind'];model:string;asset:MediaMetadata;at:number;remix?:{parentRequestId:string;contributor:`0x${string}`;brief:string};}
export interface AgentMediaJob extends MediaInput {status:'reserved'|'dispatched'|'queued'|'awaiting-ledger'|'uncertain'|'cancelled'|'completed'|'billed-no-output';at:number;published:boolean;asset?:MediaMetadata;receipt?:{ledgerId:string;providerMicros:number;actualMicros:number;finalized:true};}
export type MediaAutomationInput = {enabled:false}|Omit<MediaInput,'requestId'>&{enabled:true;intervalMs:number;maximumJobs:number;publish:boolean};
export interface MediaAutomation {enabled:boolean;startedAt?:number;request:Omit<MediaInput,'requestId'>;intervalMs:number;maximumJobs:number;publish:boolean;attempted:number;nextAt:number;pending:MediaInput|null;}
