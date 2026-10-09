import type { OwnedAgent, AgentRun } from './agents.js';
export interface AgentMemoryBackup { format: 'noerra-agent-memory'; version: 1; iterations: 310000; salt: string; iv: string; ciphertext: string; }
export function exportAgentMemory(agent: OwnedAgent, passphrase: string): Promise<AgentMemoryBackup>;
export function importAgentMemory(record: AgentMemoryBackup, passphrase: string): Promise<unknown>;
export interface AgentWorkExport { format: 'noerra-agent-work'; version: 1; iterations: 310000; salt: string; iv: string; ciphertext: string; }
export function exportAgentWork(agent: OwnedAgent, passphrase: string): Promise<AgentWorkExport>;
export function importAgentWork(record: AgentWorkExport, passphrase: string): Promise<{ version: 1; owner: string; agentId: string; name: string; runs: AgentRun[]; at: number }>;
