# WP-09: proportional automatic unwind on the Hub

## PR #19 round-2 correction

H-2 is resolved by a terminal settlement for pending requester Market Costs worth less than
one whole share. The claim sizes that debt to one share instead of zero, still subject to the
holder balance, pre-unwind served-share cap, manager base (DEC-146), fresh reports (DEC-160),
and the existing cash check including the protocol flow fee. A genuine cash shortfall remains
retryable; rounding alone no longer leaves a funded request open (DEC-151).

When that one-share burn settles all pending cost and the gross outstanding is below its
value, the entire net share value is retained as `leaverCost`; no rounding surplus is paid to
the requester. The Payout Fee also remains in Idle, and the flow fee is paid normally.
`pendingLeaverCost` becomes zero, the request closes, and its remaining Payout Reserve is
released. No requester Market Cost is silently charged to remaining holders (DEC-118/141).

**Explicit spec divergence:** DEC-061/077 normally floor payout burns and leave the remainder
in the requester's shares. Per the round-2 instruction, terminal cost settlement instead burns
one whole share and retains the sub-share surplus for the fund. Ordinary payout sizing still
floors; this exception applies only to pending Market Costs and never increases the cash
payout. The extra retained value is strictly less than one share. This is an explicit
fund-favoring rounding rule, not a claim that the register already specifies it.

The regression recreates the review's exact state: 0.399743 USDC pending cost, 89,696 investor
shares, and 89,902 USDC Idle. It checks that zero available cash defers the burn, then restoring
Idle settles the debt with one share, keeps the net value in the fund, and permits a new
1,000-USDC Instant Payout. The completion suite also covers fee-bearing Standard Payouts,
manager-base protection, both modes at five fund sizes from 1,000 to 100,000,000 USDC, and
two 512-run fuzz properties over sizes, losses from 0% to 100%, and flow fees from 0 to 100 bps.
Every funded request and its subsequent request close; cost allocation, reserve release,
cash outflow, and share balances are checked throughout. Replacing the payout logic with the
round-1 implementation makes both named Instant/Standard completion regressions fail.

### Round-2 validation (October 2, 2026)

- `forge build --sizes`, `forge fmt --check`, and `git diff --check`: pass.
- Size inventory: 3/3 tests, 1 suite; all production contracts and linked libraries fit 24,576 bytes.
- H-1 regressions: 6/6 tests, including two 512-run fuzz properties, remain green.
- H-2 regressions: 7/7 tests, including two 512-run fuzz properties, pass.
- Full non-fork suite: 1,186/1,186 tests, 169 suites, no failures or skips.
- Full fork suite: 216/216 tests, 52 suites, no failures or skips; archive RPC environment
  sourced in the same shell, concurrency 4. No fork fixtures or CI shard membership changed.

| Runtime | Round-1 bytes | Round-2 bytes | Margin |
|---|---:|---:|---:|
| Core Vault | 21,487 | 21,487 | 3,089 |
| CoreVaultPayoutLogic | 11,597 | 11,758 | 12,818 |
| Spoke Vault | 23,096 | 23,096 | 1,480 |
| SpokeUnwindLib | 11,530 | 11,530 | 13,046 |

Only CoreVaultPayoutLogic grows (+161 bytes). Spoke Vault remains tightest; no production
contract or linked library has a margin under 1,000 bytes. The complete unchanged inventory
(runtime bytes / margin) is:

| Runtime | Bytes | Margin |
|---|---:|---:|
| AaveV3Adapter | 9,893 | 14,683 |
| AcrossBridgeAdapter | 6,713 | 17,863 |
| UniswapV3SwapAdapter | 10,586 | 13,990 |
| UniswapV4Adapter | 14,369 | 10,207 |
| ManagerFeeVault | 1,077 | 23,499 |
| ManagerRegistry | 1,603 | 22,973 |
| ShareToken | 1,822 | 22,754 |
| TransitEscrow | 894 | 23,682 |
| Create3Deployer | 1,342 | 23,234 |
| FundFactory | 18,347 | 6,229 |
| ChainlinkPriceSource | 1,709 | 22,867 |
| ValueReportReceiver | 8,080 | 16,496 |
| CoreVaultLogic | 13,739 | 10,837 |
| CoreVaultTransitLogic | 14,229 | 10,347 |
| CoreVaultIncomeLogic | 5,929 | 18,647 |
| SpokeCrossChainLib | 11,904 | 12,672 |
| SpokeIncomeLib | 698 | 23,878 |

No new scope or plan deviation beyond terminal cost rounding. The standing selected-tier
reference/spec conflict documented below remains unresolved and outside this correction.

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
  It measures repeated WETH/USDC positions with successful tier caching, not a worst-case bound
  for sixteen distinct tokens or repeated exclusions that roll back the quote cache.

| Runtime | Main bytes | WP-09 bytes | Remaining margin |
|---|---:|---:|---:|
| Core Vault | 20,996 | 21,433 | 3,143 |
| CoreVaultPayoutLogic | 9,098 | 11,085 | 13,491 |
| Spoke Vault | 22,304 | 23,096 | 1,480 |
| SpokeUnwindLib | 10,985 | 11,530 | 13,046 |
| UniswapV4Adapter | 18,079 | 14,369 | 10,207 |
| AaveV3Adapter | 10,158 | 9,893 | 14,683 |

No production contract or linked library has a margin below 1,000 bytes. Spoke Vault is tightest.

## PR #19 round-1 correction

H-1's two regression examples failed before the correction: Instant fund absorption was
9,998.04 USDC; Standard fund absorption was 9,996.104040 USDC against a 102 USDC cap.

Partial burns now use the largest whole-share amount whose actual Idle outflow fits available
cash: net payment plus the flow fee, excluding the retained Payout Fee and settled requester
Market Costs. Pre-unwind served-share and manager-base caps still apply. Binary search uses at
most 256 iterations, independently of the number of positions (DEC-033/105/118/141).

`PayoutRequest.pendingLeaverCost` retains every unsettled requester cost. The next attempt adds
that balance back to its post-unwind NAV, deducts only costs it can settle, and carries the rest
again. Receipts report only the new sale costs allocated to the fund; charging a previous
attempt's debt cannot produce negative or additional fund absorption (DEC-118/141/151).
An outstanding gross amount of zero does not discard pending costs: a debt-only retry can burn
remaining shares to settle them. Gross outstanding reduction saturates at zero. If the holder
has exhausted its shares, or no cash exists to pay the flow fee, debt remains on the open
request rather than being silently allocated to the fund.

The register overrides the plan's gross-cash partial-burn formula. The ABI adds one field to
the request getter; there is no upgrade or migration of existing immutable funds. Pending costs
are request accounting, not a newly introduced Share Assets bucket or a collectible receivable
for other valuation paths. The existing D-17 NAV add-back is used for the request's settlement.

Validation after the correction: build/sizes, formatting, size inventory (3/3), non-fork tests
(1,179 in 168 suites), and the entire fork suite (216 in 52 suites) pass. Six new tests include
two 512-run properties varying fund sizes, requested amounts, losses from 0% through 100%, and
flow fees from 0 through 100 bps. They check absorption caps, exact net-value reconciliation,
maximal affordable whole-share burns, delivery memory, pending debt and charge-once retries.
Existing reserve/callback/fallback tests now exercise actual net cash rather than gross cash.

| Runtime | Before correction | After correction | Remaining margin |
|---|---:|---:|---:|
| Core Vault | 21,433 | 21,487 | 3,089 |
| CoreVaultPayoutLogic | 11,085 | 11,597 | 12,979 |
| Spoke Vault | 23,096 | 23,096 | 1,480 |
| SpokeUnwindLib | 11,530 | 11,530 | 13,046 |

All production contracts and linked libraries remain within 24,576 bytes; none is below
1,000 bytes of headroom. No shared fork fixture or new fork scenario file changes.

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
