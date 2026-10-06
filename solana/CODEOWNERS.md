# Parallel track ownership

This is coordination documentation, not a GitHub CODEOWNERS enforcement file.
Do not edit another track's worktree. Shared-file changes go through coordinator
integration, not independently regenerated manifests/IDLs (DEC-188, DEC-189).

| Track | Owned paths | Responsibility |
| --- | --- | --- |
| T0 `sol-t0-scaffold` | workspace/toolchain, `docs/`, `scripts/`, test helpers, root pointer | Compile baseline and clone harness |
| T1 core/report | `programs/pp_spoke/src/instructions/core/`, `programs/pp_spoke/src/instructions/report/`, `state/fund.rs` | Manager binding, immutable Mandate, ledger, Hub orders, report wire |
| T1b CCTP | `programs/pp_spoke/src/instructions/cctp/`, new `state/transit.rs`, `tests/cctp/` | Fast send/receive-and-credit, retries and transit proofs |
| T3 Kamino | `programs/pp_spoke/src/instructions/kamino/`, new `state/kamino.rs`, `tests/kamino/` | Supply-only cTokens, fresh principal/interest |
| T4 Raydium | `programs/pp_spoke/src/instructions/raydium/`, new `state/raydium.rs`, `tests/raydium/` | CLMM positions/NFT, Token-2022, fee-only income |
| T5 swap | `programs/pp_spoke/src/instructions/swap/`, `tests/swap/` | Guarded swap-to-ratio after venue DEC |
| Coordinator | `src/lib.rs`, `src/instructions/mod.rs`, `src/state/mod.rs`, `src/constants.rs`, `src/errors.rs`, `src/events.rs`, workspace manifests/locks | Shared exports, errors/events, integration and dependency additions |

Paths in the coordinator row are relative to `solana/programs/pp_spoke/` unless
explicitly workspace manifests. Track instruction module `mod.rs` files are
track-owned. Add protocol-specific helpers **inside your instruction module**,
and protocol-specific state files without simultaneously editing shared exports:
request the coordinator to add the `state/mod.rs` export. Use a track-local
Anchor error enum/event types until coordinated shared additions land. Tests
import `tests/helpers/` and register new test files under their track folder;
do not rewrite the test runner or clone manifest. Request extra clone addresses
through a separate explicit fixture extension. Never run formatter on EVM files.
