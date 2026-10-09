import { createPublicClient, createWalletClient, custom, erc20Abi, getAddress, keccak256, encodeFunctionData, decodeEventLog, formatUnits, parseUnits } from 'viem';
import abi from './abi/NoerraAccessMarket.json' with { type: 'json' };
export { abi as accessMarketAbi };
const number = n => { if (typeof n !== 'string' || !/^[0-9]{1,30}$/.test(n)) throw Error('Enter a positive whole number.'); const value = BigInt(n); if (!value) throw Error('Enter a positive whole number.'); return value; };
export class AccessMarket {
  constructor({ ethereum, config, storage = globalThis.localStorage, origin = globalThis.location?.origin, supportedChainIds = [1, 31337] }) {
    if (!ethereum || !config?.enabled || !Number.isSafeInteger(config.chainId) || !supportedChainIds.includes(config.chainId) || !/^0x[0-9a-f]{64}$/i.test(config.codeHash)) throw Error('The access market is not configured.');
    this.config = config; this.market = getAddress(config.address); this.ethereum = ethereum; this.storage = storage; this.origin = origin;
    this.public = createPublicClient({ transport: custom(ethereum) }); this.wallet = createWalletClient({ transport: custom(ethereum) }); this.busy = false;
  }
  async connect() {
    const [owner] = await this.ethereum.request({ method: 'eth_requestAccounts' }); this.owner = getAddress(owner); await this.check(); return this.owner;
  }
  async check() {
    if (Number(await this.public.getChainId()) !== this.config.chainId) throw Error('Switch your wallet to the configured market network.');
    const [owner] = await this.ethereum.request({ method: 'eth_accounts' }); if (!owner || getAddress(owner) !== this.owner) throw Error('The connected wallet changed. Reconnect.');
    const code = await this.public.getBytecode({ address: this.market }); if (!code || keccak256(code) !== this.config.codeHash) throw Error('The market code does not match its pinned deployment.');
  }
  read(functionName, args = []) { return this.public.readContract({ address: this.market, abi, functionName, args }); }
  async status(epoch = this.config.epoch) {
    await this.check(); const e = BigInt(epoch);
    const [pool, stake, exit, lock, position, earnings, balance, coin, payment, feeBps, recurring] = await Promise.all([this.read('epochState', [e]), this.read('staked', [this.owner]), this.read('exitAt', [this.owner]), this.read('lockedUntil', [this.owner]), this.read('positions', [e, this.owner]), this.read('earned', [e, this.owner]), this.read('balances', [this.owner]), this.read('coin'), this.read('payment'), this.read('feeBps'), this.read('recurring', [this.owner])]);
    const [decimals, symbol, allowance] = await Promise.all([this.public.readContract({ address: payment, abi: erc20Abi, functionName: 'decimals' }), this.public.readContract({ address: payment, abi: erc20Abi, functionName: 'symbol' }), this.public.readContract({ address: payment, abi: erc20Abi, functionName: 'allowance', args: [this.owner, this.market] })]);
    if (decimals !== 6) throw Error('This market requires the configured six-decimal settlement asset.');
    return { epoch: e, pool, stake, exit, lock, position, earnings, balance, coin, payment, feeBps, decimals, symbol, allowance, recurring };
  }
  async transact(target, contractAbi, functionName, args, {value=0n}={}) {
    if(typeof value!=='bigint'||value<0n)throw Error('Use an explicit native transaction amount.');
    return this.walletLock(() => this.transactLocked(target, contractAbi, functionName, args,{value}));
  }
  walletLock(action) {
    const locks = globalThis.navigator?.locks;
    if (!locks) return action();
    return locks.request(`noerra-wallet:${this.config.chainId}:${this.market}:${this.owner}`, { ifAvailable: true }, lock => {
      if (!lock) throw Error('Another tab is handling this wallet. Wait for its transaction.');
      return action();
    });
  }
  async transactLocked(target, contractAbi, functionName, args,{value=0n}={}) {
    if (this.busy) throw Error('Wait for the pending transaction.');
    const journal = `noerra-market:${this.config.chainId}:${this.market}:${this.owner}`;
    if (this.storage?.getItem(journal)) throw Error('A wallet action has an unresolved outcome. Reconcile it before sending another.'); this.busy = true;
    this.pendingHash = undefined;
    try { await this.check(); const { request } = await this.public.simulateContract({ account: this.owner, address: target, abi: contractAbi, functionName, args,...(value?{value}:{}) });
      await this.check();
      if (this.storage?.getItem(journal)) throw Error('A wallet action has an unresolved outcome. Reconcile it before sending another.');
      if (!this.storage) throw Error('Browser transaction storage is unavailable.');
      this.pendingHash = undefined;
      this.storage.setItem(journal, JSON.stringify({ phase: 'awaiting-wallet', target, functionName, data: encodeFunctionData({ abi: contractAbi, functionName, args }),value:String(value), at: Date.now() }));
      let hash; try { hash = await this.wallet.writeContract({ ...request, chain: null }); } catch (error) { if (error.code === 4001 || error.cause?.code === 4001) this.storage.removeItem(journal); throw error; }
      this.pendingHash = hash; this.storage.setItem(journal, JSON.stringify({ phase: 'submitted', hash, at: Date.now() }));
      const receipt = await this.public.waitForTransactionReceipt({ hash, confirmations: this.config.chainId === 31337 ? 1 : 2 }); if (receipt.status !== 'success') throw Error('The market transaction reverted.'); this.pendingHash = null; return receipt;
    } finally { if (this.pendingHash === null) this.storage?.removeItem(journal); this.busy = false; }
  }
  async reconcile() {
    return this.walletLock(() => this.reconcileLocked());
  }
  async reconcileLocked() {
    if (this.busy) throw Error('Wait for the pending transaction.');
    await this.check(); const key = `noerra-market:${this.config.chainId}:${this.market}:${this.owner}`, row = JSON.parse(this.storage.getItem(key) || 'null');
    if (!row) return 'No unresolved wallet action.';
    if (!row.hash) throw Error('Wallet submission outcome is unknown. Inspect the wallet transaction history before recovering this action; it will not be resent.');
    const receipt = await this.public.waitForTransactionReceipt({ hash: row.hash, confirmations: this.config.chainId === 31337 ? 1 : 2 }); this.storage.removeItem(key); this.pendingHash = null;
    return `Transaction ${receipt.status}: ${row.hash}`;
  }
  async buy(dollars) {
    if (typeof dollars !== 'string' || !/^\d{1,8}(?:\.\d{1,6})?$/.test(dollars)) throw Error('Enter an amount with at most six decimals.');
    const s = await this.status();
    if (s.pool.retailPrice <= 0n) throw Error('This access day has no funded capacity.');
    const max = parseUnits(dollars, 6), units = max / s.pool.retailPrice;
    if (!units || units > s.pool.listed - s.pool.sold) throw Error('Choose an amount within available capacity.');
    const cost = units * s.pool.retailPrice;
    if (units * s.pool.computePrice < BigInt(this.config.minimumComputeMicros || 0)) throw Error('Choose enough access to cover the provider minimum call budget.');
    const block = await this.public.getBlock();
    if (block.timestamp < s.epoch || block.timestamp >= s.epoch + 86400n) throw Error('This access day is not active. Refresh before buying.');
    if (s.allowance < cost) await this.transact(s.payment, erc20Abi, 'approve', [this.market, cost]);
    const receipt = await this.transact(this.market, abi, 'buy', [s.epoch, units, cost, block.timestamp + 300n]);
    for (const log of receipt.logs) { if (getAddress(log.address) !== this.market) continue; try { const event = decodeEventLog({ abi, data: log.data, topics: log.topics }); if (event.eventName === 'Bought') return { id: event.args.order, units, cost, hash: receipt.transactionHash }; } catch {} }
    throw Error('Purchase confirmed but its order could not be read. Preserve transaction ' + receipt.transactionHash);
  }
  async stake(tokens) { const amount = parseUnits(tokens, 18); if (amount <= 0n) throw Error('Enter a positive NOERRA amount.'); const s = await this.status(); const allowance = await this.public.readContract({ address: s.coin, abi: erc20Abi, functionName: 'allowance', args: [this.owner, this.market] }); if (allowance < amount) await this.transact(s.coin, erc20Abi, 'approve', [this.market, amount]); return this.transact(this.market, abi, 'stake', [amount]); }
  register(owned, listed, epoch = this.config.epoch) { const own = owned === '0' ? 0n : number(owned), list = listed === '0' ? 0n : number(listed); return this.transact(this.market, abi, 'register', [BigInt(epoch), own, list]); }
  async claim(epoch = this.config.epoch) { return this.claimDays([epoch]); }
  claimDays(epochs) { if (!Array.isArray(epochs) || !epochs.length || epochs.length > 31) throw Error('Choose up to 31 earnings days.'); return this.transact(this.market, abi, 'collectAndClaim', [[...new Set(epochs.map(String))].map(BigInt)]); }
  async configureRecurring(owned, listed, days = 30) {
    if (!Number.isSafeInteger(days) || days < 1 || days > 30) throw Error('Choose one to thirty recurring days.');
    const next = (BigInt(this.config.epoch) / 86400n + 1n) * 86400n, s = await this.status(next);
    if (s.pool.capacity === 0n) throw Error('The next day must be funded before choosing recurring terms.');
    const own = owned === '0' ? 0n : number(owned), list = listed === '0' ? 0n : number(listed);
    if (!own && !list || own + list > s.stake / s.pool.stakePerUnit || own > s.pool.personalCapacity) throw Error('Choose an allocation covered by your stake and funded personal capacity.');
    return this.transact(this.market, abi, 'configureRecurring', [own, list, next + BigInt(days) * 86400n, s.pool.policy]);
  }
  cancelRecurring() { return this.transact(this.market, abi, 'cancelRecurring', []); }
  requestExit() { return this.transact(this.market, abi, 'requestExit', []); }
  async withdraw() { const s = await this.status(), block = await this.public.getBlock(); if (!s.exit || block.timestamp < s.exit) throw Error(s.exit ? `Your stake is locked until ${new Date(Number(s.exit) * 1000).toISOString()}.` : 'Request unstake before withdrawing your NOERRA.'); return this.transact(this.market, abi, 'withdraw', []); }
  refund(id) { return this.transact(this.market, abi, 'refund', [number(id)]); }
  order(id) { return this.read('orders', [number(id)]); }
  async signAccess(challenge, expectedOrder) { await this.check(); if (!this.origin || challenge.origin !== this.origin || new URL(challenge.origin).origin !== this.origin || challenge.chainId !== this.config.chainId || getAddress(challenge.market) !== this.market || getAddress(challenge.address) !== this.owner || !/^0x[0-9a-f]{64}$/i.test(challenge.nonce) || !/^\d{1,30}$/.test(String(challenge.order)) || !Number.isSafeInteger(challenge.expires) || challenge.expires <= Math.floor(Date.now() / 1000) || challenge.expires > Math.floor(Date.now() / 1000) + 360 || expectedOrder !== undefined && String(challenge.order) !== String(expectedOrder)) throw Error('Unexpected access challenge.');
    if (challenge.epoch !== String(this.config.epoch)) throw Error('Unexpected access window.');
    return this.wallet.signTypedData({ account: this.owner, domain: { name: 'NoerraAccessSession', version: '1', chainId: this.config.chainId, verifyingContract: this.market }, types: { Access: [{ name: 'origin', type: 'string' }, { name: 'nonce', type: 'bytes32' }, { name: 'order', type: 'uint256' }, { name: 'epoch', type: 'uint256' }, { name: 'expires', type: 'uint256' }] }, primaryType: 'Access', message: { origin: challenge.origin, nonce: challenge.nonce, order: BigInt(challenge.order), epoch: BigInt(challenge.epoch), expires: BigInt(challenge.expires) } }); }
}
export const displayUsd = value => formatUnits(value, 6);
