import { NoerraAgentsClient } from '@noerra/sdk/agents';

// Node reads the public directory without a wallet session.
// Owner actions need a wallet adapter supplied by your application.
export async function publicDirectory(origin = 'https://withnoerra.com') {
  const client = new NoerraAgentsClient({ origin });
  const { agents } = await client.directory();
  return agents.map(agent => ({ id: agent.id, name: agent.name }));
}
