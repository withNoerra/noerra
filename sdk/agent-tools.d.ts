export type ToolVisibility = 'private' | 'public';
export type ToolOperationStatus = 'quoted' | 'reserved' | 'authorizing' | 'dispatched' | 'uncertain' | 'awaiting-receipt' | 'succeeded' | 'failed' | 'settled' | 'cancelled';
export type ToolInput = Record<string, unknown>;
/** USD micro-units (1 USD = 1,000,000), represented as positive safe integers up to 1e12. */
export interface AgentToolPolicy {
  enabled: boolean; permissions: string[]; dailyMicros: number; requestMicros: number;
  maximumResources: number; allowPublicRead: boolean; allowedRecipients?: string[]; allowedDomains?: string[];
}
export interface ToolQuoteInput {
  tool: string; input: ToolInput; maxCostMicros: number; visibility?: ToolVisibility; requestId: string;
}
export interface ResourceExpiryPolicy {
  enabled: boolean; consent: 'delete-funded-resources-at-expiry'; resourceKinds: string[];
}
export interface ToolQuote {
  requestId: string; quoteId: string; maximumMicros: number; expiresAt: number;
  tool: string; inputHash: string; policyHash: string; status: ToolOperationStatus;
  [key: string]: unknown;
}
export interface ToolOperation {
  requestId: string; status: ToolOperationStatus; providerOperationId?: string;
  result?: unknown; [key: string]: unknown;
}
export interface McpRequest {
  jsonrpc: '2.0'; id: string | number; method: 'initialize' | 'ping' | 'tools/list' | 'tools/call';
  params?: Record<string, unknown> & { arguments?: Record<string, unknown> & { requestId?: string } };
}
export class NoerraToolError extends Error {
  status?: number; requestId?: string; uncertain: boolean;
  constructor(message: string, details?: { status?: number; requestId?: string; uncertain?: boolean });
}
export class NoerraAgentToolsClient {
  constructor(options: {
    baseUrl?: string; origin?: string; fetchImpl?: typeof fetch; fetcher?: typeof fetch;
    session?: string | { token?: string | null } | null; headers?: HeadersInit; timeoutMs?: number;
  });
  catalog(agentId: string): Promise<Record<string, unknown>>;
  configure(agentId: string, policy: AgentToolPolicy): Promise<Record<string, unknown>>;
  quote(agentId: string, input: ToolQuoteInput): Promise<ToolQuote>;
  execute(agentId: string, input: { requestId: string; quoteId: string }): Promise<ToolOperation>;
  operation(agentId: string, requestId: string): Promise<ToolOperation>;
  resources(agentId: string): Promise<Record<string, unknown>>;
  expiryStatus(agentId: string): Promise<Record<string, unknown>>;
  configureExpiry(agentId: string, policy: ResourceExpiryPolicy): Promise<Record<string, unknown>>;
  reconcileExpiry(agentId: string, input: { resourceId: string }): Promise<Record<string, unknown>>;
  reconcile(agentId: string, input: { requestId: string }): Promise<ToolOperation>;
  mcp(agentId: string, message: McpRequest): Promise<Record<string, unknown>>;
}
