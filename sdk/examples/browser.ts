import { NoerraAgentsClient } from '@noerra/sdk';

// The wallet signs a short-lived owner session; no key leaves the wallet.
type Wallet = { request(options: { method: string; params: unknown[] }): Promise<string> };

export async function listMyAgents(wallet: Wallet, address: string) {
  const client = new NoerraAgentsClient({ origin: 'https://withnoerra.com' });
  await client.connect(wallet, address);
  const { agents } = await client.list();
  return { client, agents };
}

// Public profiles need no wallet.
export async function readProfile(agentId: string) {
  return new NoerraAgentsClient({ origin: 'https://withnoerra.com' }).publicProfile(agentId);
}
