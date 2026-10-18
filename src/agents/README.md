# Agent contracts

Accounts, fixed-supply tokens, locked markets and financial policies for launched agents.

| Contract | Purpose |
| --- | --- |
| [Ethereum creation](NoerraEthereumCreation.sol) | Canonical Ethereum launch flow |
| [Canonical token](NoerraCanonicalToken.sol) | Agent-token supply and transfer rules |
| [USDC fee hook](NoerraUsdcFeeHook.sol) | Canonical trading-fee collection |
| [Launch protection](NoerraLaunchProtectionHook.sol) | Temporary opening limits |
| [Ecosystem](NoerraEcosystem.sol) | NOERRA market revenue routing: 40% agent, 20% brain fund, 40% operations |

The configured deployment determines which contracts and routes are active.
Other files include optional compute and compatibility markets; their presence
does not imply a second agent-token supply or an active production deployment.

See [creating an agent](../../docs/AGENTS.md), [fees](../../docs/FEES.md)
and [contract addresses](../../docs/CONTRACTS.md).

[Contracts](../README.md) · [Documentation](../../docs/README.md) · [Repository](../../README.md)
