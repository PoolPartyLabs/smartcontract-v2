# Operating Cash is disabled in this MVP

Ruling **2026-10-02**, DEC-187 and conformance B-03 supersede the legacy base-token top-up implementation for this
release. Native Operating Cash, measured-gas refunds (DEC-164/165) and bridge gas top-ups (DEC-185) are post-buildathon.

The Mandate rejects a nonzero floor or top-up on any chain. Both live `setOperatingCashParameters` entries revert
`OperatingCashNotSupported`, including `(0, 0)`; their existing role/chain checks remain. Internal top-up hooks are
no-ops, and the old linked-library top-up entry reverts. No value-moving operation can feed Operating Cash.
The manager pays their own gas; the keeper funds permissionless reports, deliveries and orders.

Storage fields, read-only views, event declarations and the minimal disabled hooks remain to minimize interface
churn. They do not implement native Operating Cash and are not a promise that a future version can reuse this
immutable deployment. Future native cash needs a separately reviewed version and its approved caps and spend rules.

Legacy cash-sink PoCs now assert prevention. All shared unit, security, factory and fork fixtures use zero creation
parameters; fork fee/conservation expectations remove only the former cash deduction, not bridge or Market Costs.
