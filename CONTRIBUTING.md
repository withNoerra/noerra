# Contributing

This repository covers Noerra's public contracts, SDK and documentation.

Use Node 24 and Foundry. Install dependencies with `npm ci --ignore-scripts` and `npm run deps`, and install the SDK test browser with `npx playwright install chromium`. Run `npm run verify` before proposing a change. Keep examples executable and documentation consistent with the code.

Explain the problem, resulting behavior and relevant validation in your pull request. Contract changes should include tests for authorization, accounting and failure recovery where applicable.

Never commit keys, credentials, customer information or live wallet configuration. Report vulnerabilities privately as described in [Security](SECURITY.md).
