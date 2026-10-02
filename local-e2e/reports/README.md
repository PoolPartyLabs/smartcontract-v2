# Run reports

Every `pnpm scenario` and `pnpm api:probe` run writes `<UTC time>-<kind>.json` and `.md` here (src/report.ts): the
steps and assertions, the gas of every transaction it sent and per verb, the Share Price per phase and at every Core
Vault event, the fee ledger (flow fee, Payout Fee, performance fee with its manager part and protocol slice,
management fee, bridge fees) and the balances at the end. Git ignores them; commit a run worth keeping with
`git add -f local-e2e/reports/<file>`.
