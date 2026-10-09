const bytes = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
const base64 = value => btoa(Array.from(value, c => String.fromCharCode(c)).join(''));
const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const aad = encoder.encode('noerra-agent-memory-v1');
async function key(passphrase, salt) {
  if (typeof passphrase !== 'string' || passphrase.length < 12 || passphrase.length > 256) throw Error('Use a backup passphrase with 12–256 characters.');
  const material = await crypto.subtle.importKey('raw', encoder.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations: 310000, hash: 'SHA-256' }, material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
export async function exportAgentMemory(agent, passphrase) {
  const snapshot = { version: 1, owner: agent.owner, config: agent.config, memory: agent.memory, journal: [...agent.journal, ...agent.drafts], at: Date.now() };
  const plaintext = encoder.encode(JSON.stringify(snapshot)); if (plaintext.length > 200000) throw Error('Agent memory exceeds the backup limit.');
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  try {
    const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad }, await key(passphrase, salt), plaintext);
    return { format: 'noerra-agent-memory', version: 1, iterations: 310000, salt: base64(salt), iv: base64(iv), ciphertext: base64(new Uint8Array(ciphertext)) };
  } finally { plaintext.fill(0); }
}
export async function importAgentMemory(record, passphrase) {
  try {
    if (record?.format !== 'noerra-agent-memory' || record.version !== 1 || record.iterations !== 310000 || typeof record.ciphertext !== 'string' || record.ciphertext.length > 280000) throw Error();
    const salt = bytes(record.salt), iv = bytes(record.iv); if (salt.length !== 16 || iv.length !== 12) throw Error();
    const plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad }, await key(passphrase, salt), bytes(record.ciphertext)));
    try { return JSON.parse(decoder.decode(plaintext)); } finally { plaintext.fill(0); }
  } catch { throw Error('The backup or passphrase could not be verified.'); }
}
export async function exportAgentWork(agent, passphrase) {
  const plaintext = encoder.encode(JSON.stringify({ version: 1, owner: agent.owner, agentId: agent.id, name: agent.name, runs: agent.runs.filter(row => ['completed', 'invalid-output', 'cancelled'].includes(row.status)), at: Date.now() }));
  if (plaintext.length > 2_000_000) throw Error('Export work in smaller batches. No operations were archived.');
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  try { const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: encoder.encode('noerra-agent-work-v1') }, await key(passphrase, salt), plaintext);
    return { format: 'noerra-agent-work', version: 1, iterations: 310000, salt: base64(salt), iv: base64(iv), ciphertext: base64(new Uint8Array(ciphertext)) };
  } finally { plaintext.fill(0); }
}
export async function importAgentWork(record, passphrase) {
  try { if (record?.format !== 'noerra-agent-work' || record.version !== 1 || record.iterations !== 310000 || typeof record.ciphertext !== 'string' || record.ciphertext.length > 2_700_000) throw Error('Invalid work export.');
    const salt = bytes(record.salt), iv = bytes(record.iv); if (salt.length !== 16 || iv.length !== 12) throw Error('Invalid work export.');
    const plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: encoder.encode('noerra-agent-work-v1') }, await key(passphrase, salt), bytes(record.ciphertext)));
    try { return JSON.parse(decoder.decode(plaintext)); } finally { plaintext.fill(0); }
  } catch { throw Error('The work export or passphrase could not be verified.'); }
}
