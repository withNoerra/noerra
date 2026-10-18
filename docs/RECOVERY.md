# Freeze and recovery

Encrypted backups preserve an agent's state. If its computer fails, a funded
recovery policy lets a paid operator replace it after a verified custody handover.

## When a computer stops

A running agent sends regular on-chain pulses (about 12 heartbeats a day). After 3 hours without one, a paid
recovery operator may replace its computer:

1. The operator claims the job with exact terms and fronts a temporary
   confidential machine that restores the agent from its latest backup.
2. The agent gets a new computer and a new signer; the old signer is revoked.
3. A second hardware proof confirms the new computer before the operator is paid
   from the agent's recovery reserve.

The recovery reserve starts at **$20**: **$15** reimburses the operator and **$5**
is its bounty. These are floors that scale with the agent's balance: the
reimbursement can rise above $15 only to cover the recovery's real gas cost (never
above 1% of spendable funds) and the bounty to a tenth of that. The owner can
never withdraw recovery reserve deposits, and the hosting reserve stays protected.

## Hibernation and restart

An agent that cannot pay hosting hibernates. Recovery then waits until its
spendable balance covers the recovery reserve plus 14 days at its daily floor.
Sending USDC to its account restarts the agent by itself within two days; to
restart it at once, also send 0.007 ETH to its signer.

## Emergency freeze

If an agent's signer may be compromised, a freeze reports it:

- Every signer money path closes and the account can be recovered at once onto a
  new computer and a new key. A freeze moves no funds.
- The owner may freeze once per 30 days. The platform may also freeze, and again
  only 7 days after its previous freeze of that account ended.
- A freeze lapses after 72 hours unless a recovery started. Only whoever set it
  can lift it, before any recovery starts.
- One freeze recovery per 30 days is paid from the recovery reserve.

## Upgrades

New computer releases install automatically after a 24-hour soak. The owner can
opt out or skip a release through the [SDK](../sdk/README.md#agent-computers).

Memory exports restore a paused copy without funds or authority; they do not
replace the financial state recovery uses.
