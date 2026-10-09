export interface DiemDeploymentPin {address: `0x${string}`; codeHash: `0x${string}`;}
export interface AgentDiemPins {chainId: 8453 | 31337; wrapper: DiemDeploymentPin; diem: DiemDeploymentPin; registry: DiemDeploymentPin; reader?: DiemDeploymentPin;}
export class NoerraAgentDiem {
  constructor(options: {ethereum: {request(input: {method: string; params?: unknown[] | object}): Promise<unknown>}; pins: AgentDiemPins; storage?: Pick<Storage,'getItem'|'setItem'|'removeItem'>});
  connect(): Promise<string>; check(): Promise<void>; reconcile(): Promise<string>;
  status(agentId: `0x${string}`): Promise<{vault: string; locked: string; wrapped: string; diem: string; staked: string; cooldown: string; cooldownEndsAt: bigint}>;
  poolBackingPage(start?: bigint,maximum?: number): Promise<{subtotal: string; next: bigint}>;
  wrap(diem: string): Promise<unknown>;
  lockFor(agentId: `0x${string}`,diem: string,options: {acknowledgePermanentLock: true}): Promise<unknown>;
  reconcileAgent(agentId: `0x${string}`): Promise<unknown>;
  redeem(diem: string): Promise<unknown>; claim(): Promise<unknown>;
}
