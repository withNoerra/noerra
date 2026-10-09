import type { Address, Hex, TransactionReceipt, Abi } from 'viem';
export interface EthereumProvider { request(args: { method: string; params?: unknown[] | object }): Promise<unknown>; }
export interface JournalStorage { getItem(key: string): string | null | undefined; setItem(key: string, value: string): void; removeItem(key: string): void; }
export interface MarketConfig { enabled: true; address: Address; codeHash: Hex; chainId: 1 | 31337; epoch: string; minimumComputeMicros?: string; }
export interface AccessChallenge { chainId: number; market: Address; address: Address; origin: string; nonce: Hex; order: string; epoch: string; expires: number; }
export interface PoolState { retailPrice: bigint; computePrice: bigint; listed: bigint; sold: bigint; [field: string]: unknown; }
export interface MarketStatus { epoch: bigint; pool: PoolState; stake: bigint; exit: bigint; lock: bigint; position: readonly unknown[]; recurring: readonly [bigint, bigint, bigint, Hex]; earnings: bigint; balance: bigint; coin: Address; payment: Address; feeBps: bigint; decimals: number; symbol: string; allowance: bigint; }
export class AccessMarket {
  constructor(options: { ethereum: EthereumProvider; config: MarketConfig; storage?: JournalStorage; origin?: string });
  config: MarketConfig; origin?: string; market: Address; owner?: Address;
  connect(): Promise<Address>; check(): Promise<void>; status(epoch?: string): Promise<MarketStatus>;
  buy(dollars: string): Promise<{ id: bigint; units: bigint; cost: bigint; hash: Hex }>;
  stake(tokens: string): Promise<TransactionReceipt>;
  register(kept: string, listed: string, epoch?: string): Promise<TransactionReceipt>;
  claim(epoch?: string): Promise<TransactionReceipt>;
  claimDays(epochs: (string | bigint)[]): Promise<TransactionReceipt>;
  configureRecurring(kept: string, listed: string, days?: number): Promise<TransactionReceipt>;
  cancelRecurring(): Promise<TransactionReceipt>;
  requestExit(): Promise<TransactionReceipt>; withdraw(): Promise<TransactionReceipt>; refund(order: string): Promise<TransactionReceipt>;
  order(id: string): Promise<readonly unknown[]>; reconcile(): Promise<string>;
  signAccess(challenge: AccessChallenge, expectedOrder?: string): Promise<Hex>;
}
export const accessMarketAbi: Abi;
export function displayUsd(micros: bigint): string;
