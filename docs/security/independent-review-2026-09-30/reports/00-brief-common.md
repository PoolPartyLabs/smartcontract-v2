# Pool Party v2 smart contract review: common brief for every reviewer

## What this is

An independent review of `github.com/PoolPartyLabs/smartcontract-v2` at commit `e5c778a` (branch `main`). It is a
buildathon MVP, nothing is deployed. The founder asked for four things:

1. a verification of the whole flow and of the integration between the contracts;
2. whether best practices were adopted;
3. whether the checks in the contracts are correct;
4. whether there are logic errors.

You are one of several reviewers, each with a distinct scope. A coordinator merges your findings and re-verifies
every one of them against the code. A finding without evidence is discarded, and a wrong finding costs a whole
verification round. Precision over volume: ten proven findings are worth more than forty guesses.

## Read first, in this order

1. `README.md` (vocabulary, contributing rules)
2. `docs/ARCHITECTURE.md` (the target design and the contract between modules)
3. `docs/DECISIONS.md` (DEC-001 to DEC-110, the business rules; a later decision overrides an earlier one)
4. `docs/OPEN-QUESTIONS.md`, lines 1 to 131 (founder rulings, the "MVP code stance" table, what earlier rounds closed)
5. `docs/REVIEW-LOG-2026-09-29.md` (findings of the earlier agent-driven verification rounds)

## What is already known (do not re-report it as new)

The code was written module by module by agents and went through adversarial verification rounds.
`docs/OPEN-QUESTIONS.md` and `docs/REVIEW-LOG-2026-09-29.md` record the accepted stances and the open questions.
A documented stance is NOT a finding. It becomes one only when:

- (a) the code does not do what the documented stance says;
- (b) the stance has a consequence the docs do not disclose (say which, with a scenario);
- (c) two documented stances contradict each other in the code;
- (d) a DEC rule is violated and no open question covers it.

In those cases cite the doc row. Treat the docs as claims to test, not as truth: the earlier rounds were run by the
same process that wrote the code, and the tests were written by the authors of the code they test.

## Method

- Read every line in your scope. Do not sample. For each external or public function trace: who may call it, input
  validation, state written, external calls and their order (checks-effects-interactions), reentrancy guard, events,
  and every revert path.
- Arithmetic: rounding direction and who it favours, precision loss, overflow and underflow, `unchecked` blocks,
  division by zero, decimals (USDC 6, shares 18, Q128 income index, 1e18 prices), casts that truncate.
- Accounting state: for every ledger variable, which functions write it and the invariant that ties it to the
  others (for example `payoutReserve <= idle`, ledger versus token balance, `totalSupply` a multiple of 1e18).
  Look for a sequence of calls that breaks the invariant or leaves value counted twice or not at all (DEC-104).
- Access control: every privileged function, and every function that should be privileged and is not.
- Integration points: what this module assumes about the modules it calls or is called by, and whether the other
  side really guarantees it. Read the other side's code to check; you may read anything in the repository.
- Think as an attacker in each role: a stranger, a shareholder, the manager (may be malicious: the design promises
  that a manager can only act inside the Mandate), a relayer or filler, a donor of tokens, a buggy or hostile
  adapter, the adapter guardian, the owner of the protocol registry.
- Best practices the founder cares about: every operation ends with an event that lets a server monitor it (route,
  amounts, slippage, fees, payer); custom errors; SafeERC20; no `tx.origin`; no unbounded loops on user paths;
  explicit handling of tokens with unusual behaviour where a token is not fixed; NatSpec that matches the code;
  every rule citing its decision.

## Evidence standard

Every finding needs: `path:line` (relative to the repository root), a concrete failure scenario (initial state, the
exact calls with actors and amounts, the wrong result, who loses what and how much), and the fix you recommend.

For every finding you rate Critical, High or Medium: write a Foundry PoC test and run it. The PoC must assert the
wrong behaviour explicitly, so that it would fail if the bug were fixed. Put PoCs under `test/review/<your-slug>/`
in YOUR working copy and reuse the existing fixtures and mocks (`test/unit/**/*Fixture.sol`, `*TestBase.sol`,
`test/mocks/**`). Report the exact command and the result. If you cannot produce a PoC, say why and mark the
finding PLAUSIBLE, never CONFIRMED.

When you investigate a suspicion and refute it, record it in "Checked and found correct" with the reason. That list
is as valuable as the findings.

## Severity

- **Critical**: direct loss or permanent lock of investor funds, or Share Price manipulation, reachable by a
  stranger or a shareholder.
- **High**: loss, lock or mispricing reachable under realistic conditions, or by the manager beyond the Mandate; a
  broken core invariant.
- **Medium**: bounded loss, griefing or denial of service of a flow, mispricing that needs unusual conditions, a
  violated DEC rule with material effect.
- **Low**: defence in depth, a missing check with no exploit today, a deviation from best practice with limited
  effect.
- **Info**: code quality, gas, NatSpec or docs that do not match the code, test gaps.

## Hard rules

- The repository is read-only for you: no commits, no pushes, no branch changes, no edits under `src/`, `script/`,
  `docs/` or to existing test files. The only files you may create are PoC tests under `test/review/<your-slug>/`
  in your working copy and your report.
- Do not spawn sub-agents. The machine budget is two agents at a time and both slots are in use.
- The machine has 8 CPUs and 8 GB of RAM, and another reviewer is running at the same time in another working
  copy. Run targeted tests only (`forge test --match-path 'test/review/<your-slug>/*' -vv`), never the full suite,
  never `forge coverage`, never `forge clean`. Do not install anything.
- Fork tests need RPC access. Do not depend on them for PoCs; use the unit fixtures and mocks.
- Everything you write is in English.

## Output

Write your report to the path given in your task, with this structure:

```
# <Scope> review

## Summary
(five lines at most: overall judgement, counts by severity)

## Findings
### [H-01] Title            (prefix C, H, M, L or I, numbered per severity)
- Status: CONFIRMED (PoC passes) | PLAUSIBLE (reasoned, no PoC)
- Where: path:line(s)
- Rule: DEC-nnn, doc row or best practice at stake
- What: one paragraph
- Scenario: numbered steps with actors and amounts, ending in the wrong outcome
- PoC: path, command and result (or why there is none)
- Fix: concrete
- Known?: whether OPEN-QUESTIONS or REVIEW-LOG mention it (cite the row) and why it is still a finding

## Checks and validations
(a table with every external or public state-changing function in scope: access control, input validation,
reentrancy guard, CEI order, event emitted; mark every gap)

## Checked and found correct
(suspicions you refuted, each with the reason)

## Not covered
(what you did not get to)
```

Your final message to the coordinator: the report path, the counts by severity, and the three findings you are most
sure of in two lines each. Nothing else.
