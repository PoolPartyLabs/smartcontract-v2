# Third-party notices

<!--
@implements-rules-version: v2
@analytics-events: none (license and provenance inventory only)
-->

The [Pool Party license](LICENSE) governs only rights-controlled first-party
material. Upstream source, interfaces, fonts/artwork, generated mixed artifacts
and third-party marks retain their own rights. Importing, linking, vendoring or
copying a dependency does not transfer ownership to Pool Party.

[LICENSING.md](LICENSING.md) records first-party scope, prior MIT grants,
exceptions and deployment metadata. The
[legacy manifest](LICENSES/legacy-baseline.json) preserves per-file baseline
declarations and distinguishes the 27 files previously missing SPDX notices.

## Pinned dependencies

The following gitlinks are unchanged. [foundry.lock](foundry.lock) and
[.gitmodules](.gitmodules) identify their pins and sources. Follow each
dependency's source declarations and full license at its exact revision,
including nested dependencies.

| Dependency | Pinned revision | License boundary |
| --- | --- | --- |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std) | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | MIT / Apache-2.0 notices supplied upstream. |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | MIT. |
| [Uniswap V3 Core](https://github.com/Uniswap/v3-core) | `6562c52e8f75f0c10f9deaf44861847585fc8129` | Mixed source declarations. The root BUSL notice specifies a change to GPL-2.0-or-later with a 2023 change-date provision; the imported factory/pool interfaces declare GPL-2.0-or-later. |
| [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery) | `b325bb0905d922ae61fcc7df85ee802e8df5e96c` | GPL-2.0-or-later and other per-file declarations. Imported quoter/immutable-state interfaces declare GPL-2.0-or-later. |
| [Uniswap V4 Core](https://github.com/Uniswap/v4-core) | `e50237c43811bd9b526eff40f26772152a42daba` | Mixed **BUSL-1.1 / MIT / UNLICENSED** source declarations. [BUSL terms](https://github.com/Uniswap/v4-core/blob/e50237c43811bd9b526eff40f26772152a42daba/licenses/BUSL_LICENSE) specify a 2027-06-15-or-earlier change-date mechanism, not an automatic present MIT grant. |
| [Uniswap V4 Periphery](https://github.com/Uniswap/v4-periphery) | `9969eec44cfdf07e24b41de47f40276a58401976` | MIT root license; inspect imported files and its transitive dependencies individually. |
| [Wormhole Solidity SDK](https://github.com/wormhole-foundation/wormhole-solidity-sdk) | `a57e7d8f001f29a18463a7b7aae082e91b11aae1` | Apache-2.0, copyright Wormhole Project Contributors. Production imports use the `ICoreBridge` interface/types. |

No blanket statement that "Uniswap is MIT" is accurate for this dependency set.
Additional use grants, change-date rules and licenses must be checked in
the relevant pinned files.

## Production imports and combined work

The Uniswap V3 swap adapter imports `IUniswapV3Factory`, `IUniswapV3Pool`,
`IQuoterV2` and `IPeripheryImmutableState`, whose upstream declarations are
GPL-2.0-or-later. These imports are external protocol interfaces rather than
copied V3 pool/router implementations. This is a relevant source/legal boundary,
not a conclusion that all compiled code is GPL or custom-licensed.

The Uniswap V4 adapter imports upstream interfaces/types and mathematical
libraries including MIT-declared `TickMath` and `LiquidityAmounts`.
Other tests import and link BUSL components such as
`lib/v4-core/src/libraries/Pool.sol`; the imported library keeps its own terms.
Some upstream V4 test routers, including `src/test/PoolSwapTest.sol`, declare
`UNLICENSED`. Do not infer permission from their being publicly readable.

For any complete source bundle or compiled artifact, preserve upstream notices
and verify combined-work obligations before redistribution. The root custom
license does not relicense upstream bytes or waive GPL/BUSL requirements.
This PR does not change source bodies, compile artifacts, adjust dependency
pins or declare that those compatibility questions have been legally resolved.

## External interface subsets kept under existing MIT notices

| Repository file | Referenced upstream |
| --- | --- |
| `src/interfaces/external/IAToken.sol` | Aave V3 scaled-balance/ERC20 interface subset. |
| `src/interfaces/external/IAaveV3Pool.sol` | Aave V3 `IPool` / `DataTypes` subset. |
| `src/interfaces/external/ISwapRouter02.sol` | Uniswap swap-router-contracts v1.1.0 `IV3SwapRouter` subset. |
| `src/interfaces/external/IAcrossSpokePool.sol` | Across V3 SpokePool interfaces. |
| `src/interfaces/external/IAcrossMessageHandler.sol` | Across callback interface. |
| `src/interfaces/external/IChainlinkAggregatorV3.sol` | Chainlink `AggregatorV3Interface` subset. |
| `test/mocks/across/IAcrossSpokePoolLive.sol` | Across relay structs/events/errors and live interface subset; its source comment identifies revision `a634bea`. |

The existing SPDX identifiers and source comments are preserved. These records
do not manufacture an upstream grant; confirm the exact copyright/notice
requirements for copied portions before a new release.

## Pending adaptation provenance

- `src/factory/Create3.sol` references Solady/0xsequence CREATE3 patterns and
  implements a different proxy that bubbles constructor reverts. Pattern reuse
  alone does not establish a literal copy; retain its current MIT notice until
  provenance and any copied portions are classified.
- `test/mocks/v4/V4SwapRouter.sol` describes itself as "after" V4's test router.
  The simplified local implementation is not assumed a permissively licensed
  upstream copy. Its current MIT notice is retained pending that review.
- `test/security/integrations/mocks/PoolLibV4.sol` says its thin shell is
  reimplemented; the V4 Pool library it links remains upstream BUSL material.

These exceptions are explicit in the scope map rather than silently replaced
with Pool Party's SPDX identifier. Rights-cleared independent additions inherit
the current first-party policy; an upstream obligation still controls any
upstream-derived portion.

## Harness packages, marks and artifacts

The private-to-public classification of this repository does not relicense
`local-e2e/` dependencies. Its [package manifest](local-e2e/package.json) and
lockfile retain their existing versions and resolution data, including viem,
TypeScript and tooling. Only its own license metadata is updated.

Uniswap, Aave, Across, Wormhole, Chainlink and other names/logos identify
third-party projects. They remain their owners' marks; attribution is not a
trademark license or endorsement.

Historical deployment sources, metadata and verification stay linked to the
original release commits. A custom header on current source is not evidence
that the same bytecode was redeployed or that an upstream license changed.
