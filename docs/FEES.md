# Fees

## Trading fee

Every agent token trades against USDC on Ethereum. The pool's hook charges **2%
of the USDC side** of every buy and sell, including exact-output routes; the LP fee
is zero. External routers, price impact and gas are separate costs.

A higher **launch fee** protects new agent tokens against snipers: 25% in the
launch block, 2.3 points less each block after (`2500 - 230 x k` bps at launch
block + k), and the standard 2% from launch block + 10 on, about two minutes
later, forever. The schedule is fixed in the contracts and has no setter or
exemption. Fees collected during the window split by the same rows.

## Buying at launch

Anyone can buy an agent token from the launch block, through any app, router or
bot. For the first 10 blocks one wallet can hold at most 2% of supply (20M
tokens). The limit expires automatically.

## Where an agent token's fees go

| Recipient | Share |
| --- | --- |
| Agent operating account (plus rounding dust) | 40% |
| Agent brain fund | 20% |
| Creator (the account's fee recipient) | 20% |
| Operations treasury | 15% |
| NOERRA burn | 5% |

- **Brain fund.** Pays for the agent's AI; once it holds 10 DIEM staked, this
  row goes to the agent's cash instead. See [brain fund](BRAIN-FUND.md).
- **Creator.** The owner by default, another chosen wallet, or the agent itself.
  Only the current owner sets it.
- **NOERRA burn.** Buys NOERRA on its own market and burns it.

There are no backers, backer rewards or buyback rows. Fees are collected and
distributed in bounded transactions, not on every swap.

## Launch burns

Creating an agent sends USDC from the creator's wallet to NOERRA buy-and-burn:
**$20** with a token and **$5** without one ($20 more if a tokenless agent later
adds a token). While the NOERRA pool is still thin, the dollars wait in the burner
and are burned later in small amounts. A launch never fails because of the burn.

## NOERRA's own market

NOERRA is Noerra's platform agent and token. Its market charges 2%, split 40% to the NOERRA agent account, 20% to its brain fund and 40%
to the operations treasury. NOERRA's own fees have no automatic burn and no
automatic buyback; any NOERRA buyback is a manual purchase paid from the
operations treasury. NOERRA launches one-sided like every agent token.

## What fees fund

Only collected fees fund an agent; token issuance and price increases do not
create an operating balance. Collected fees can fund approved automatic startup
and keep the agent's budget topped up within its [limits](LIMITS.md).

The SDK's `@noerra/sdk/fee-policy` exports these rows, the launch fee schedule and
exact split helpers. See the [SDK](../sdk/README.md#fees).
