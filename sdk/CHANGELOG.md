# Changelog

## 1.0.0

This release matches the final contracts and runtime.

- **Trading fee.** The fee is 2% on the USDC side. A higher launch fee runs for the first ~5 minutes to protect
  against snipers: every market (each agent token and NOERRA) charges 25% in its launch block, 92 bps less each block,
  and the standard 2% from launch block + 25 on. The schedule is fixed in the hook.
- **Agent token fee rows.** 40% agent, 20% brain fund, 20% creator, 15% treasury and 5% NOERRA burn.
- **NOERRA's own market.** 40% agent, 20% brain fund and 40% treasury.
- **Removed rows.** There are no backer or buyback rows.

### Breaking

- `NoerraAgentChain` (and the legacy `NoerraDiemMarket` / `NoerraDualMarket`):
  removed `back`, `backerStatus`, `claimRewards` and `claimCredits`. The SDK has
  no backing or backer-reward calls on any market.
- `creation()` no longer returns `backers`; canonical launches return `brainEscrow`.
- `@noerra/sdk/earned-diem` is read-only. The brain fund has no creator actions:
  removed `earnedDiemTransaction` and `NoerraEarnedDiem.connect`, `transact`,
  `reconcile` and `pending`; `earnedDiemActions` is empty and
  `validateEarnedDiemReceiptInput` always throws. `earnedDiemReserveAbi` now
  describes the reserve's read functions. `NoerraEarnedDiem({client, agentId})`
  only needs the owner session.
- `NoerraAgentsClient.earnedDiemReceipt` removed (there is nothing to verify).
- `automaticActivationCommitment` now requires `birthCheckpoint` (a nonzero bytes32, normally
  `birthCheckpointHash(...)`). It mirrors `NoerraAgentAccount.automaticActivationCommitment(expectedGeneration,
  nextSigner, destination, birthCheckpoint)`, and `activateApproved` takes the same `birthCheckpoint`. Commitments
  made without it are refused.
- `telegramGroup` replaces the actions `'begin'`, `'confirm'` and `'disable'` with `'connect'` and
  `'disconnect'`; a group connects as soon as the owner's paired Telegram account posts the code. The Telegram
  connection view has `group` instead of `publicRoom`.
- Chain 31337 (a local anvil node) is refused unless the constructor is given `localDevnet: true`. This covers
  `NoerraAgentChain`, `NoerraDiemMarket`, `NoerraDualMarket`, `NoerraAgentDiem` and `NoerraComputePool`. Production pins
  use chain 1 (8453 for the legacy Base markets).

### Added

- `@noerra/sdk/fee-policy` subpath with types: `TRADE_FEE_BPS`,
  `CREATION_FEE_ROWS`, `ECOSYSTEM_FEE_ROWS`, `LAUNCH_BURN_TOKEN_MICROS` ($20),
  `LAUNCH_BURN_TOKENLESS_MICROS` ($5), `creationFeeSplit`, `ecosystemFeeSplit`.
- `spending(agentId)`: today's max(floor, spendable / 30) budget, the own-wallet
  cap (max(3 x floor, the day's scaled limit / 10)) and the daily fuel cap (at
  least 0.005 ETH, max(0.005 ETH, 5M gas x base fee)).
- `serviceStatus(service)`: registry-approved services (effective 7 days after proposal).
- Type declarations for the creator fee dial (`feeRecipient`, `setFeeRecipient`),
  `hibernation`, owner principal (`ownerWithdrawal`, `ownerDeposit`,
  `requestOwnerWithdrawal`, `cancelOwnerWithdrawal`, `executeOwnerWithdrawal`),
  `FreezeStatus`, `upgradeComputer` and `computerAutoUpgrade`.
- `BRAIN_FUND_CAP_DIEM` ('10') and `PLATFORM_WITHDRAWAL_DELAY_SECONDS` (7 days).
- `@noerra/sdk/fee-policy`: `LAUNCH_FEE_START_BPS` (2500n), `LAUNCH_FEE_DECAY_BLOCKS`
  (25n), `launchFeeBps(launchBlock, blockNumber)` (exact mirror of the on-chain
  schedule), `TRADE_FEE_TEXT` and `LAUNCH_FEE_SCHEDULE_TEXT`. `LAUNCH_FEE_BPS` stays as
  the launch-block rate.
- `NoerraAgentChain.quote` and `NoerraEcosystem.quote` return the fee in force at the
  quoted block (`feeBps`, `feePercent`, `launchFeeActive`, `launchBlock`,
  `launchFeeEndBlock`, `quotedBlock`); `NoerraAgentChain.currentFee(poolKey, block)`.
- `quoteSleeping` reports `tradeFeeBps`, `launchFeeStartBps` and `launchFeeDecayBlocks`.
- `@noerra/sdk/agent-chain`: `birthCheckpointHash({binding, archive})`. It gives the hash of the birth archive the
  starter sealed, which becomes the account's first `checkpointHash` at activation. An agent lost before its first
  `pulseCheckpoint` can therefore still be recovered.
- Telegram group replies: `NoerraAgentsClient.telegramGroup(id, action?, requestId?)` with actions
  `'connect'`, `'disconnect'`, `'dismiss-delivery'` and `'retry-delivery'` (no action reads the status). It
  returns `{status, group, expiresAt, pairingUrl?, command?, limits, deliveries}`; `connect` returns a one-time
  `https://t.me/<bot>?startgroup=<code>` link. In the owner's connected group the agent answers mentions of its bot
  and replies to its messages, within a daily group budget and per-person limits.

### Changed

- `check()` (agent chain and NOERRA ecosystem) also pins the hook's
  `LAUNCH_FEE_START_BPS` and `LAUNCH_FEE_DECAY_BLOCKS`; the NOERRA check accepts the
  decaying `feeBps()` at every block of the window.
- `abi/NoerraNoerFeeHook.json` adds `LAUNCH_FEE_START_BPS`, `LAUNCH_FEE_DECAY_BLOCKS`
  and `poolFeeBps`.
- ABIs regenerated from the compiled contracts:
  - `NoerraAgentMirror` adds `frozen()` and `update(human, signer, generation, sequence, frozen)`.
  - `NoerraAgentMirrorRegistry.receiveAuthority` carries the freeze flag.
  - `NoerraAgentAuthorityMessenger` adds `sync(bytes32, uint256)`.
  - `NoerraRecoveryVerifier`, `NoerraPaidRecoveryVerifier` and `NoerraDstackPaidRecoveryVerifier` add the start-claim
    functions (`claimStart`, `renewStartClaim`, `startClaims`, `registerAndClaimStart`, `registerAndFundStart`,
    `registerAndCompleteStart` and related) and the events `StartClaimed`, `StartClaimRenewed`, `StartFunded`,
    `StartCompleted` and `StartActionBound`.
  - `NoerraCrosschainReinvestment` adds `currentBatchLimit()` and `currentDailyLimit()`.

### Removed

- The token-gated website chat room and the legacy one-to-one wallet chat: `newRoomRequestId`, `chatHistory`, `chat`,
  `roomMessages`, `sendRoom`, `recoverRoom`, `telegramRoom` and the room message and page types. Public profiles no longer include `chat`; agent configuration keeps `chat` only as a retired legacy field
  (`null` for new agents) so approved configuration hashes stay unchanged.

### Unchanged

- `launchSleeping` and `prepareAgent` approve exactly the $20 / $5 NOERRA launch
  burn; `brainStatus` / `depositBrain`; `freezeStatus`, `freezeCompromised`,
  `freezeCompromisedAndSync`, `unfreeze`; stewardship and recovery calls.

## 0.1.0

Initial version.
