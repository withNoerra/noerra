/** Single off-chain source of the canonical trading-fee policy.
 * TRADE_FEE_BPS must equal NOERRA_TRADE_FEE_BPS in src/agents/NoerraUsdcFeeHook.sol; changing the rate is
 * that constant plus this one (plus the reviewed NOERRA creation hashes in NoerraAtomicCodeHashes.sol).
 * Rows are basis points of each collected USDC fee. There are no backer or buyback rows.
 */
export const TRADE_FEE_BPS=200n;
/** Anti-snipe launch fee of every agent token: LAUNCH_FEE_START_BPS in the launch block, falling linearly (230 bps a
 * block) to TRADE_FEE_BPS at launch block + LAUNCH_FEE_DECAY_BLOCKS (~2 minutes), then TRADE_FEE_BPS forever. Equals
 * NOERRA_LAUNCH_FEE_START_BPS / AGENT_LAUNCH_FEE_DECAY_BLOCKS in NoerraUsdcFeeHook.sol. */
export const LAUNCH_FEE_START_BPS=2500n,LAUNCH_FEE_DECAY_BLOCKS=10n;
/** NOERRA's own market decays over 25 blocks (92 bps a block); equals NOERRA_LAUNCH_FEE_DECAY_BLOCKS. */
export const NOERRA_LAUNCH_FEE_DECAY_BLOCKS=25n;
/** The launch-block rate (the schedule's start); kept for existing callers. */
export const LAUNCH_FEE_BPS=LAUNCH_FEE_START_BPS;
const BPS=10000n;
/** Exact mirror of the on-chain noerraLaunchFeeBps(launchBlock, blockNumber, decayBlocks): the fee in force at
 * `blockNumber` for a market launched at `launchBlock` (0 or absent: not launched, standard fee). `decayBlocks`
 * defaults to the agent-token schedule (LAUNCH_FEE_DECAY_BLOCKS); pass NOERRA_LAUNCH_FEE_DECAY_BLOCKS for NOERRA. */
export function launchFeeBps(launchBlock,blockNumber,decayBlocks=LAUNCH_FEE_DECAY_BLOCKS){
 const launch=BigInt(launchBlock??0),block=BigInt(blockNumber),decay=BigInt(decayBlocks);
 if(decay<=0n)throw Error('Use a positive launch-fee decay.');
 if(launch===0n||block<launch)return TRADE_FEE_BPS;
 const elapsed=block-launch;
 return elapsed>=decay?TRADE_FEE_BPS:LAUNCH_FEE_START_BPS-(LAUNCH_FEE_START_BPS-TRADE_FEE_BPS)*elapsed/decay;
}
/** NoerraEthereumCreation rows. agent: cash to the agent account (plus rounding dust); brain: exactly to the
 * agent's brain escrow (to the account when none, disabled or full); creator: account.feeRecipient() at
 * distribution time (the account itself in AGENT mode); treasury: operations; burn: the deployment's NoerraBurner, which
 * buys NOERRA on its canonical market and burns it (accumulating until NOERRA is bound). */
export const CREATION_FEE_ROWS=Object.freeze({agent:4000n,brain:2000n,creator:2000n,treasury:1500n,burn:500n});
/** Dollar-pegged NOERRA burns paid by the creator: launchSleeping (token agent) and prepareAgent (tokenless agent). */
export const LAUNCH_BURN_TOKEN_MICROS=20_000000n,LAUNCH_BURN_TOKENLESS_MICROS=5_000000n;
/** The burner's permissionless burn() threshold. */
export const MINIMUM_BURN_MICROS=20_000000n;
/** NoerraEcosystemVault rows (NOERRA's own market only); the treasury receives the remainder, including rounding dust. */
export const ECOSYSTEM_FEE_ROWS=Object.freeze({agent:4000n,brain:2000n,treasury:BPS-4000n-2000n});

const percent=bps=>{const whole=bps/100n,fraction=bps%100n;return fraction?`${whole}.${String(fraction).padStart(2,'0').replace(/0$/,'')}%`:`${whole}%`;};
/** Display text such as "2%". */
export const TRADE_FEE_PERCENT=percent(TRADE_FEE_BPS);
export const LAUNCH_FEE_PERCENT=percent(LAUNCH_FEE_BPS);
const points=bps=>{const whole=bps/100n,fraction=bps%100n;return fraction?`${whole}.${String(fraction).padStart(2,'0').replace(/0$/,'')}`:`${whole}`;};
/** Public fee copy (agent tokens): "2% trade fee; a higher launch fee in the first ~2 minutes (25% falling to 2%) protects against snipers". */
export const TRADE_FEE_TEXT=`${percent(TRADE_FEE_BPS)} trade fee; a higher launch fee in the first ~2 minutes (${percent(LAUNCH_FEE_START_BPS)} falling to ${percent(TRADE_FEE_BPS)}) protects against snipers`;
/** Agent tokens: "25% in the launch block, falling 2.3 points a block to 2% at block 10 (about two minutes)" */
export const LAUNCH_FEE_SCHEDULE_TEXT=`${percent(LAUNCH_FEE_START_BPS)} in the launch block, falling ${points((LAUNCH_FEE_START_BPS-TRADE_FEE_BPS)/LAUNCH_FEE_DECAY_BLOCKS)} points a block to ${percent(TRADE_FEE_BPS)} at block ${LAUNCH_FEE_DECAY_BLOCKS} (about two minutes)`;
export const feePercent=percent;
/** "40% agent, 20% agent brain, 20% creator, 15% treasury, 5% NOERRA burn" */
export const CREATION_FEE_SPLIT_TEXT=`${percent(CREATION_FEE_ROWS.agent)} agent, ${percent(CREATION_FEE_ROWS.brain)} agent brain, ${percent(CREATION_FEE_ROWS.creator)} creator, ${percent(CREATION_FEE_ROWS.treasury)} treasury, ${percent(CREATION_FEE_ROWS.burn)} NOERRA burn`;
/** Agent cash row and brain row, e.g. "40%" and "20%". */
export const AGENT_FEE_PERCENT=percent(CREATION_FEE_ROWS.agent),BRAIN_FEE_PERCENT=percent(CREATION_FEE_ROWS.brain);
export const CREATOR_FEE_PERCENT=percent(CREATION_FEE_ROWS.creator),TREASURY_FEE_PERCENT=percent(CREATION_FEE_ROWS.treasury),BURN_FEE_PERCENT=percent(CREATION_FEE_ROWS.burn);
/** "40% NOERRA agent operating account · 20% NOERRA brain fund · 40% operations treasury" */
export const ECOSYSTEM_FEE_SPLIT_TEXT=`${percent(ECOSYSTEM_FEE_ROWS.agent)} NOERRA agent operating account · ${percent(ECOSYSTEM_FEE_ROWS.brain)} NOERRA brain fund · ${percent(ECOSYSTEM_FEE_ROWS.treasury)} operations treasury`;

/** Exact on-chain integer split of one creation fee collection (the agent row takes the dust). */
export function creationFeeSplit(dollars){
 const row=bps=>dollars*bps/BPS,brain=row(CREATION_FEE_ROWS.brain),creator=row(CREATION_FEE_ROWS.creator),treasury=row(CREATION_FEE_ROWS.treasury),burn=row(CREATION_FEE_ROWS.burn);
 return {agent:dollars-brain-creator-treasury-burn,brain,creator,treasury,burn};
}
/** Exact on-chain integer split of NOERRA market (vault) revenue (operations takes the dust). */
export function ecosystemFeeSplit(amount){
 const agent=amount*ECOSYSTEM_FEE_ROWS.agent/BPS,brain=amount*ECOSYSTEM_FEE_ROWS.brain/BPS;
 return {agent,brain,operations:amount-agent-brain};
}
