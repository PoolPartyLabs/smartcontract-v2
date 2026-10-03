# Run reports

Every `pnpm scenario` and `pnpm api:probe` run writes `<UTC time>-<kind>.json` and `.md` here (src/report.ts): the
steps and assertions, the gas of every transaction it sent and per verb, the Share Price per phase and at every Core
Vault event, the fee ledger (flow fee, Payout Fee, performance fee with its manager part and protocol slice,
management fee, bridge fees) and the balances at the end. Git ignores them; commit a run worth keeping with
`git add -f local-e2e/reports/<file>`.

Conservation only attributes market flows when transaction inputs and protocol/vault
events explain the token, amount and pinned counterparty. Unknown flows are listed in
`unexplainedFlows`, excluded from investment P&L and fail conservation. Run
`pnpm test:harness` for the unrelated 10 USDC outflow negative control and durable ACK
queue regressions. On freshly started forks, `KEEPER_FILL_DELAY_SECONDS=5
KEEPER_VAA_DELAY_SECONDS=1 pnpm check:recovery` runs the full lifecycle with reports
before fills and one injected temporary ACK-send RPC failure.
