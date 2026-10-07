# V2 contracts licensing and scope

<!--
@implements-rules-version: v2
@analytics-events: none (source distribution policy only)
-->

The current first-party policy is
**[Pool Party Source-Available License 1.0](LICENSE)**. It applies to **all
Pool Party-authored V2 material** in this repository: existing and future core
vaults, spokes, factories, deployers, mandate logic, adapters, libraries, own
interfaces, tests, deployment scripts, local harness, configuration,
documentation and original assets. Work in progress is included; the policy
does not wait for a final release.

The custom SPDX identifier is
`LicenseRef-PoolParty-Source-Available-1.0`.
This is **source-available, not OSI-approved open source**. External dependencies
and preserved prior grants are separate legal boundaries.

## Permitted use and written authorization

Reading, local modifications/tests with test assets, study/contribution forks,
paid and unpaid security audits, and documented use of official Pool Party
deployments are permitted. Managers and investors may use their supported
features, including manager fees. Independently written adapters and integrations
may interoperate with official deployments and copy interface definitions or
integration examples as reasonably necessary for that purpose.

**Separate production deployments, free or commercial, and products, SaaS,
white labels or commercial redistribution using restricted implementation
material require prior express written authorization.** The
[license](LICENSE) defines these permissions and exceptions precisely.

A fork is not automatically official. Interface availability does not authorize
an adapter to alter a live fund, change its immutable mandate, bypass access
controls or move another person's assets.

Request other rights through the verified
[PoolPartyLabs organization](https://github.com/PoolPartyLabs) or a non-sensitive
issue. Only an agreement signed by an authorized representative, identifying
the legal entity and covered versions/rights, constitutes additional permission.

## MIT publication history remains effective

At public main
[`9e32ba98bd1dbc14de0256723336f93a40ad302a`](https://github.com/PoolPartyLabs/smartcontract-v2/commit/9e32ba98bd1dbc14de0256723336f93a40ad302a),
there was no root LICENSE. **374 Solidity files declared MIT and 27 had no
SPDX identifier.** The
[baseline manifest](LICENSES/legacy-baseline.json) lists those paths separately
and records the exact reference commit.

The [preserved MIT terms](LICENSES/MIT-legacy.txt) reproduce Pool Party's prior
MIT notice. The manifest identifies this notice's source; it does not invent a
retroactive MIT grant or exclusive ownership for a file that had no declaration.

**Valid previous MIT and other grants remain effective.** Earlier recipients
can continue to exercise those rights, including commercial use and distribution
with the required notices, on the material the grant covers. Unchanged licensed
portions retain those rights when included in a later version. The current SPDX
policy identifies Pool Party's present offer and future changes; it cannot make
the earlier MIT material exclusively noncommercial.

This means the new restriction can protect original additions/changes to the
extent Pool Party owns or can license them. It cannot prevent lawful reuse of
the earlier MIT-published implementation merely by changing its header.

## Source and dependency boundaries

| Material | Current notice and boundary |
| --- | --- |
| First-party `src/**`, `script/**` and `test/**` Solidity, excluding rows below | Custom SPDX with a prior-grant reminder; only comments change in this transition. |
| Pool Party's own `src/interfaces/**` | Current custom default; earlier MIT interface grants remain available. Necessary interface use for independent official-platform integrations is expressly permitted. |
| `src/interfaces/external/**` | Existing MIT notices retained: Aave, Across, Chainlink and Uniswap protocol definitions. No exclusive Pool Party ownership is asserted. |
| `test/mocks/across/IAcrossSpokePoolLive.sol` | Existing MIT notice and Across provenance retained. |
| `src/factory/Create3.sol` | Existing MIT notice retained while the Solady/0xsequence adaptation provenance and rights are verified. The root default does not override this exception. |
| `test/mocks/v4/V4SwapRouter.sol` | Existing MIT notice retained pending classification of the implementation described as "after" Uniswap's test router. Its upstream example is not assumed permissively licensed. |
| `lib/**` and nested dependencies | Exact upstream licenses at their pinned revisions. No gitlink, dependency body, pin or upstream notice is changed. |
| `local-e2e/**` | Current first-party policy subject to inherited rights/dependencies; package metadata references the full [local license](local-e2e/LICENSE). |
| Generated/compiled artifacts and historical deployment evidence | Mixed source rights and release-specific provenance remain. Do not treat all linked upstream bytecode as exclusively Pool Party material. |

The independently implemented shell in
`test/security/integrations/mocks/PoolLibV4.sol` imports and links the upstream
Uniswap V4 `Pool` library. That linked code retains its BUSL terms at the pinned
revision. A custom SPDX header on the shell does not relicense the upstream
library or authorize broader distribution of a combined artifact.

Read [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for exact dependency pins
and license granularity. "Uniswap" is not a single uniform license; imported
file declarations and applicable change dates matter.

## Solidity metadata and existing mainnet deployments

Adding or changing a source comment/SPDX header can change the Solidity metadata
hash and resulting bytecode even when the executable source body is identical.
This licensing PR does **not** compile, redeploy, change contract behavior or
replace already deployed sources/artifacts.

Historical mainnet addresses, explorer verification and receipts remain tied
to their original release commits, including release
[`797d592`](https://github.com/PoolPartyLabs/smartcontract-v2/commit/797d592).
Use those original sources for source matching. A future deployment must be
built and validated against its own exact commit and dependency/license set.

## Future files, adapters and contributions

All new rights-cleared first-party files inherit the current policy. New
first-party Solidity files must use the custom SPDX identifier rather than a
default MIT template. For upstream copies, retain their original notices and
add provenance before distribution. The listed unresolved exceptions require
a rights decision before their terms are changed.

Independent developers may create adapters for the official Pool Party platform.
The license permits required interface/example use without licensing the
developer's independently written code. It does not grant unrestricted reuse of
future restricted implementation changes or automatically modify live funds.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for explicit inbound rights required for
new contributions. Ownership is retained by the contributor unless separately
assigned; earlier contributors are not silently bound by new terms.

## Required review before merging this transition

1. Verify the contracting entity and commercial-authorization signatory.
2. Verify rights/assignments for current founder, employee and contractor code,
   including the 27 files without prior SPDX notices.
3. Approve the contribution permission and any necessary signed agreements.
4. Resolve the two adaptation-provenance exceptions and check license
   compatibility of copied, imported and linked dependencies/combined artifacts.
5. Check current hackathon, grant and audit-subsidy commitments against actual
   signed terms before describing the release as exclusively restricted.

Tracked in [POO-2269](https://linear.app/yeildbay/issue/POO-2269), rules v2.
The complete proposal is ready for review in PR #44; it changes no
operational permissions of the existing official platform.
