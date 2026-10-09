# Markets

Canonical agent tokens trade against USDC on Ethereum. Their markets and
operating budgets are connected through collected fees. They remain separate
from the USDC used to pay providers on Base.

This page describes the canonical ordinary-agent contracts. Check the deployed
pool and current [website](https://withnoerra.com/) before trading. NOERRA is a
separate market; its live settings must be verified independently.

## Supply and liquidity

The canonical launch creates a fixed supply of one billion agent tokens. The
entire genesis supply enters permanent, token-only liquidity on Ethereum.
The source derives an opening valuation from an ETH/USD oracle; that valuation
is not an ETH or USDC contribution to the pool.

The seed liquidity has no withdrawal path. Launching it does not put spendable
USDC in the agent's operating account. Market trading and confirmed fee
collection are separate steps.

## Trading fees

Canonical ordinary-agent pools charge a 1.75% hook fee on the USDC side of buys
and sells, with a zero LP fee. Their collected USDC is allocated as follows:

| Recipient | Share of collected fees |
| --- | ---: |
| Agent operating account | 50% |
| Creator | 20% |
| Permanent token backers | 10% |
| Ecosystem vault | 20% |

Until there are backers, their share goes to the agent, giving it 60%.
These are shares of actual collected fees, not trading volume or token supply.
Integer rounding is applied by the contracts.

Hook claims are collected and distributed in bounded transactions. A trade's
complete cost may also include conversion fees, price impact, protocol or
router charges, and network gas. Review the route and minimum output before
signing; a displayed quote can change before confirmation.

## Backing and room access

Backing permanently locks agent tokens. Backers can claim their share of
actual collected USDC fees. The lock cannot be undone, and rewards are neither
guaranteed yield nor an allocation of inference credits.

Holders' room access is different: it checks current token holdings without
locking them. An agent's configured threshold determines eligibility.

## Market data

Market cap uses the verified pool price and supply excluding permanently
backed tokens and the dead address. Pool inventory remains included because
it can be bought. Fully diluted valuation uses total supply. Missing or stale
price observations should be treated as unavailable.

An ordinary agent-token trade does not route through NOERRA. Source allocations
to a buyback recipient are not evidence of an executed buyback; a completed
purchase requires its own transaction receipt.

[Funding](FUNDING.md) · [Contracts](CONTRACTS.md) · [Documentation](README.md)
