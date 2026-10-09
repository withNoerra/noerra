export interface AgentChainPin { address: `0x${string}`; codeHash: `0x${string}`; }
export interface AgentChainPins {providerMode?:'cash-only'|'legacy-diem';cashDeployer?:AgentChainPin;launchProtectionHook?:AgentChainPin;ecosystemVault?:AgentChainPin;legacyQuoter?:AgentChainPin;baseBridge?:`0x${string}`;baseLaunchpad?:`0x${string}`;compatibilityTargets?:{deployed:false;registry:`0x${string}`;launchpad:`0x${string}`;standardBridge:`0x${string}`};}
export {NoerraEarnedDiem} from './earned-diem.js';
export {NoerraAgentDiem} from './agent-diem.js';
export {NoerraComputePool} from './agent-compute.js';
export {NoerraEcosystem,NoerraFlagshipMarket} from './agent-ecosystem.js';
export type {EcosystemPins,EcosystemStatus,NoerraLaunch,FlagshipDescriptor,FlagshipPolicy} from './agent-ecosystem.js';
export interface AgentChainPins { chainId: 1 | 31337; registry: AgentChainPin; credits: AgentChainPin; launchpad: AgentChainPin; dollar: AgentChainPin; manager: AgentChainPin; quoter?: AgentChainPin; launchMode?: 'sleeping';ethUsdFeed?:AgentChainPin;oracleMaximumAge?:number;buildHash?:`0x${string}`;operationsTreasury?:`0x${string}`; checkout?:AgentChainPin;fundingRouter?:AgentChainPin;fundingQuoter?:AgentChainPin;weth?:AgentChainPin;authorityMessenger?:AgentChainPin; }
export interface ChainCreation { agentId: `0x${string}`; locker: `0x${string}`; token: `0x${string}`; backers: `0x${string}`; account: `0x${string}`; liquidity: bigint; feeTokens: bigint; }
export interface DiemMarketPins { chainId: 8453 | 31337; sourceChainId?:1; registry: AgentChainPin; wrapper: AgentChainPin; diem: AgentChainPin; reader: AgentChainPin; launchpad: AgentChainPin; manager: AgentChainPin; deployer: AgentChainPin; quoter?: AgentChainPin; }
export function agentMetadataHash(id: string): `0x${string}`;
export interface AutomaticActivationBinding {chainId:1;owner:`0x${string}`;signer:`0x${string}`;account:`0x${string}`;agentId:`0x${string}`;buildHash:`0x${string}`;generation:string;}
export interface AutomaticActivationApproval {intentHash:`0x${string}`;policyNonce:string;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string;}
export interface AutomaticActivationIntent {version:1;chainId:1;owner:string;account:string;localId:string;agentId:`0x${string}`;buildHash:`0x${string}`;config:unknown;configHash:`0x${string}`;templateHash:`0x${string}`;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string;intentHash:`0x${string}`;approval?:AutomaticActivationApproval;}
export function canonicalActivationJson(value:unknown):string;
export function automaticActivationTemplateHash(value:unknown):`0x${string}`;
export function automaticActivationIntent(input:{binding:AutomaticActivationBinding;localId:string;config:unknown;template:unknown;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string}):AutomaticActivationIntent;
export function automaticActivationCommitment(input:{binding:AutomaticActivationBinding;approval:AutomaticActivationApproval;nextSigner:`0x${string}`;destination:`0x${string}`}):`0x${string}`;
export class NoerraAgentChain {
  automaticActivationPolicy(agentId:`0x${string}`):Promise<Omit<AutomaticActivationApproval,'expiresAt'>&{expiresAt:string;agentId:`0x${string}`;account:`0x${string}`;signer:`0x${string}`;generation:string;protectedReserveMicros:string;currentPolicyNonce:string;autonomousCoreLocked:boolean;startupHuman:`0x${string}`;autonomousDailyFloorMicros:string;state:'not-approved'|'expired'|'approved'|'locked'}>;
  approveAutomaticActivation(agentId:`0x${string}`,input:{intentHash:`0x${string}`;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string}):Promise<unknown>;
  cancelAutomaticActivation(agentId:`0x${string}`):Promise<unknown>;
  stewardship(binding:AutomaticActivationBinding):Promise<{steward:string;autonomous:boolean;blockNumber:string;blockHash:`0x${string}`;account:`0x${string}`;proposedHuman:`0x${string}`}>;
  offerStewardship(binding:AutomaticActivationBinding,next:`0x${string}`):Promise<unknown>;
  acceptStewardship(binding:AutomaticActivationBinding):Promise<unknown>;
  replaceAgentSteward(binding:AutomaticActivationBinding,next:`0x${string}`,input:{reasonHash:`0x${string}`}):Promise<unknown>;
  recoveryPolicy(agentId:`0x${string}`):Promise<{account:`0x${string}`;reserveMicros:string;maximumReimbursementMicros:string;bountyMicros:string;hostingReserveMicros:string}>;
  configureRecovery(agentId:`0x${string}`,input:{maximumReimbursement:string;bounty:string}):Promise<unknown>;
  fundRecovery(agentId:`0x${string}`,dollars:string):Promise<unknown>;
  constructor(options: { ethereum: { request(input: {method: string; params?: unknown[] | object}): Promise<unknown> }; pins: AgentChainPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'> });
  connect(): Promise<string>; check(): Promise<void>; reconcile(): Promise<string>;
  createAccount(input: {signer: `0x${string}`; metadataHash: `0x${string}`; buildHash: `0x${string}`; reserve?: string; daily?: string}): Promise<{agentId: `0x${string}`; human: `0x${string}`; account: `0x${string}`; token: `0x${string}`; metadataHash: `0x${string}`; transactionHash: `0x${string}`} >;
  creation(agentId: `0x${string}`): Promise<ChainCreation | null>;
  approveProvider(agentId: `0x${string}`,recipient: `0x${string}`): Promise<unknown>;
  configureSleepingAccount(agentId:`0x${string}`,input:{dailyLimitMicros:string;hostingReserveMicros:string;recipients:`0x${string}`[]}):Promise<{agentId:`0x${string}`;account:`0x${string}`;dailyLimitMicros:string;hostingReserveMicros:string;recipients:`0x${string}`[];receipts:unknown[]}>;
  launch(agentId: `0x${string}`,input: {name: string; symbol: string; seed: string}): Promise<unknown>;
  quoteSleeping(agentId:`0x${string}`,input:{name:string;symbol:string}):Promise<{agentId:`0x${string}`;name:string;symbol:string;initialValuation:string;initialFdvEth:'1';protectionBlocks:10;maxHoldingBps:200;token:`0x${string}`;sqrtPriceX96:bigint;lower:number;upper:number;quoteDeposit:'0';state:'sleeping'}>;
  launchSleeping(agentId:`0x${string}`,input:{name:string;symbol:string;sqrtPriceX96:bigint;lower:number;upper:number;acknowledgePermanentLiquidity:true}):Promise<{agentId:`0x${string}`;token:`0x${string}`;locker:`0x${string}`;backers:`0x${string}`;bridgeReserve:`0x${string}`;baseToken:`0x${string}`;receipt:unknown;transactionHash:`0x${string}`;state:'sleeping'}>;
  dispatchBrain(agentId:`0x${string}`):Promise<unknown>;syncAuthority(agentId:`0x${string}`):Promise<unknown>;
  quoteBudget(agentId:`0x${string}`,input:{dollars:string;slippageBps?:number}):Promise<{agentId:`0x${string}`;dollars:string;quotedEth:string;maximumEth:string;deadline:bigint;slippageBps:number;state:'quoted'}>;
  fundBudget(agentId:`0x${string}`,input:{dollars:string;maximumEth:string;deadline:bigint}):Promise<unknown>;
  handoverSleeping(agentId:`0x${string}`,input:{nextSigner:`0x${string}`;destination:`0x${string}`;acceptance:`0x${string}`;expectedGeneration:string|bigint;buildHash:`0x${string}`;signerGasWei?:bigint}):Promise<{agentId:`0x${string}`;account:`0x${string}`;signer:`0x${string}`;generation:'2';destination:`0x${string}`;buildHash:`0x${string}`;transactionHash:`0x${string}`;receipt:unknown;state:'activation-pending'}>;
  trade(agentId: `0x${string}`,input: {buy: boolean; input: string; minimumOutput: string}): Promise<unknown>;
  quote(agentId: `0x${string}`,input: {buy: boolean; input: string; slippageBps?: number}): Promise<{output: string; minimumOutput: string; slippageBps: number}>;
  feeConversionQuote(agentId: `0x${string}`,input: {input: string; slippageBps?: number}): Promise<{output: string; minimumOutput: string; slippageBps: number}>;
  convertFees(agentId: `0x${string}`,input: {input: string; minimumOutput: string}): Promise<unknown>;
  back(agentId: `0x${string}`,tokens: string,options: {acknowledgePermanentLock: true}): Promise<unknown>;
  backerStatus(agentId: `0x${string}`): Promise<{tokens: string; backedTokens: string; pendingRewards:string;rewardAsset:'USDC'|'NCC'|'nDIEM'; /** @deprecated Use pendingRewards. */ pendingCredits: string}>;
  collect(agentId: `0x${string}`): Promise<unknown>; claimRewards(agentId:`0x${string}`):Promise<unknown>; /** @deprecated Use claimRewards. */ claimCredits(agentId: `0x${string}`): Promise<unknown>;
  mintCredits(dollars: string): Promise<unknown>; activateCredits(agentId: `0x${string}`,dollars: string): Promise<unknown>;
}
export class NoerraDiemMarket extends NoerraAgentChain {
  constructor(options: {ethereum: {request(input: {method: string; params?: unknown[] | object}): Promise<unknown>}; pins: DiemMarketPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>});
  launch(agentId: `0x${string}`,input: {name: string; symbol: string; seed: string; acknowledgePermanentLiquidity: true}): Promise<unknown>;
  reconcileCompute(agentId: `0x${string}`): Promise<unknown>;
  finalizeBrain(agentId:`0x${string}`):Promise<unknown>;
  mintCredits(): Promise<never>; activateCredits(): Promise<never>;
}
export interface DualMarketPins extends DiemMarketPins { credits: AgentChainPin; dollar: AgentChainPin; cashDeployer: AgentChainPin; }
export interface NoerraDualMarket extends Omit<NoerraAgentChain,'launch'> {}
export class NoerraDualMarket {
  constructor(options: {ethereum: {request(input: {method: string; params?: unknown[] | object}): Promise<unknown>}; pins: DualMarketPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>});
  selectMarket(side: 'cash' | 'brain'): this;
  launch(agentId: `0x${string}`, input: {name: string; symbol: string; cashSeed: string; diemSeed: string; activation?: string; operatingCash: string; startupGas?: string; acknowledgePermanentLiquidity: true}): Promise<unknown>;
  reconcileCompute(agentId: `0x${string}`): Promise<unknown>;
}
