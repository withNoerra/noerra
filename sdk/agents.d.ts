import type {EarnedDiemStatus} from './earned-diem.js';
/** Owner-visible computer supervision status (automatic upgrades are on by default with a 24 h soak; the owner may pause or veto). */
export interface ComputerSupervisionStatus {agentId:string;watched:true;initialSource:boolean;generation:string;lease:{dseq:string;provider:string}|null;recoveries:number;autoUpgrade?:{enabled:boolean;consentAt:number|null;soakSeconds:number;vetoed:string[];count:number;lastAt:number|null;byDefault:boolean};tier?:unknown;image?:unknown;wakes?:unknown;[key:string]:unknown}
export interface AgentConfiguration {
  creationMode?: 'agent-only' | 'agent-token';
  name: string; purpose: string; model: string;
  avatar?: string | null;
  description?: string; category?: 'research' | 'writing' | 'character' | 'building' | 'other';
  dailyMicros: number; requestMicros: number;
  tools: ('memory' | 'journal' | 'web' | 'computer' | 'integrations')[]; intervalMs?: number;
  publicProfile?: boolean; autoJournal?: boolean;
  surplus?: {enabled: boolean; keepMicros: number; maximumUnits: number; afterHour: number} | null;
  lab?: LabPolicy | null;
  /** Optional public voice card: style up to 200, up to six interests of 40, quirks and avoid up to 160 characters, without links. Setting or changing it changes the public identity hash, so native posting waits for re-approval. Absent or null means no voice card. */
  voice?: AgentVoice | null;
  /** Retired chat setting (removed 17 Oct 2026). Kept only so configuration hashes approved earlier stay identical; it has no effect. New agents have null. */
  chat?: unknown;
}
export interface AgentVoice {style?:string;interests?:string[];quirks?:string;avoid?:string}
export interface AgentEntry { id: string; text: string; at: number; source: string; published?: boolean; }
export interface NativePost {id:string;requestId:string;at:number;text:string;source:'native';media?:{requestId:string;kind:'image'|'video';model:string;asset:{sha256:string;mime:string;size:number}};}
export interface NativePostingInput {enabled:boolean;publicBrief?:string;intervalMs?:number;maximumDailyPosts?:number;/** Optional owner-approved event sources beyond the agent's own published work. */ events?:SocialEventSources;expectedRevision?:number;/** Change policy only while idle with the same last native request; null means no previous request. */expectedIdleLastRequestId?:string|null;shareToX?:boolean;quality?:SocialQualityPolicy;/** Fixed self-media (avatar edits), or generated images under the auto-scaled daily media budget (no fixed image count). */media?:{imageModel?:string;videoModel?:string;maximumDailyJobs:number;maximumJobMicros:number}|NativeMediaAutoBudget|null;}
export interface NativeMediaAutoBudget {budget:'auto';/** Share of the auto-scaled daily spend allowance, 100-5000 basis points (default 1000 = 10%). */shareBps?:number;}
export interface MediaBudgetStatus {allowanceMicros:number;shareBps:number;floorMicros:number;budgetMicros:number;usedMicros:number;remainingMicros:number;day:number;generationModels:string[];diemRoute:boolean;lanes:string[];}
export interface NativePostingStatus {policy:NativePostingInput;revision:number;nextAt:number|null;currentDayAttempts:number;currentDayPosts:number;currentDayMediaJobs?:number;pending:{requestId:string;at:number;status:string;mediaRequestId?:string}|null;posts:NativePost[];last:Record<string,unknown>|null;lastError?:{at:number;message:string}|null;/** Outcome and error counts (published, skipped, duplicate, invalid-output, media-unavailable, errors, ...). */counters?:Record<string,number>;/** Why a due post is not starting, when it is not. */blockedBy?:string|null;mediaBudget?:MediaBudgetStatus;}
export interface LabPolicy {enabled:true;mission:string;sources?:string[];intervalMs?:number;maximumDailyTasks?:number;autoResearch?:boolean;autoPublish?:boolean;acceptSuggestions?:boolean;autoAccept?:boolean;}
export interface LabIdea {id:string;title:string;brief:string;status:'pending'|'queued'|'running'|'completed'|'blocked'|'rejected';at:number;reportId?:string;}
export interface LabReport {id:string;ideaId:string;title:string;text:string;at:number;sources:{url:string;sha256:string}[];execution:AgentRun['execution']|null;}
export interface PublicLab {enabled:true;mission:string;acceptSuggestions:boolean;ideas:LabIdea[];reports:LabReport[];}
export interface OwnedLab {version:1;ideas:(LabIdea&{wallet:string;runId?:string})[];reports:(LabReport&{published:boolean})[];days:Record<string,number>;nextAt:number;}
export interface AgentRun {
  id: string; prompt: string; status: 'reserved' | 'dispatched' | 'uncertain' | 'cancelled' | 'completed' | 'invalid-output' | 'archived';
  cap: number; actualMicros?: number; answer?: string; at: number; sources?: {url: string; sha256: string}[];
  /** A Telegram group reply: the connected group and the member who asked. */
  telegramGroup?: {chatId: number; userId: number};
  publicContext?: boolean;
  publicSources?: boolean;
  labContext?: boolean;labReport?:string;
  execution?: {harness: 'noerra-bounded' | 'hermes-metered'; steps: number; reason: 'finished' | 'limit' | 'interrupted' | 'tool-denied' | 'invalid-output'};
}
export interface AgentRunReceipt {requestId:string;status:AgentRun['status'];publicContext:boolean;publicSources:boolean;actualMicros:number|null;receiptHash:string|null;completedAt:number|null;finalized:boolean;generation?:number;originalStatus?:AgentRun['status'];settlement?:{status:'pending'|'settled'|'blocked';finalized:boolean;acceptedMicros?:number;proofHash?:string};}
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
  socialActivity?:{at:number;postId:string;text:string;url:string;replyTo?:string}[];
  nativePosts?:NativePost[];
  marketMetrics?: AgentMarketMetrics|null;
  description: string; category: string;
  market: {kind?:'platform-noerra';token?:string;locker?:string;chainId: number; agentId: `0x${string}`; account: `0x${string}`} | null;
  media?: PublishedMedia[];
  remixes?: {enabled:boolean};
  lab?: PublicLab|null;
}
export interface TelegramGroupStatus {
  status: 'off' | 'pairing' | 'connected';
  group: {title: string} | null;
  /** While a connect link is open (also while switching from a connected group). */
  expiresAt: number | null;
  /** Today's group allowance: a share of the agent's daily budget; per person at most perUserDailyMicros and perUserHourlyMessages. */
  limits: {dailyMicros: number; usedTodayMicros: number; perUserDailyMicros: number; perUserHourlyMessages: number};
  /** 'uncertain-delivery' and 'rejected-delivery' wait for Dismiss or Retry. */
  deliveries: {requestId: string; status: 'queued' | 'running' | 'blocked' | 'ready' | 'sending' | 'sent' | 'uncertain-delivery' | 'rejected-delivery' | 'dismissed' | 'limited' | 'skipped' | 'expired' | 'withheld'; at: number}[];
}
export interface AgentTelegramConnection {
  provider: 'telegram'; username: string; status: 'pairing' | 'paired'; enabled: boolean;
  pairedChat: string | null;
  /** The one group this agent answers in (telegram-group). */
  group: TelegramGroupStatus;
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
  nativePosting?:NativePostingStatus|null;
  /** Media lanes (x402, prepaid), today's auto-scaled budget, last error and the reviewed media amendment state. */
  mediaStatus?:{lastError:{at:number;stage:string;message:string}|null;counters:Record<string,number>;budget:MediaBudgetStatus|null;lanes:string[];amendment:{version:2;state:string;sealedHash:string|null;refused:string|null;models?:{image:string[]};mediaPayment?:'x402'|'prepaid'}|null}|null;
  nativeCrossposts?:{posts:{nativePostId:string;requestId:string;status:string;at:number;reason?:string;postId?:string}[]}|null;
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
  reserveProvisioning?:{required:boolean;ready:boolean;state:string;earnedFeeAllocationBps?:1000;initialTargetDiemWei?:string;maximumDailyDiemWei?:string};
  sourceAccount?: OwnedAgent['chainAccount'];
  automaticActivation?: {requestId:string;transactionHash:string;intent:import('./agent-chain.js').AutomaticActivationIntent;requirements:Record<string,unknown>;state:'waiting-launch'|'waiting-fees'|'waiting-operator'|'starting'|'started'|'waiting-reconciliation'|'cancelled'|'expired'|'revoked';createdAt:number;balanceMicros?:string;collectionStatus?:string;cancellationHash?:string;renewable?:boolean;feeBudget?:{kind:'trading-fees';chainId:1;transactionHash:string;blockNumber:string;blockHash:string;locker:string;account:string;agentCashMicros:string;dollars:string;finalized:true;state:'treasury-funded';runtime:'activation-pending'}}|null;
  sleepingMarket?: {kind?:'platform-noerra';chainId:1;transactionHash:string;token:string;locker:string;/** The agent's auto-bound brain-fund escrow (new launches have no backers). */brainEscrow:string;bridgeReserve:string;baseToken:string;allocation?:'ethereum-only';baseState:'not-required'|'not-observed'|'pending'|'finalized';state:'sleeping';finalized:true;progress?:{sourceChainId:1;providerChainId:8453;sourceBlock?:string;baseBlock?:string;allocation?:'ethereum-only';authority:'ethereum'|'pending'|'finalized';tokenDelivery:'not-required'|'pending'|'finalized';brainMarket:'not-required'|'pending'|'finalized';providerQuota:'not-observed';computer:'not-started';state:'sleeping'}}|null;
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
  /** Current authenticated owner session; do not publish or log it. */
  token:string|null;
  suggestIdea(id:string,input:{requestId:string;title:string;brief:string;publicConsent:true}):Promise<LabIdea|{id:string;status:string;at:number;archived:true}>;
  reviewIdea(id:string,ideaId:string,action:'accept'|'reject'):Promise<LabIdea>;
  researchIdea(id:string,ideaId:string):Promise<LabIdea>;
  publishLabReport(id:string,reportId:string):Promise<LabReport&{published:boolean}>;
  constructor(options: { origin: string; fetcher?: typeof fetch });
  launch(config:AgentConfiguration,requestId:string):Promise<AgentLaunch>;
  launchStatus(id:string):Promise<AgentLaunch>;
  launches():Promise<{launches:AgentLaunch[]}>;
  config(): Promise<{ ownerModelCatalog?:boolean; publicOrigin?:string; flagship?:import('./agent-ecosystem.js').FlagshipDescriptor|null; dedicatedLaunch?: boolean; sleepingMarkets?: boolean; agentOnly?: boolean; fundedActivation?: boolean; operatorRecovery?:boolean; mode: 'synthetic' | 'production'; models: { id: string; name?: string }[]; tools: string[]; auth: string; externalTools: boolean; directIntegrations?:{configured:true;providers:string[];billing:'verified-provider-account'}|null; funding: boolean; recovery: boolean; remoteCheckpoints: boolean; telegram: boolean; social: boolean; socialOAuth?:{callback:string}|null; media: {models: Record<'image'|'video'|'audio',string[]>&{imageEdit?:string[]};maximumRequestMicros:number}|null; computePool: boolean; computeSupplier?: boolean; computers: {provider: string; denom: string; minimumDeposit: number; maximumDeposit: number} | null; privacy: string }>;
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
  connect(wallet: { request(options: { method: string; params: unknown[] }): Promise<string> }, address: string): Promise<{ owner: string; expiresAt: number }>;
  connectSynthetic(): Promise<{ owner: string; expiresAt: number }>;
  disconnect(): Promise<void>; list(): Promise<{ agents: OwnedAgent[] }>;
  startSleeping(id:string,requestId:string):Promise<AgentLaunch>;
  sleepingStatus(id:string):Promise<OwnedAgent>;
  sleepingReserveStatus(id:string):Promise<{required:boolean;ready:boolean;state:string;agentId:string;account?:string|null;message?:string}>;
  quoteSleepingReserve(id:string):Promise<Record<string,unknown>>;
  authorizeSleepingReserve(id:string,input:{signature:string}):Promise<Record<string,unknown>>;
  bindSleepingReserveReceipt(id:string,input:{transactionHash:`0x${string}`;stepId:string}):Promise<Record<string,unknown>>;
  checkSleepingReserve(id:string):Promise<{required:boolean;ready:true;agentId:string;account?:string;reviewedPlanHash?:string}>;
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
  earnedDiem(id:string):Promise<EarnedDiemStatus>;
  funding(id: string): Promise<{ startup?: {stage: 'funding-gas' | 'funding-transfer' | 'funding-provider'; chainId: 1 | 8453; transactionHash: string | null; destinationHash?: string | null; checkedAt?: number | null} | null; bootstrap?:{enabled:boolean;sourceChainId:1;providerChainId:8453;status:string;gasStage?:string|null;diemStage?:string|null;providerQuotaConfirmed:boolean;paymentRoute?:string}|null; chainId: number; asset: string; token: string; recipient: string; runtimeSigner?: string; fundingMode?: 'surplus-cash' | 'prepaid-usdc' | 'vault-diem' | 'vault-diem-with-cash'; vaultPolicy?: Record<string,unknown> | null; minimumMicros: number; reserveMicros: number; privacy: string; gas?: AgentGasFunding | null; hosting?: {enabled:boolean;status:string;spentMicros:string;gasReservedWei:string;pending:{id:string;stage:string;hash:string|null}|null;receipts:unknown[]}|null; accountPolicy: Record<string,unknown> | null; binding: OwnedAgent['chainAccount']; renewable?: {source: 'provider-diem-balance'; allowance: {creditMicros: number; providerMicros: number; creditDay: number; observedAt: number; expiresAt: number} | null} | null }>;
  bindAccount(id: string,transactionHash: `0x${string}`): Promise<{chainId: number; account: string; agentId: string; owner: string; signer: string; generation: string; buildHash: string; creationHash: string}>;
  runReceipt(id:string,requestId:string):Promise<AgentRunReceipt>; /** Owner only: archived runs newest first; offset counts back from the newest, limit 1..500. */ archivedRuns(id:string,page?:{offset?:number;limit?:number}):Promise<{total:number;offset:number;limit:number;runs:Record<string,unknown>[]}>;
  reconcile(id: string, requestId: string): Promise<AgentRun>;
  publish(id: string, draftId: string): Promise<AgentEntry>;
  backup(id: string): Promise<{ encrypted: string; hash: string; at: number; generation: number }>;
  remoteCheckpoint(id: string,options?: {reconcile?: boolean}): Promise<NonNullable<OwnedAgent['checkpoint']>>;
  restoreRemote(id: string): Promise<OwnedAgent>;
  /** Owner-requested computer image upgrade between two published releases (a paid operator move onto the new image). */
  upgradeComputer(id: string,input: {fromImage: string; fromVersion: string; toImage: string; toVersion: string}): Promise<Record<string,unknown>>;
  /** Automatic computer upgrades are on by default (24 h soak). {enabled:false} opts out, {enabled:true} opts back in, {vetoVersion} skips one release. */
  computerAutoUpgrade(id: string,choice: {enabled: boolean} | {vetoVersion: string}): Promise<ComputerSupervisionStatus>;
  /** GET status, or connect (returns the one-time add-to-group link, valid ten minutes), disconnect, and Dismiss/Retry for an unconfirmed group delivery. Requires a paired private chat. */
  telegramGroup(id:string,action?:'connect'|'disconnect'|'dismiss-delivery'|'retry-delivery',requestId?:string):Promise<TelegramGroupStatus&{pairingUrl?:string;command?:string}>;
  connectTelegram(id: string,token: string): Promise<AgentTelegramConnection & {pairingUrl: string}>;
  controlTelegram(id: string,action: 'enable' | 'disable' | 'disconnect' | 'dismiss-delivery' | 'retry-delivery',requestId?: string): Promise<AgentTelegramConnection | null>;
  /** media defaults to true; a runtime without images connects without media.write and returns mediaUnavailable with a notice. */
  beginSocialOAuth(id:string,input:{clientId:string;clientSecret?:string;username:string;media?:boolean}):Promise<{url:string;callback:string;expiresAt:number;media?:boolean;mediaUnavailable?:true;notice?:string}>;
  connectSocial(id:string,token:string,refresh?:SocialRefreshInput):Promise<AgentSocialConnection>;
  disconnectSocial(id:string):Promise<AgentSocialConnection>;
  publishSocial(id:string,input:{requestId:string;text:string;reviewedSha256:string;replyTo?:string|null;media?:{requestId:string;sha256:string}}):Promise<SocialPost>;
  recoverSocial(id:string,input:{requestId:string;postId?:string}):Promise<SocialPost>;
  /** Explicit owner renewal of a completed, unposted original reply; never regenerates inference. */
  recoverSocial(id:string,input:{requestId:string;resumeReply:true}):Promise<{requestId:string;status:'drafting';replyTo:string;resumed:true}>;
  automateSocial(id:string,input:SocialAutomationInput):Promise<AgentSocialConnection>;
  automateNativePosts(id:string,input:NativePostingInput):Promise<NativePostingStatus>;
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
export interface AgentSocialConnection {provider:'x';username:string;userId:string;enabled:boolean;posts:SocialPost[];/** Estimated X API spend today and this month (millionths of USD) with call counts; with a budget also its ceilings, whether it is reached, when X calls resume, the reserve kept for today's original post and how many more replies it funds today. */ xApi?:{spentTodayMicros:number;spentMonthMicros:number;calls:Record<string,number>;budget?:null;dailyBudgetMicros?:number;monthlyBudgetMicros?:number;reached?:boolean;resetsAt?:number;originalReserveMicros?:number;repliesFundedToday?:number;replyLinks?:boolean};safety?:{replyApproved:boolean;blocked:boolean;cooldownUntil:number|null;reason:'rate-limit'|'authorization'|'credits-required'|null};authorization?:{renewable:boolean;expiresAt:number|null;error?:string}|null;automation?:SocialAutomationInput&{attempted:number;nextAt:number;pending:unknown;revision:number;publicIdentity?:SocialPublicIdentity}|null;replies?:SocialReplyPolicyInput&{attempted:number;nextAt:number;cursor:string|null;pending:unknown;mentions:SocialMention[];todayReplies:number;/** Dispatches in the current UTC-hour bucket; absent on older servers. */ currentHourReplies?:number;revision:number;publicIdentity?:SocialPublicIdentity;error?:string}|null;}
/** Owner opt-in public event sources beyond the agent's own published work. Absent means none. */
export type SocialEventSources = {directory?:boolean;receipts?:boolean;changelog?:boolean;/** Platform feed of notable agents, protocol milestones and protocol updates (flagship-events.mjs), at most one a UTC day. */ flagship?:boolean;/** Draft originals only when an approved source has an event; own work does not count. Needs a source. */ eventsOnly?:boolean};
/** Absent or steady keeps the fixed interval; organic is a separate owner approval. */
export type SocialRhythm = {mode:'steady'}|{mode:'organic';/** 600,000 up to the posting interval. */ minimumGapMs:number;/** 0 to 0.25. */ burstChance?:number;/** Two different UTC hours. */ quietHoursUtc?:[number,number]};
export type SocialQualityPolicy = {mix?:'auto'|'flagship';/** Up to 40 phrases of 60 characters, no links. */ blocklist?:string[];/** Up to 24 explainer topics of 160 characters, no links. */ topics?:string[]};
export type SocialPostingPolicyInput = {enabled:false}|{enabled:true;publicBrief:string;/** Integer milliseconds >=10,000; current time plus interval must remain a safe integer. */ intervalMs:number;/** Finite batch 1–128; continuous operation ignores the batch ceiling. */ maximumPosts:number;/** Creator-set positive safe integer per UTC day; omitted defaults to 8. */ maximumDailyPosts?:number;continuous?:boolean;rhythm?:SocialRhythm;events?:SocialEventSources;/** Owner approval for one X read a day of the last twenty originals' public metrics; only clamped angle weights are kept. Absent means none. */ learning?:boolean;/** Shared quality system: optional content mix, blocked phrases and explainer topics. Absent means the automatic mix and derived motifs. */ quality?:SocialQualityPolicy};
/** Backward-compatible name for the original-post scheduling policy. */
export type SocialAutomationInput = SocialPostingPolicyInput;
export type SocialReplyPolicyInput = {enabled:false}|{enabled:true;publicBrief:string;/** Integer milliseconds >=10,000; current time plus interval must remain a safe integer. */ intervalMs:number;/** Finite batch 1–10,000; continuous operation ignores the batch ceiling. */ maximumReplies:number;/** Creator-set cap per UTC day (1-2,400). Omitted or null means automatic: half the agent's day-scaled budget at its observed reply cost, at least 12, within X's 2,400-a-day account limit and the observed X tier limit. */ maximumDailyReplies?:number|null;/** Positive safe integer per UTC-hour bucket; omitted or null adds no hourly cap. */ maximumHourlyReplies?:number|null;/** Minimum milliseconds between reply dispatch attempts. New policies default to 0; omission on renewal preserves approved spacing. */ minimumReplyIntervalMs?:number;continuous?:boolean;/** Owner-selected fresh cutoff: skips undrafted backlog without discarding original requests or delivery journals. */ startFromNow?:boolean;/** Phase 2 reply voice (owner approval, off by default): identity and voice card, verified-events rule, spam and instruction filters and the structural repeat check for replies. */ voice?:boolean;/** Which mentions are answered: requested (default, explicit questions and requests) or open (relevant mentions, model may decline; every paid draft counts against the reply ceilings). Needs voice. */ selection?:'requested'|'open';/** Event sources for voice replies. Needs voice. */ events?:SocialEventSources;/** 1-50 paid reply drafts per X account per UTC day; absent means no per-author limit. */ maximumDailyRepliesPerAuthor?:number;/** Optional ceiling on this connection's estimated X API spend per UTC day, in millionths of USD (X pay-per-use rates: post $0.015, post with a URL $0.20, $0.005 per post read, $0.010 per user read, $0.001 per owned read). When reached, polling, replies and posts stop until the next UTC day; today's one original post is reserved first. Absent means no X budget (the creator's own X app pays). */ xApiDailyBudgetMicros?:number|null;/** Optional monthly ceiling on the estimated X API spend, in millionths of USD; stops X calls until the next UTC month. */ xApiMonthlyBudgetMicros?:number|null;/** false keeps URLs and domain names out of replies (they become "the link in my bio"). Default true. */ replyLinks?:boolean;/** Shared quality system: optional blocked phrases. */ quality?:SocialQualityPolicy};
export interface SocialMention {id:string;text:string;authorId:string;status:string;requestId?:string;postId?:string;}
export interface RemixInput {requestId:string;parentRequestId:string;brief:string;publicConsent:true;}
export interface RemixRequest {requestId:string;parentRequestId:string;brief:string;contributor:`0x${string}`;at:number;status:'pending'|'reviewing'|'rejected'|AgentMediaJob['status'];published:boolean;}
export interface MediaInput {requestId:string;kind:'image'|'video'|'audio';model:string;prompt:string;maximumMicros:number;useAvatar?:boolean;parentRequestId?:string;}
export interface MediaMetadata {mime:string;sha256:string;size:number;chunks:number;kind:MediaInput['kind'];}
export interface PublishedMedia {requestId:string;kind:MediaInput['kind'];model:string;asset:MediaMetadata;at:number;remix?:{parentRequestId:string;contributor:`0x${string}`;brief:string};}
export interface AgentMediaJob extends MediaInput {status:'reserved'|'dispatched'|'queued'|'awaiting-ledger'|'uncertain'|'cancelled'|'completed'|'billed-no-output';at:number;published:boolean;asset?:MediaMetadata;receipt?:{ledgerId:string;providerMicros:number;actualMicros:number;finalized:true};}
export type MediaAutomationInput = {enabled:false}|Omit<MediaInput,'requestId'>&{enabled:true;intervalMs:number;maximumJobs:number;publish:boolean};
export interface MediaAutomation {enabled:boolean;startedAt?:number;request:Omit<MediaInput,'requestId'>;intervalMs:number;maximumJobs:number;publish:boolean;attempted:number;nextAt:number;pending:MediaInput|null;}
