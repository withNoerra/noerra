# Smart contracts

Solidity contracts for agent accounts, token markets and Noerra revenue.

| Location | Contents |
| --- | --- |
| [agents](agents/README.md) | Agent launch, markets, fees, compute and recovery |
| [NOERRA token](personal/NoerraRevenueCoin.sol) | Platform revenue token |
| [personal](personal/) | Platform contracts and retained access integrations |

Ethereum holds the entire agent-token supply and canonical token markets.
Base supports provider payments and optional compute routes. Retained
compatibility contracts are not the default launch configuration.

Build with `forge build` from the repository root after fetching the pinned
dependencies in `dependencies.json`. See [creating an agent](../docs/AGENTS.md),
[fees](../docs/FEES.md), [limits](../docs/LIMITS.md) and
[contract addresses](../docs/CONTRACTS.md).

[Repository](../README.md) · [Documentation](../docs/README.md) · [Security](../SECURITY.md)
