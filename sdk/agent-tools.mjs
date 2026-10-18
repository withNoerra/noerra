const identity = (value, label = 'agent') => {
  if (!/^[a-f0-9]{32}$/.test(value || '')) throw Error(`Use a stable 32-character ${label} identity.`);
  return value;
};
const micros = value => {
  if (!Number.isSafeInteger(value) || value < 1 || value > 1e12) throw Error('Use a positive finite integer amount in USD micro-units.');
  return value;
};
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

export class NoerraToolError extends Error {
  constructor(message, { status, requestId, uncertain = false } = {}) {
    super(message); this.name = 'NoerraToolError'; this.status = status;
    this.requestId = requestId; this.uncertain = uncertain;
  }
}

/** Direct provider gateway client. A mutation is sent once; unknown outcomes need reconciliation. */
export class NoerraAgentToolsClient {
  constructor({ baseUrl, origin, fetchImpl, fetcher, session = null, headers = {}, timeoutMs = 30000 } = {}) {
    const url = new URL(baseUrl || origin);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1')) throw Error('Use HTTPS or loopback.');
    if (url.username || url.password || url.search || url.hash || !['/', '/api/agents', '/api/agents/'].includes(url.pathname)) throw Error('Use an agent service origin or its /api/agents base URL.');
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 180000) throw Error('Use a timeout between 1 and 180000 milliseconds.');
    this.baseUrl = url.origin + '/api/agents'; this.origin = url.origin;
    this.fetchImpl = (fetchImpl || fetcher || globalThis.fetch).bind(globalThis);
    this.session = session; this.headers = new Headers(headers); this.timeoutMs = timeoutMs;
  }
  async request(path, input, { requestId, mutation = input !== undefined } = {}) {
    const headers = new Headers(this.headers);
    const token = typeof this.session === 'string' ? this.session : this.session?.token;
    if (token) headers.set('authorization', 'Bearer ' + token);
    if (input !== undefined) {
      headers.set('content-type', 'application/json');
      if (typeof window === 'undefined') headers.set('origin', this.origin);
    }
    // Serialize before dispatch: a local encoding error is not an unknown provider outcome.
    const body = input === undefined ? undefined : JSON.stringify(input);
    let response;
    try {
      response = await this.fetchImpl(this.baseUrl + path, {
        method: input === undefined ? 'GET' : 'POST', headers, redirect: 'error', credentials: 'omit',
        signal: AbortSignal.timeout(this.timeoutMs), ...(input === undefined ? {} : { body })
      });
    } catch {
      throw new NoerraToolError(mutation ? 'Tool request outcome is unknown. Keep its request ID and reconcile before another execution.' : 'Tool service could not be reached.', { requestId, uncertain: mutation });
    }
    let value;
    try { value = await response.json(); } catch {
      throw new NoerraToolError('Tool service returned an unreadable response.', { status: response.status, requestId, uncertain: mutation });
    }
    if (!object(value)) throw new NoerraToolError('Tool service returned an invalid response.', { status: response.status, requestId, uncertain: mutation });
    if (!response.ok) throw new NoerraToolError(typeof value.error === 'string' ? value.error : 'Tool service rejected the request.', { status: response.status, requestId, uncertain: mutation && response.status >= 500 });
    return value;
  }
  path(agentId) { return '/' + identity(agentId) + '/tools'; }
  catalog(agentId) { return this.request(this.path(agentId)); }
  configure(agentId, policy) {
    if (!object(policy) || typeof policy.enabled !== 'boolean' || !Array.isArray(policy.permissions) || policy.permissions.some(value => typeof value !== 'string') || typeof policy.allowPublicRead !== 'boolean') throw Error('Use an explicit tool policy and permissions.');
    const allowed = new Set(['enabled', 'permissions', 'dailyMicros', 'requestMicros', 'maximumResources', 'allowPublicRead', 'allowedRecipients', 'allowedDomains']);
    if (Object.keys(policy).some(key => !allowed.has(key))) throw Error('Tool policy must not contain provider credentials or unknown fields.');
    micros(policy.dailyMicros); micros(policy.requestMicros);
    if (!Number.isSafeInteger(policy.maximumResources) || policy.maximumResources < 1 || policy.maximumResources > 64) throw Error('Use a resource limit between 1 and 64.');
    if (policy.requestMicros > policy.dailyMicros) throw Error('Keep the per-call limit within the daily budget.');
    for (const key of ['allowedRecipients', 'allowedDomains']) if (policy[key] !== undefined && (!Array.isArray(policy[key]) || policy[key].some(value => typeof value !== 'string'))) throw Error('Use string lists for recipients and domains.');
    return this.request(this.path(agentId) + '/configure', policy);
  }
  quote(agentId, input) {
    if (!object(input) || !/^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9_-]*)+$/.test(input.tool || '') || !object(input.input)) throw Error('Choose a tool and JSON input.');
    identity(input.requestId, 'request'); micros(input.maxCostMicros);
    if (input.visibility !== undefined && !['private', 'public'].includes(input.visibility)) throw Error('Choose private or public visibility.');
    const allowed = new Set(['tool', 'input', 'maxCostMicros', 'visibility', 'requestId']);
    if (Object.keys(input).some(key => !allowed.has(key))) throw Error('Use only the declared tool quote fields.');
    return this.request(this.path(agentId) + '/quote', input, { requestId: input.requestId });
  }
  execute(agentId, { requestId, quoteId } = {}) {
    identity(requestId, 'request');
    if (typeof quoteId !== 'string' || !quoteId.length || quoteId.length > 256) throw Error('Use the original tool quote identity.');
    return this.request(this.path(agentId) + '/execute', { requestId, quoteId }, { requestId });
  }
  operation(agentId, requestId) { return this.request(this.path(agentId) + '/operations/' + identity(requestId, 'request')); }
  resources(agentId) { return this.request(this.path(agentId) + '/resources'); }
  expiryStatus(agentId) { return this.request(this.path(agentId) + '/expiry'); }
  configureExpiry(agentId, policy) {
    if(!object(policy)||Object.keys(policy).some(key=>!['enabled','consent','resourceKinds'].includes(key))||typeof policy.enabled!=='boolean'||policy.consent!=='delete-funded-resources-at-expiry'||!Array.isArray(policy.resourceKinds)||policy.resourceKinds.length>20||new Set(policy.resourceKinds).size!==policy.resourceKinds.length||policy.resourceKinds.some(key=>!['e2b:sandbox','fly:machine','fly:volume','fly:app','vercel:deployment','vercel:project','supabase:database','supabase:bucket','agentmail:inbox'].includes(key)))throw Error('Explicitly consent to deleting selected funded resources at expiry.');
    return this.request(this.path(agentId) + '/expiry-configure',policy);
  }
  reconcileExpiry(agentId,{resourceId}={}) {
    identity(resourceId,'resource');return this.request(this.path(agentId) + '/expiry-reconcile',{resourceId});
  }
  reconcile(agentId, { requestId } = {}) {
    identity(requestId, 'request');
    return this.request(this.path(agentId) + '/reconcile', { requestId }, { requestId });
  }
  mcp(agentId, message) {
    if (!object(message) || message.jsonrpc !== '2.0' || !['initialize', 'ping', 'tools/list', 'tools/call'].includes(message.method) || !['string', 'number'].includes(typeof message.id)) throw Error('Use an identified MCP request.');
    const mutation = message.method === 'tools/call';
    const requestId = mutation ? identity(message.params?.arguments?.requestId, 'request') : undefined;
    return this.request(this.path(agentId) + '/mcp', message, { requestId, mutation });
  }
}
