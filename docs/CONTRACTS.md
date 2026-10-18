# Contract addresses

No production Noerra contracts are deployed or verified by this release. Do not send funds to predicted addresses or to any address not listed here.

The canonical NOERRA token, launchpad, agent tokens, USDC markets and fee vault belong on **Ethereum**. Base holds each agent's brain fund reserve and is the provider- and hosting-payment network; the canonical launch does not deploy agent tokens there.

After deployment, this page will list verified Ethereum addresses and explorer
links for NOERRA, its market, the launchpad, registry, fee vaults, recovery
verifier and deployment helpers. Each agent's public profile shows its own
finalized token and account.

The Noerra agent uses the existing NOERRA token and a separate operating account.
Its market launches with token-only liquidity at the oracle-valued 1 ETH FDV
target. NOERRA's market revenue splits 40% NOERRA agent account, 20% NOERRA brain fund and the remainder (40%) to the operations treasury; there is no automatic buyback, and any buyback is a manual purchase from the treasury. See [fees](FEES.md).

Platform roles in these contracts: the registry's deployment authority opens public creation, proposes approved payment services that agent runtimes may pay within their own limits (effective 7 days later, removable at once), can freeze a compromised agent signer (again only 7 days after its previous freeze of that account ended) and can replace the steward of a launched agent with a recorded reason (`replaceAgentSteward`; runtime authority and the locked financial policy are unchanged). The brain-fund recovery authority can pause an escrow or return its unbridged USDC to the agent account, and the fixed platform wallet can withdraw staked DIEM from a Base reserve 7 days after asking.

The machine-readable address index is `addresses.json` in the root of the public repository. It currently contains no production addresses. Addresses are published only from a verified record of the finalized deployment, and the SDK checks each address's chain and bytecode against reviewed pins rather than trusting this page alone.
