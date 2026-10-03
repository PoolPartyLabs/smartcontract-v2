# Terminal closure dust (internal alpha)

DEC-149/163/167 and conformance B-02: a terminal remainder must not require new manager capital to finish closure.
The MVP excludes **less than 0.50 base-token units** (500,000 units for six-decimal USDC/USDG). Exactly 0.50 is
not dust. The alpha Across minimum deposit is approximately 0.50 USDC in either direction (release research,
2026-10-03); the adapter also charges a fixed 0.03 token units plus a rounded-up percentage. The threshold is
a versioned alpha route assumption, not a live Across API oracle. Check the route minimum again before release.
USDC and USDG on the alpha route both have six decimals and are treated at the existing 1:1 route convention.

- CLOSE excludes base-token Principal below the threshold, clears its unwind reservation and ledger entry, and
  emits `ClosureDustExcluded(token, amount, Principal)` from the Spoke Vault. It never excuses a failed position,
  a non-base Unallocated Balance, or a still-uncredited transfer.
- Principal arriving after CLOSE also excludes the aggregate base-token Unallocated Balance when it is below
  the same threshold and no unwind proceeds remain reserved. Arrival credits and `cumulativeReceived` still
  record the full arrival for Hub reconciliation. At/above-threshold Principal and all Income arrivals stay
  ledgered. No second CLOSE is needed for eligible late dust: an ordinary fresh report permits finalization.
- COLLECT after CLOSE excludes unsent converted Income below the threshold, emits the Income exclusion event,
  and reports the original token units sold with zero dollars obtained. The Core Vault closes those recognized
  token intervals at a zero-dollar rate, including their fee units, and emits its chain-specific exclusion event.
  Holders retain their already converted dollar entitlements; only the terminal unsendable interval is excluded.
- Excluded balances remain physically on the Spoke Vault but outside its ledger, available to permissionless
  `sweepExcess`. They are not included in the frozen `closedIdle` split. Open-fund Income dust still waits for a
  larger collection; the terminal rule does not apply to ordinary Income Withdrawal.
  The sweep emits `ExcessSwept(token, recipient, amount)` recording the dust actually transferred.
- Finalization accepts only a below-threshold base-token Principal remainder in an otherwise complete fresh CLOSE
  report, records it in an event, and still requires collected Income to be empty and its intervals converted.

This deliberately narrows DEC-163's literal “nothing remains on the spoke” to “no recoverable non-dust value remains.”
The task's terminal-dust instruction authorizes this alpha exception; it is not a claim that dust reached Hub Idle.
