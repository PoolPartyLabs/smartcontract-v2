# Pool Party v2 — Solana spoke

This workspace is isolated from Foundry. **No mainnet transactions are authorized
by these scripts.** Implemented track primitives coexist with fail-closed
entrypoints. Authenticated bootstrap, canonical adapter accounting and exhaustive
reports are integrated, with a measured cloned lifecycle in `docs/REHEARSAL.md`.
Production signed V2 swap policy and non-ACK Hub commands remain blocked; this
workspace is not launch-ready.
New Funds only (DEC-188); closed-team upgradeable demo only (DEC-189).

## Pinned toolchain

| Component | Pin | Reason |
| --- | --- | --- |
| Anchor CLI / `anchor-lang` | 0.31.1 | Already installed through AVM; matching CLI, macros and IDL, without adopting the newer 1.x API during the critical-path build. |
| Agave CLI / validator / SBF builder | 2.3.0 | Installed local validator and `cargo-build-sbf`; use one runtime for all tracks. |
| Host Rust | 1.88.0 | Explicit workspace pin, not the moving `stable` alias. |
| SBF Rust | 1.84.1 (platform-tools v1.48) | Bundled by Agave 2.3.0; **not** the host Rust. The lockfile must build with this compiler too. |
| TypeScript tests | Node 24.14.0, npm lockfile | One shared Node test runner and `@solana/web3.js` v1; no venue SDK dependency tree. |

Anchor 0.31 recommends Solana 2.1; 2.3.0 is deliberately retained only after an
actual SBF build here. Anchor 1.2.1 exists in the AVM catalog as of 2026-10-06;
it is not needed to encode external CPIs and is not assumed compatible just
because research mentions it. Lean hand-written CPI wire encoders belong in
each adapter module: pin upstream source/discriminators in tests, validate
owners/account relationships, and never pull entire Raydium/Kamino/Circle/
Wormhole program crates into this workspace.

`Cargo.lock` also pins all Anchor macros to 0.31.1, `blake3` 1.8.2,
`proc-macro-crate` 3.3.0, `zeroize` 1.8.1, `indexmap` 2.10.0 and
`unicode-segmentation` 1.12.0. Unconstrained resolution on this date selected
Edition 2024 dependencies that Agave's Cargo 1.84 cannot parse. Do not regenerate
the lockfile or update these packages without repeating the SBF build.

Primary references: Anchor release notes `0-31-0`, `0-31-1`, `1-2-1` on
`anchor-lang.com/docs/updates/release-notes/`; Agave v2.3.0 platform-tools
reported by `cargo-build-sbf --version`. See the handoff research for pinned
external protocol sources; research is evidence, not a replacement for DECs.

```sh
rustup toolchain install 1.88.0 --profile minimal --component rustfmt
avm install 0.31.1
avm use 0.31.1
cd solana
cargo test --locked
anchor build
npm ci
npm test
./scripts/localnet.sh prepare
./scripts/localnet.sh start
npm run test:localnet
./scripts/localnet.sh stop
```

The scripts generate local-only test keypairs under ignored `.localnet/`; never
copy production keys into this workspace. `Anchor.toml`'s program address is a
**local scaffold placeholder**, not a deployment identity. Tests load the built
SBF binary at this address at genesis and do not need its private key. T1 must
replace it with the approved deployer-controlled identity before deployment;
do not run `anchor keys sync` during parallel development.

See [architecture](docs/ARCHITECTURE.md), [ownership](CODEOWNERS.md), and the
[clone harness](docs/LOCALNET.md) before implementing a track. Shared root files
are coordinator-owned after T0; instruction files/accounts are track-owned.
