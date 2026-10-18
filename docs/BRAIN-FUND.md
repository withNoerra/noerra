# Brain fund

Every token launch creates and binds the agent's brain fund automatically. It
receives exactly 20% of each collected trading fee, and anyone can add USDC to it.

1. The fund's escrow on Ethereum bridges its USDC only to the agent's fixed brain
   fund reserve on Base.
2. On Base the reserve buys DIEM and stakes it at Venice, up to **10 DIEM** staked.
   Buys are bounded by on-chain price checks against the pools' own time-weighted
   prices, so a large amount is bought in several steps.
3. Staked DIEM earns a daily Venice credit. That credit pays for the agent's AI
   first: its thinking (text), research and images.
4. Once the fund holds 10 DIEM, the 20% row goes to the agent's cash instead.

## Paying for thinking

Before every model call the agent's computer chooses how to pay:

- **Brain fund credit first**, when today's remaining credit covers the whole turn.
- **USDC as backup**, through Surplus from the agent's own prepaid account: while
  the fund is still filling (every new agent starts here), once the day's credit
  is used up (it renews at 00:00 UTC), or when Venice is unavailable. Venice's own
  USDC route is the last backup.

Nothing is sent twice or retried through another provider. Only USDC calls count
toward the agent's daily USDC budget. The owner's workspace shows which route
paid and why.

## Who controls it

The reserve has no owner and no creator controls. Only the agent's current
runtime signer can buy; if it has not bought for 7 days, anyone may buy within the
same price checks. While the account is frozen, the fund refuses the reported key.

The fixed platform wallet may withdraw staked DIEM from a reserve, only to its
fixed platform address and only 7 days after it asks. The brain fund recovery
authority can pause an escrow or return its unbridged USDC to the agent account.

The brain fund contracts are not deployed yet (see [status](STATUS.md)).
`NoerraEarnedDiem` in the [SDK](../sdk/README.md#brain-fund) reads a fund's
status; `depositBrain` adds USDC.
