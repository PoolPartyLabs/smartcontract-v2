# WP-09: proportional automatic unwind on the Hub

## Design

- Idle pays first. Available USDC includes Free Idle, a Standard Payout's own Payout Reserve,
  and the Hub Spoke Vault's base-token Unallocated Balance.
- The first position attempt stores `(S - A/P) / (T - A/P) * 1.02`, capped at one, from shares,
  not pool-priced position values (DEC-132/137). The post-unwind burn never exceeds that attempt's `S`.
- Each position exits and sells its non-base principal in one self-call. Failure rolls back that
  position alone and emits its revert data. Stable adapter/key identities record successful delivery
  across retries; the stored fraction applies to an undelivered position's current size (DEC-148/151/178).
- Non-base Unallocated Balance gives the same fraction. Exit income remains collected income,
  never payout proceeds. The swap adapter's custody checks verify exact input debit and backed output.
- Sales use the Mandate swap adapter's best direct V3 tier, cached per token for successful steps.
  No production position adapter exposes pool-swap or spot-quote functions (DEC-136/143/153).
- Zero and limits of at least 10,000 bps mean no maximum. A sale over a smaller maximum excludes
  only its position. Sale events carry the applied maximum and minimum output (DEC-140/178; doc 15).
- Instant Payouts bear all measured Market Costs. Standard Payouts absorb up to 1% of each sale's
  pre-sale mid value; the requester bears the excess (DEC-118/141). The burn price adds requester
  costs back to post-unwind NAV before deducting those costs once from payment (plan reading D-17).
- Every accepted spoke report must remain fresh before burning, including Idle-paid claims
  (DEC-160). The Hub is valued directly after the unwind. A no-progress attempt burns nothing
  and retains the request, fraction, and delivery memory. A manager-base cap closes the request
  and sets `PayoutReceipt.cappedByManagerBase` (DEC-146/183).
- The Payout Fee stays in Idle; Operating Cash receives none of it (DEC-144).

## WP-12 boundary

This package does not publish or execute spoke UNWIND orders, bridge payout proceeds, or settle a
cross-chain payout. The existing `onReportApplied` and `_executeUnwindOrder` hooks remain clean
stubs for WP-12. `ICoreVault.OrderPublished(kind, orderId, requestId, attempt, wormholeSequence)`
already exists; no Hub path publishes an order in WP-09, so there is no publication to emit for
yet. WP-12 must emit it at actual publication, together with post-unwind report/settlement logic.
Income collection and closure publishers likewise belong to their own work packages.

The separately ported harness is unchanged. Foundry end-to-end assertions no longer assume that
only the registry's first Aave position pays: every Aave/V4 position gives its fraction, which
removes PR #12 carry-over L-1's stale Aave-first branch. The matching harness carry-over stays
with the separate harness port.

## Validation on October 2, 2026

After merging `origin/main` (`1db9a9d`) into the branch:

- `forge build --sizes`: passes with the existing compiler settings.
- `forge fmt --check`: passes.
- Contract-size suite: 3/3 tests pass; every production contract and linked library fits EIP-170.
- Non-fork suite: 1,173 tests in 167 suites pass, including invariants.
- Full fork suite: 216 tests in 52 suites pass on the archive RPC pins supplied by the handoff tool.
- CI scenario shard membership matches all 14 files calling `_createForks()`.
- Real V4/Aave positions sell through the real V3 swap adapter. A strict one-basis-point maximum
  excludes V4 while Aave delivers; a relaxed retry sells only undelivered positions.
- Sixteen positions unwind in 5,180,975 gas, below the 32,000,000 Arbitrum transaction cap.
  This is the unwind call alone, not the test's factory deployment/setup gas.

| Runtime | Main bytes | WP-09 bytes | Remaining margin |
|---|---:|---:|---:|
| Core Vault | 20,996 | 21,433 | 3,143 |
| CoreVaultPayoutLogic | 9,098 | 11,085 | 13,491 |
| Spoke Vault | 22,304 | 23,096 | 1,480 |
| SpokeUnwindLib | 10,985 | 11,530 | 13,046 |
| UniswapV4Adapter | 18,079 | 14,369 | 10,207 |
| AaveV3Adapter | 10,158 | 9,893 | 14,683 |

No production contract or linked library has a margin below 1,000 bytes. Spoke Vault is tightest.

## Deviations and spec divergences

- The typed `UnwindRequest`/`UnwindResult` ABI replaces the plan's outer opaque byte envelope;
  atomic self-call steps still use encoded bytes. No claimant supplies exit amounts or routes.
- D-16: no Network Costs or gas charge is introduced. The DEC-118 example without its 10 USDC
  network charge pays `30,000 - 600 - 75 - 61.20 = 29,263.80`. The isolated unit example uses
  a zero flow-fee fixture and therefore pays 29,338.80 instead.
- D-17/D-19 are implemented as planned: add requester Market Costs back for burning, and measure
  per-sale loss/Standard absorption against the selected V3 tier's pre-sale mid value.
- D-18 remains: pushing a position pool changes its exit composition and consolidated NAV.
  The share-based fraction bounds the position principal exposed, but is not an oracle price floor.
- Existing `ISwapAdapter`/`UniswapV3SwapAdapter` NatSpec warns against charging direct-route
  Market Costs until the founder rules on manipulation of a selected tier's mid. DEC-118/141
  and WP-09 explicitly require those costs, so this implementation follows the register/plan.
  A standing manipulated tier can overstate costs or block bounded sales; the existing adversarial
  V3 fork tests remain green. This conflict needs spec-owner review before third-party access.
- Tier selection inside a reverted atomic step also reverts its transient cache. A later position
  using that token may therefore quote again; successful steps choose only once per token per call.

No income production files, shared environment, dependency symlink, or harness process is modified.
