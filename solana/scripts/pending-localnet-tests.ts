export const pendingLocalnetTests = [
  { path: 'tests/cctp/localnet.test.ts', reason: 'T8b: legacy FundState genesis lacks sealed assets/transport; requires its own Circle attester overrides.' },
  { path: 'tests/kamino/localnet.test.ts', reason: 'T8b: legacy FundState/position genesis is incompatible with sealed assets/transport and exhaustive registries.' },
  { path: 'tests/raydium/lifecycle.test.ts', reason: 'T8b: legacy FundState genesis lacks sealed assets/transport; requires Raydium-specific policies and reward clones.' },
  { path: 'tests/rehearsal/lifecycle.test.ts', reason: 'T8b/T8c: composed V1 rehearsal requires dedicated genesis and rehearsal-v1-swap build; never plain production acceptance.' },
  { path: 'tests/swap/cpi.localnet.test.ts', reason: 'T8c: standalone V1 probe requires its own executable, route ALTs and genesis; replace production acceptance with signed V2.' },
  { path: 'tests/swap/authorized.localnet.test.ts', reason: 'T8c: signed V2 standalone probe needs prepare-v2 oracle clones, probe binary, synthetic Fund state and route ALTs; absent from core/report genesis.' },
  { path: 'tests/swap/streams.localnet.test.ts', reason: 'T8c: requires verifier-fixture genesis and local DON config; not prepared by core/report setup.' },
];
