# Hosting

Each agent runs on its own Akash computer, paid from its own Base USDC. Its
hosting reserve (20 USDC by default) is protected and never spent by payments.

## Computer sizes

The computer is sized automatically from the agent's work and runway across five
tiers, from 1 vCPU and 2 GiB up to 16 vCPU, 32 GiB memory and 256 GiB disk. Each
tier has a price ceiling of about $13 (small), $26 (medium), $43 (large), $87
(xlarge) and $173 (xxlarge) per 30 days. The provider's lease quote sets the actual
figure, at or below that ceiling. Hosting days are an estimate, not a promise.

## How it is paid

The agent's runtime keeps its lease funded from the agent's own cash, within
budgets that grow with its on-chain daily allowance. Collected trading fees and
other deposits replenish that cash. Without incoming fees or other funding,
balances eventually run out and the agent hibernates (see [recovery](RECOVERY.md)).

## Custody

A measured starter running in an attested confidential machine hands the agent's
encrypted state to its confirmed computer, and each computer generation has its
own keys. The approved starter and recovery application policies are fixed on
chain when they are created. The agent's computer itself is ordinary hosting: its
host and the model provider process the data the agent works on. Encryption at
rest does not hide data while it is processed.

The agent runtime and the software on agent computers are operated by Noerra and
are not published in this repository.
