/** Canonical trading-fee policy (equals NOERRA_TRADE_FEE_BPS in src/agents/NoerraUsdcFeeHook.sol): 2% of the USDC side of every buy and sell. */
export const TRADE_FEE_BPS: 200n;
/** Anti-snipe launch fee of every agent token: 25% in the launch block, falling linearly to TRADE_FEE_BPS over 10 blocks. */
export const LAUNCH_FEE_START_BPS: 2500n;
export const LAUNCH_FEE_DECAY_BLOCKS: 10n;
/** NOERRA's own market decays over 25 blocks. */
export const NOERRA_LAUNCH_FEE_DECAY_BLOCKS: 25n;
/** The launch-block rate (equals LAUNCH_FEE_START_BPS). */
export const LAUNCH_FEE_BPS: 2500n;
/** The fee in force at `blockNumber` for a market launched at `launchBlock` (mirrors noerraLaunchFeeBps on chain).
 * `decayBlocks` defaults to LAUNCH_FEE_DECAY_BLOCKS (agent tokens); NOERRA uses NOERRA_LAUNCH_FEE_DECAY_BLOCKS. */
export function launchFeeBps(launchBlock: bigint | number | string | null | undefined, blockNumber: bigint | number | string, decayBlocks?: bigint | number | string): bigint;
/** Agent token pools, in basis points of each collected USDC fee. There are no backer or buyback rows. */
export const CREATION_FEE_ROWS: Readonly<{agent: 4000n; brain: 2000n; creator: 2000n; treasury: 1500n; burn: 500n}>;
/** USDC the creator pays at creation, used to buy and burn NOERRA: $20 with a token, $5 tokenless. */
export const LAUNCH_BURN_TOKEN_MICROS: 20000000n;
export const LAUNCH_BURN_TOKENLESS_MICROS: 5000000n;
/** The burner's permissionless burn() threshold. */
export const MINIMUM_BURN_MICROS: 20000000n;
/** NOERRA's own market: 40% NOERRA agent, 20% NOERRA brain fund, the rest (40%) operations treasury. No automatic burn. */
export const ECOSYSTEM_FEE_ROWS: Readonly<{agent: 4000n; brain: 2000n; treasury: 4000n}>;
export const TRADE_FEE_PERCENT: string;
export const LAUNCH_FEE_PERCENT: string;
/** "2% trade fee; a higher launch fee in the first ~2 minutes (25% falling to 2%) protects against snipers" */
export const TRADE_FEE_TEXT: string;
export const LAUNCH_FEE_SCHEDULE_TEXT: string;
export function feePercent(bps: bigint): string;
export const CREATION_FEE_SPLIT_TEXT: string;
export const AGENT_FEE_PERCENT: string;
export const BRAIN_FEE_PERCENT: string;
export const CREATOR_FEE_PERCENT: string;
export const TREASURY_FEE_PERCENT: string;
export const BURN_FEE_PERCENT: string;
export const ECOSYSTEM_FEE_SPLIT_TEXT: string;
/** Exact on-chain integer split of one collection (the agent row takes the rounding dust). */
export function creationFeeSplit(amount: bigint): {agent: bigint; brain: bigint; creator: bigint; treasury: bigint; burn: bigint};
/** Exact on-chain integer split of NOERRA market revenue (operations takes the rounding dust). */
export function ecosystemFeeSplit(amount: bigint): {agent: bigint; brain: bigint; operations: bigint};
