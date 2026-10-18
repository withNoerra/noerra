export interface AgentChainPin { address: `0x${string}`; codeHash: `0x${string}`; }
export interface AgentChainPins {providerMode?:'cash-only'|'legacy-diem';cashDeployer?:AgentChainPin;launchProtectionHook?:AgentChainPin;escrowDeployer?:AgentChainPin;/** @deprecated Creation markets no longer pay an ecosystem vault; ignored. */ecosystemVault?:AgentChainPin;legacyQuoter?:AgentChainPin;baseBridge?:`0x${string}`;baseLaunchpad?:`0x${string}`;compatibilityTargets?:{deployed:false;launchpad:`0x${string}`;standardBridge:`0x${string}`};}
export {NoerraEarnedDiem} from './earned-diem.js';
export {NoerraAgentDiem} from './agent-diem.js';
export {NoerraComputePool} from './agent-compute.js';
export {NoerraEcosystem,NoerraFlagshipMarket} from './agent-ecosystem.js';
export type {EcosystemPins,EcosystemStatus,NoerraLaunch,FlagshipDescriptor,FlagshipPolicy} from './agent-ecosystem.js';
export interface AgentChainPins { chainId: 1 | 31337; registry: AgentChainPin; credits: AgentChainPin; launchpad: AgentChainPin; dollar: AgentChainPin; manager: AgentChainPin; quoter?: AgentChainPin; launchMode?: 'sleeping';ethUsdFeed?:AgentChainPin;oracleMaximumAge?:number;buildHash?:`0x${string}`;operationsTreasury?:`0x${string}`; checkout?:AgentChainPin;fundingRouter?:AgentChainPin;fundingQuoter?:AgentChainPin;weth?:AgentChainPin;authorityMessenger?:AgentChainPin; }
/** Canonical Ethereum cash launches have no backers: `brainEscrow` is the agent's auto-bound brain fund (absent on legacy markets). */
export interface ChainCreation { agentId: `0x${string}`; locker: `0x${string}`; token: `0x${string}`; brainEscrow?: `0x${string}` | null; account: `0x${string}`; liquidity: bigint; feeTokens: bigint; }
/** Creator-share fee dial: follow-human (default, the current steward), explicit (a fixed address) or agent (the account itself). */
export type FeeRecipientMode = 'follow-human' | 'explicit' | 'agent';
/** Effective USDC trade fee at `quotedBlock`: the anti-snipe launch fee (25% in the launch block, minus 92 bps a block) in a market's first 25 blocks, then the standard 2%. */
export interface CurrentTradeFee { feeBps: number; feePercent: string; standardFeeBps: 200; launchFeeActive: boolean; launchBlock: string | null; launchFeeEndBlock: string | null; quotedBlock: string; }
export interface SpendingEnvelope { account: `0x${string}`; dailyFloorMicros: string; scaledLimitMicros: string; /** max(floor, spendable / 30). */ dailyLimitMicros: string; spentTodayMicros: string; remainingTodayMicros: string; /** max(3 x floor, scaledLimit / 10) for the agent's own or unverified wallets; a locked account uses its fixed autonomousDailyFloor. */ ownWalletCapMicros: string; ownWalletSpentTodayMicros: string; /** fuelLimits(latest basefee): max(0.005 ETH, 5M gas x base fee) per UTC day. */ fuelCapWei: string; /** Fuel's dollar survival allowance at the fresh ETH/USD price (0 when the feed is stale). */ fuelAllowanceMicros: string; fuelUsedTodayWei: string; /** Hosting plus recovery reserve; never spendable. */ protectedMicros: string; snapshotted: boolean; }
export interface HibernationStatus { account: `0x${string}`; hibernating: boolean; /** Recovery reserve + 14 x the daily floor (snapshotted at hibernate). */ wakeThresholdMicros: string; spendableMicros: string; recoverable: boolean; missingMicros: string; }
export interface OwnerWithdrawalStatus { account: `0x${string}`; /** True only for tokenless agents without a platform steward replacement. */ allowed: boolean; principalMicros: string; delaySeconds: number; pending: null | {amountMicros: string; readyAt: number}; }
export interface FreezeStatus { account: `0x${string}`; frozen: boolean; /** Platform report of the current signer: during the freeze and its lapse, until a rotation or the platform unfreeze(). */ reported: boolean; recoveryOpen: boolean; recoveryPaid: boolean; frozenGeneration: string; frozenAt: number; /** frozenAt + 72 h (extended while a recovery start claim is current). */ expiresAt: number; generation: string; signer: `0x${string}`; human: `0x${string}`; deploymentAuthority: `0x${string}`; nextOwnerFreezeAt: number; nextPaidFreezeRecoveryAt: number; }
export interface BrainFundStatus { escrow: `0x${string}`; available: string; earned: string; deposited: string; bridged: string; full: boolean; enabled: boolean; }
export interface DiemMarketPins { chainId: 8453 | 31337; sourceChainId?:1; registry: AgentChainPin; wrapper: AgentChainPin; diem: AgentChainPin; reader: AgentChainPin; launchpad: AgentChainPin; manager: AgentChainPin; deployer: AgentChainPin; quoter?: AgentChainPin; }
export function agentMetadataHash(id: string): `0x${string}`;
export interface AutomaticActivationBinding {chainId:1;owner:`0x${string}`;signer:`0x${string}`;account:`0x${string}`;agentId:`0x${string}`;buildHash:`0x${string}`;generation:string;}
export interface AutomaticActivationApproval {intentHash:`0x${string}`;policyNonce:string;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string;}
export interface AutomaticActivationIntent {version:1;chainId:1;owner:string;account:string;localId:string;agentId:`0x${string}`;buildHash:`0x${string}`;config:unknown;configHash:`0x${string}`;templateHash:`0x${string}`;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string;intentHash:`0x${string}`;approval?:AutomaticActivationApproval;}
export function canonicalActivationJson(value:unknown):string;
export function automaticActivationTemplateHash(value:unknown):`0x${string}`;
export function automaticActivationIntent(input:{binding:AutomaticActivationBinding;localId:string;config:unknown;template:unknown;minimumBalanceMicros:string;expiresAt:number;maximumStartupGasWei:string}):AutomaticActivationIntent;
/** birthCheckpoint (birthCheckpointHash of the sealed birth archive) becomes the account's first checkpointHash. */
export function automaticActivationCommitment(input:{binding:AutomaticActivationBinding;approval:AutomaticActivationApproval;nextSigner:`0x${string}`;destination:`0x${string}`;birthCheckpoint:`0x${string}`}):`0x${string}`;
export function birthCheckpointHash(input:{binding:{chainId:1;account:`0x${string}`;agentId:`0x${string}`};archive:Record<string,unknown>}):`0x${string}`;
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
  constructor(options: { ethereum: { request(input: {method: string; params?: unknown[] | object}): Promise<unknown> }; pins: AgentChainPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>; /** Admit chain 31337 (local anvil) for tests only. */ localDevnet?: boolean });
  connect(): Promise<string>; check(): Promise<void>; reconcile(): Promise<string>;
  /** reserve: protected hosting reserve in USDC (default '20', also the recovery-reserve cap); daily: daily spending floor in USDC (default '20', minimum '5'). */
  createAccount(input: {signer: `0x${string}`; metadataHash: `0x${string}`; buildHash: `0x${string}`; reserve?: string; daily?: string}): Promise<{agentId: `0x${string}`; human: `0x${string}`; account: `0x${string}`; token: `0x${string}`; metadataHash: `0x${string}`; transactionHash: `0x${string}`} >;
  creation(agentId: `0x${string}`): Promise<ChainCreation | null>;
  approveProvider(agentId: `0x${string}`,recipient: `0x${string}`): Promise<unknown>;
  configureSleepingAccount(agentId:`0x${string}`,input:{dailyLimitMicros:string;hostingReserveMicros:string;recipients:`0x${string}`[]}):Promise<{agentId:`0x${string}`;account:`0x${string}`;dailyLimitMicros:string;hostingReserveMicros:string;recipients:`0x${string}`[];receipts:unknown[]}>;
  launch(agentId: `0x${string}`,input: {name: string; symbol: string; seed: string}): Promise<unknown>;
  quoteSleeping(agentId:`0x${string}`,input:{name:string;symbol:string}):Promise<{agentId:`0x${string}`;name:string;symbol:string;initialValuation:string;initialFdvEth:'1';protectionBlocks:10;maxHoldingBps:200;/** 2% after the launch window. */tradeFeeBps:200;/** Anti-snipe launch fee: 25% in the launch block, falling linearly to 2% over 10 blocks (~2 minutes). */launchFeeStartBps:2500;launchFeeDecayBlocks:10;token:`0x${string}`;sqrtPriceX96:bigint;lower:number;upper:number;quoteDeposit:'0';/** USDC the launch pulls for its NOERRA burn ($20). */launchBurnMicros:'20000000';state:'sleeping'}>;
  /** Approves exactly the $5 NOERRA launch burn (5 USDC) to the launchpad, then prepares the tokenless agent. */
  prepareAgent(agentId:`0x${string}`):Promise<unknown>;
  /** Emergency freeze: status, the human (once per 30 days) or platform freeze (any time, then 7 days after its last one ended), and the
   * mistake-only unfreeze by whoever set it. A freeze lapses 72 h after it was set unless a recovery started; it moves no funds. */
  freezeStatus(agentId:`0x${string}`):Promise<FreezeStatus>;
  frozen(agentId:`0x${string}`):Promise<boolean>;
  freezeCompromised(agentId:`0x${string}`):Promise<unknown>;
  freezeCompromisedAndSync(agentId:`0x${string}`):Promise<{freeze:unknown;sync:{synced:true;receipt:unknown}|{synced:false;reason:string}}>;
  unfreeze(agentId:`0x${string}`):Promise<unknown>;
  /** Owner-admitted image upgrade (human only, moves no funds): send before the upgrade starter is granted so its paid recovery skips the 6 h paid-recovery cooldown. */
  admitUpgrade(agentId:`0x${string}`):Promise<unknown>;
  fundAccount(agentId:`0x${string}`,dollars:string):Promise<unknown>;
  /** Creator-share fee dial (20% row). */
  feeRecipient(agentId:`0x${string}`):Promise<{account:`0x${string}`;mode:FeeRecipientMode|'unknown';recipient:`0x${string}`}>;
  /** Current human only, also after launch. After a platform steward replacement only 'agent' is accepted onchain. */
  setFeeRecipient(agentId:`0x${string}`,input:{mode:'explicit';recipient:`0x${string}`}|{mode:'follow-human'|'agent';recipient?:undefined}):Promise<unknown>;
  hibernation(agentId:`0x${string}`):Promise<HibernationStatus>;
  spending(agentId:`0x${string}`):Promise<SpendingEnvelope>;
  /** Registry-approved payment service: effective 7 days after the platform proposes it, removable at once. */
  serviceStatus(service:`0x${string}`):Promise<{service:`0x${string}`;proposed:boolean;approved:boolean;effectiveAt:number;delaySeconds:number}>;
  /** Tokenless agents only: the owner's own deposits, withdrawable 7 days after a request (above both reserves). */
  ownerWithdrawal(agentId:`0x${string}`):Promise<OwnerWithdrawalStatus>;
  ownerDeposit(agentId:`0x${string}`,dollars:string):Promise<unknown>;
  requestOwnerWithdrawal(agentId:`0x${string}`,dollars:string):Promise<unknown>;
  cancelOwnerWithdrawal(agentId:`0x${string}`):Promise<unknown>;
  executeOwnerWithdrawal(agentId:`0x${string}`):Promise<unknown>;
  /** Approves exactly the $20 NOERRA launch burn (20 USDC) to the launchpad, then launches. */
  launchSleeping(agentId:`0x${string}`,input:{name:string;symbol:string;sqrtPriceX96:bigint;lower:number;upper:number;acknowledgePermanentLiquidity:true}):Promise<{agentId:`0x${string}`;token:`0x${string}`;locker:`0x${string}`;brainEscrow:`0x${string}`;bridgeReserve:`0x${string}`;baseToken:`0x${string}`;receipt:unknown;transactionHash:`0x${string}`;state:'sleeping'}>;
  dispatchBrain(agentId:`0x${string}`):Promise<unknown>;syncAuthority(agentId:`0x${string}`):Promise<unknown>;
  quoteBudget(agentId:`0x${string}`,input:{dollars:string;slippageBps?:number}):Promise<{agentId:`0x${string}`;dollars:string;quotedEth:string;maximumEth:string;deadline:bigint;slippageBps:number;state:'quoted'}>;
  fundBudget(agentId:`0x${string}`,input:{dollars:string;maximumEth:string;deadline:bigint}):Promise<unknown>;
  handoverSleeping(agentId:`0x${string}`,input:{nextSigner:`0x${string}`;destination:`0x${string}`;acceptance:`0x${string}`;expectedGeneration:string|bigint;buildHash:`0x${string}`;signerGasWei?:bigint}):Promise<{agentId:`0x${string}`;account:`0x${string}`;signer:`0x${string}`;generation:'2';destination:`0x${string}`;buildHash:`0x${string}`;transactionHash:`0x${string}`;receipt:unknown;state:'activation-pending'}>;
  trade(agentId: `0x${string}`,input: {buy: boolean; input: string; minimumOutput: string}): Promise<unknown>;
  /** The output already pays the fee in force at `quotedBlock` (the decaying launch fee in a market's first 25 blocks, then 2%). */
  quote(agentId: `0x${string}`,input: {buy: boolean; input: string; slippageBps?: number}): Promise<{output: string; minimumOutput: string; slippageBps: number}&CurrentTradeFee>;
  currentFee(poolKey:{currency0:`0x${string}`;currency1:`0x${string}`;fee:number;tickSpacing:number;hooks:`0x${string}`},blockNumber:bigint):Promise<CurrentTradeFee>;
  feeConversionQuote(agentId: `0x${string}`,input: {input: string; slippageBps?: number}): Promise<{output: string; minimumOutput: string; slippageBps: number}>;
  convertFees(agentId: `0x${string}`,input: {input: string; minimumOutput: string}): Promise<unknown>;
  brainEscrow(agentId:`0x${string}`):Promise<`0x${string}`|null>; brainStatus(agentId:`0x${string}`):Promise<BrainFundStatus|null>;
  /** Anyone may add USDC to an agent's brain fund (it can only bridge to the agent's Base reserve). */
  depositBrain(agentId:`0x${string}`,dollars:string):Promise<unknown>;
  /** Collects the pool's USDC fees and distributes them 40 agent / 20 brain / 20 creator / 15 treasury / 5 NOERRA burn. */
  collect(agentId: `0x${string}`): Promise<unknown>;
  mintCredits(dollars: string): Promise<unknown>; activateCredits(agentId: `0x${string}`,dollars: string): Promise<unknown>;
}
export class NoerraDiemMarket extends NoerraAgentChain {
  constructor(options: {ethereum: {request(input: {method: string; params?: unknown[] | object}): Promise<unknown>}; pins: DiemMarketPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>; localDevnet?: boolean});
  launch(agentId: `0x${string}`,input: {name: string; symbol: string; seed: string; acknowledgePermanentLiquidity: true}): Promise<unknown>;
  reconcileCompute(agentId: `0x${string}`): Promise<unknown>;
  finalizeBrain(agentId:`0x${string}`):Promise<unknown>;
  mintCredits(): Promise<never>; activateCredits(): Promise<never>;
}
export interface DualMarketPins extends DiemMarketPins { credits: AgentChainPin; dollar: AgentChainPin; cashDeployer: AgentChainPin; }
export interface NoerraDualMarket extends Omit<NoerraAgentChain,'launch'> {}
export class NoerraDualMarket {
  constructor(options: {ethereum: {request(input: {method: string; params?: unknown[] | object}): Promise<unknown>}; pins: DualMarketPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>; localDevnet?: boolean});
  selectMarket(side: 'cash' | 'brain'): this;
  launch(agentId: `0x${string}`, input: {name: string; symbol: string; cashSeed: string; diemSeed: string; activation?: string; operatingCash: string; startupGas?: string; acknowledgePermanentLiquidity: true}): Promise<unknown>;
  reconcileCompute(agentId: `0x${string}`): Promise<unknown>;
}
