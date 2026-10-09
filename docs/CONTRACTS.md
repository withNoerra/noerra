# Contracts

Noerra's contracts separate agent identity, operating funds, token markets,
and revenue distribution. Ethereum holds the canonical agent-token supply and
markets; provider payments and optional compute routes use Base.

## Source map

| Source | Responsibility |
| --- | --- |
| [NoerraAgents.sol](../src/agents/NoerraAgents.sol) | Registry, agent accounts, token creation, and credit accounting |
| [NoerraEthereumCreation.sol](../src/agents/NoerraEthereumCreation.sol) | Canonical USDC market and collected-fee allocation |
| [NoerraLaunchpad.sol](../src/agents/NoerraLaunchpad.sol) | Locked market creation and backing |
| [NoerraSleepingLaunchpad.sol](../src/agents/NoerraSleepingLaunchpad.sol) | Market launch before computer activation |
| [NoerraLaunchProtectionHook.sol](../src/agents/NoerraLaunchProtectionHook.sol) | Canonical market launch restrictions |
| [NoerraUsdcFeeHook.sol](../src/agents/NoerraUsdcFeeHook.sol) | USDC-side swap fees |
| [NoerraQuoter.sol](../src/agents/NoerraQuoter.sol) | Quotes derived from pool execution |
| [NoerraEcosystem.sol](../src/agents/NoerraEcosystem.sol) | Ecosystem revenue and separate NOERRA market components |
| [NoerraCanonicalToken.sol](../src/agents/NoerraCanonicalToken.sol) | Canonical bridge custody and token representations |
| [NoerraRecoveryVerifier.sol](../src/agents/NoerraRecoveryVerifier.sol) | Recovery evidence verification |
| [NoerraRevenueCoin.sol](../src/personal/NoerraRevenueCoin.sol) | Fixed-supply NOERRA token |

The source tree also includes optional compute and compatibility components.
Their presence does not mean a deployment enables those routes. Use the
selected deployment's verified configuration when integrating.

## Financial boundaries

Canonical ordinary-agent markets use a 1.75% USDC-side hook fee and zero LP fee.
The [market guide](MARKETS.md) explains the 50/20/10/20 allocation of collected
fees and the backer share's fallback to the agent.

Seed liquidity and token backing are permanent. Operating-account balances
remain subject to account permissions, spending ceilings, and reserves. A
token launch neither creates spendable USDC nor confirms provider funding.

The ecosystem vault's source allocation is 50% protocol treasury, 10% agent
operations, and 40% buyback allocation. A transfer to a buyback recipient is not
an executed market purchase. These source rules do not establish NOERRA's live
launch terms, token address, or current market state.

## Integrating

Obtain addresses from verified Noerra publication channels and confirm the
network, deployed bytecode, immutable bindings, and assets independently.
Review contract pins before constructing a financial SDK client. Do not use
addresses or deployment pins supplied only by a model response.

Show the complete quote and minimum output before signing. Persist the
transaction hash and [reconcile uncertain submissions](RECOVERY.md). Contract
tests establish behavior under their tested conditions; they do not certify a
live deployment or replace a security review.

## Build and test

From the repository root, with Node 24 and Foundry installed:

```sh
npm ci
npm run deps
npm run build:contracts
npm run test:contracts
```

[SDK](../sdk/README.md) · [Source](../src/README.md) · [Documentation](README.md)
