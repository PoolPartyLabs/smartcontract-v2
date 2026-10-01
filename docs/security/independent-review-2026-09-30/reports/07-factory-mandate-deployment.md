# Fund creation, Mandate and deployment review (factory)

## Summary
The factory, CREATE3 and code stores are mechanically sound: the proxy bytes, the address formulas, salt binding, revert bubbling, deployment order and every constructor argument check out. The weak point is what nothing checks across chains: the hub sends capital to a Spoke Vault that nothing has shown to exist or to run the hub's Mandate, and a spoke's reporting parameters are not checked against the chain.
Counts: Critical 0, High 2, Medium 1, Low 1, Info 8. Every H, M and L has a passing PoC under `test/review/factory/`. The Across fill behaviour the H-01 PoC relies on was confirmed on the live Robinhood SpokePool (fork).

## Findings

### [H-01] The hub sends capital to a Spoke Vault that nothing shows exists; a send made before `createSpoke` is lost to the fund yet stays in Share Assets for good
- Status: CONFIRMED (PoC passes; the live Robinhood SpokePool's behaviour was confirmed on a fork)
- Where: `src/core/CoreVaultLogic.sol:638-668` (`_checkSend`: never asks for a report, a sign of life or anything about the destination), `:143-158` and `:204` (no report means spoke value 0, and mints do not revert), `:541-560` (a genuine post-deadline report that omits the id "proves" non-arrival), `:735-745` (`recognizeRefund` waits for an Across refund that cannot come); `src/factory/FundFactory.sol:138-181` and `:184-210` (the hub fund is live at once; `createSpoke` is a separate transaction on another chain, at any later time); `src/spoke/SpokeVault.sol:556-563` (permissionless sweep of anything unledgered).
- Rule: DEC-104 (value counted in a base although no ledger holds it), DEC-089 (a chain is supported only through a live route), DEC-066 and DEC-090 (transit outcomes), README contributing rule 2 (an uncovered case takes the conservative path and reverts).
- What: `sendToSpoke` sends to the Mandate's predicted Spoke Vault whether or not it exists. If Across fills before the vault has code, the live SpokePool transfers the output tokens and skips `handleV3AcrossMessage`, because the recipient is not a contract. No ledger credits the arrival and `cumulativeReceived` never counts it. When the vault is created later, the tokens are unledgered and anyone sweeps them to the Protocol Recipient. The spoke's first report lists no arrival, so `attestExpiry` succeeds. The transit then sits in `ExpiryAttested` for good: there is no refund, because the deposit was filled. Share Assets keep counting `amountToArrive` as In-flight Value, and the unknown-origin deduction never applies because the spoke never credited anything. A hub Mandate whose spoke can never be created (the authors' own `test_DEC087_verify_hubMandateMayNameASpokeThatCanNeverBeCreated`) reaches the same state: the tokens stay at the empty address.
- Scenario (PoC numbers; fixture Mandate: Spoke Cap 200,000, 50 bps bridge fee cap):
  1. Manager `createFund` on Arbitrum. `createSpoke` on Robinhood has not run yet.
  2. Alice deposits 100,000 USDC: Idle 99,750, 99,750 shares.
  3. Manager calls `sendToSpoke(0, 50,000 USDC, quote 49,975 USDG)`. The cap check passes (no report means spoke value 0). A relayer fills 49,975 USDG to the predicted address, which has no code, so no callback runs.
  4. After the fill deadline the manager runs `createSpoke` from the hub's own Mandate. `mandateHash()` equals the hub's, so the check DEPLOYMENT.md tells investors to run passes. The vault's ledger and `cumulativeReceived` are 0, and `sweepExcess(USDG)` sends the 49,975 USDG to the Protocol Recipient.
  5. On Arbitrum the report is accepted, `attestExpiry` succeeds and `recognizeRefund` reverts `NoRefund` for ever. Share Assets are 99,725 while the fund holds 49,750.
  6. Bob deposits 50,000 at the overstated price. Alice requests 99,600 Instant and receives 97,358.05 USDC, although the real assets behind her shares were 49,750. Bob's shares show 49,874.50 USDC, but Idle holds 25.47 USDC; the rest of his claim is the ghost value.
  - Loss: the whole amount sent, shifted from the holders who remain to those who leave first. A manager who holds shares can cause this on purpose and redeem at the inflated price. The only way back is for the Protocol Recipient to return the value (DEC-101), by donating `amountSent` to the transit's escrow or by re-bridging with the transit id.
- PoC: `test/review/factory/H01_SendToASpokeThatDoesNotExist.t.sol` (fixture `FactoryReviewFixture.sol`: the real factory and every real fund contract on two simulated chains). Command: `forge test --match-path 'test/review/factory/H01_*' -vv`. Result: PASS (logs: Share Assets 99,725,000,000, Idle 49,750,000,000, Alice received 97,358,053,369, Idle left 25,465,414).
  - Live-pool behaviour: `test/review/factory/Fork_AcrossFillToCodelessSpokeVault.t.sol`, run with `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com ROBINHOOD_FORK_BLOCK=76649566 forge test --match-path 'test/review/factory/Fork_*' -vv`. Result: PASS. The real `fillRelay` to an address without code, with a non-empty message, succeeds and credits the tokens.
- Fix: in `_checkSend`, require `IValueReportReceiver(w.reportReceiver).hasReport(spokeIndex)` before any send. An accepted report proves that the Spoke Vault exists at the Mandate address, because Wormhole attests the emitter; with the H-02 fix it also proves the vault runs the hub's Mandate. In DEPLOYMENT.md, make "createSpoke, then `report()` and deliver it" a precondition of the first send.
- Known?: No row in OPEN-QUESTIONS or REVIEW-LOG. FundFactoryVerifyRound2 notes that a hub Mandate may name a spoke that can never be created and says it is "recorded so DEPLOYMENT.md can warn about it". DEPLOYMENT.md has no such warning, and the consequence (the hub still sends, and the value turns into ghost In-flight Value) is not recorded anywhere. OQ-09 and CS-OQ-6 cover arrivals the spoke did credit; here nothing is credited.

### [H-02] FF-OQ-1's residual is a full-drain path: the hub accepts a spoke built from a divergent Mandate end to end, and it could detect it with data already on chain
- Status: CONFIRMED
- Where: `src/factory/FundFactory.sol:190-202` (`p.mandateHash` is supplied by the caller and only compared with the Mandate the same caller passes); `src/report/ValueReportReceiver.sol:144-202` (checks emitter, fund id, chain, sequences and age, never the Mandate); `src/libraries/ReportCodec.sol:88-103` (the report carries no Mandate hash); `src/spoke/SpokeVault.sol:160,166,173,178` (the spoke enforces its own `maxReportAge`, hub USDC and `maxBridgeFeeBps`); `src/spoke/SpokeCrossChainLib.sol:215-223` (fee check against the spoke's copy); `src/core/CoreVaultLogic.sol:638-668` (no attestation required before sending).
- Rule: DEC-030 and DEC-053 (the rules are fixed at creation and the manager acts only inside them), DEC-087 (destination locked by the core), FF-OQ-1.
- What (lead 1): with the same manager, number and hub, the fund id and addresses are the same, so the manager can create the spoke at the address the hub trusts, from any Mandate that passes `validate`.
  - Fields that may differ while every factory check passes: everything except `manager`, `hubChainId`, this chain's `spokeVault` and `spokeToken` (which must be USDG), and the listed addresses (which must be predictions).
  - What that buys on the spoke: arbitrary hookless pools, so DEC-030's "the manager cannot create a pool and operate in it" no longer holds and own-token pools can drain the spoke (shown at creation by `test_FFOQ1_verify_managerCanCreateTheSpokeFromAMandateOtherThanTheHubs` in `test/unit/factory/FundFactoryVerifyRound2.t.sol`). Also a `maxBridgeFeeBps` for sends home up to 10,000, and a spoke `maxReportAge` that sets when the spoke drops its return leg (core-a H-02, on demand). `usdc` (the output token of sends home) can only harm itself, because the hub's handler rejects any other token. Operating Cash values and the hub-only fields are free too.
  - What the hub accepts: every report (it checks only fund id, chain and emitter) and every arrival the spoke's report lists.
- Scenario (PoC):
  1. The hub Mandate shows `maxBridgeFeeBps` 50 and a Spoke Cap of 200,000. Alice deposits 1,000,000. The manager sends 200,000 and 199,900 USDG arrive.
  2. The manager runs `createSpoke` from the same Mandate with `maxBridgeFeeBps = 10,000`, passing its hash. The vault lands at the address the hub names. A spoke built from the hub's Mandate refuses the next step with `BridgeFeeAboveMax`.
  3. The manager calls `sendToHub(199,890 USDG, quote{outputAmount: 1, exclusiveRelayer: manager's relayer, exclusivityDeadline: 21,600})` and it is accepted. The exact `depositV3` call is asserted in the PoC.
  4. The hub accepts the report, confirms the arrival and credits the 1-unit fill. Share Assets fall from 997,400 to 797,500.000001: 199,899.999999 USDC went to the manager's relayer, which Across repays ~199,890 USDG. Cap usage is back to 0, and a second 200,000 send is accepted.
  - Worst case: each cycle takes one report delivery (15 to 20 min), so all Free Idle is gone in about five cycles, roughly two hours for this fund. Only the Payout Reserve and what holders pull out through Instant Payouts meanwhile survive.
- PoC: `test/review/factory/H02_DivergentSpokeMandateAcceptedByTheHub.t.sol`. Command: `forge test --match-path 'test/review/factory/H02_*' -vv`. Result: PASS.
- Fix: two changes, both using data that is already on chain.
  1. Put `mandateHash` in `ReportCodec.Report` (version 3), filled from the Spoke Vault's immutable. The receiver takes the expected hash at construction (the factory has `m.hash()` when it deploys the receiver, `FundFactory.sol:172-177`) and reverts `ReportMismatch` on any other hash.
  2. H-01's `hasReport` gate before any send.
  - Cost: one more word per payload (about +22k gas on the first delivery, at most about 5k on later ones since the stored word does not change, and 32 more bytes of Wormhole message), one comparison, one cold STATICCALL (about 2.6k) per send, and one delivered report per spoke before its first send. The report building lives in the library, so the Spoke Vault's 932 B of headroom only has to absorb one more config word.
  - Effect: a divergent spoke can still be created but can never receive capital. The hub-attested `FundCreated` (FF-OQ-1's full fix) is then no longer needed for safety.
- Known?: FF-OQ-1 (OPEN-QUESTIONS row 75, DEPLOYMENT.md "Known limits") records the residual and tells investors to compare `mandateHash()`. It is still a finding under the brief's rule (b), because four consequences are not disclosed:
  1. The hub accepts that spoke's reports and arrivals and gives no on-chain signal.
  2. The comparison is only possible once the spoke exists, while `createSpoke` can run after deposits and the hub never waits for it (H-01).
  3. The stake is all capital sent to the spoke, repeatable cap after cap, not "other rules".
  4. The divergence can be detected on chain today.

### [M-01] A spoke's reporting parameters are unchecked manager inputs; a report lifetime below the spoke's finality, or a wrong Wormhole chain id, makes every report undeliverable and locks everything sent to that spoke
- Status: CONFIRMED
- Where: `src/mandate/Mandate.sol:272-276` (only non-zero is required); `src/factory/FundFactory.sol:314-335` (addresses are checked, the chain's reporting properties are not); `src/report/ValueReportReceiver.sol:103-111,152-153,177-181` (takes them as given); consequences at `src/core/CoreVaultLogic.sol:489-505` (held apart until listed) and `:548-550` (the time path attests expiry).
- Rule: DEC-094 ("fixed and derives from a property of the spoke chain"), DEC-099 ("a per-supported-chain parameter", Robinhood about 925 to 1,190 s plus one block), DEC-089 (a protocol-level supported-chain list with per-chain parameters, the Mandate chooses within it), DEC-086.
- What (lead 2): a finalized Robinhood VAA exists only after about 925 s. With `maxReportAge` below that, every report is `ReportTooOld` at the earliest delivery. With a wrong `wormholeChainId`, every genuine VAA comes from an `UnknownEmitter`. Either way the fund is created on both chains and works until capital comes back. Every send home is held apart for good, sends out attest expiry through the time path although they arrived, and the spoke's capital can never pay a Payout. An investor cannot reasonably know Robinhood's finality or its Wormhole id (72), and a 600 s lifetime looks stricter, not broken.
  - The other extreme is reasoned, not in the PoC. `maxReportAge = 2^32-1` (136 years) voids the mint freshness guard (Q57 reading), the expiry time path (`CoreVaultLogic.sol:548`) and the future-timestamp bound (`ValueReportReceiver.sol:179`). It also makes the spoke list every send home for ever (`SpokeCrossChainLib.sol:300-302`), so reports grow with ordinary use until they become undeliverable (spoke-b H-01's end state).
- Scenario (PoC):
  1. The Mandate sets `maxReportAge` 600. `createFund` and `createSpoke` succeed. Alice deposits 1,000,000 and the manager sends 100,000 (99,950 arrive).
  2. The manager sends 99,940 home and a report is published at R.
  3. Delivery at R + 925 reverts `ReportTooOld(925, 600)`.
  4. The send home fills 99,900 USDC on Arbitrum. `unmatchedArrivals` holds 99,900, Idle is unchanged and `sweepExcess` returns 0.
  5. The outgoing transit is attested expired and `recognizeRefund` reverts `NoRefund`.
  6. Alice's full exit is a Partial Payout: 897,499 paid and 99,951 outstanding that can never be paid.
  - The same happens with `wormholeChainId` 23.
- PoC: `test/review/factory/M01_UnreportableSpokeLocksItsCapital.t.sol`, 2 tests. Command: `forge test --match-path 'test/review/factory/M01_*' -vv`. Result: 2 PASS.
- Fix: follow DEC-089 and DEC-099. Put a per-spoke-chain table (EVM id to Wormhole id and report lifetime) in the factory wiring, and in `createFund` either require every Mandate spoke to match it or take the values from the table. At minimum, bound `maxReportAge` in `validate` to [chain finality + one block, a small multiple of it].
- Known?: The Q66 row puts `maxReportAge` "per spoke in the Mandate" with a recommended value. The consequence of a value below finality is not disclosed, and the Wormhole id is not mentioned. core-b H-02 (sends home stranded when not listed in time) and spoke-b H-01 (reports made undeliverable by size) reach the same end state from other causes. This one is a creation-time value and permanent from day one.

### [L-01] Mandate lists are unbounded; fund creation passes Arbitrum's per-transaction gas cap at about 30 extra hub pools, and then EIP-3860, with no named error
- Status: CONFIRMED (measured)
- Where: `src/mandate/Mandate.sol:163-182,286-328` (no length bounds; O(n^2) duplicate scans, run by every fund contract); `src/core/CoreVaultBase.sol:119-148` and `src/spoke/SpokeVault.sol:199-215` (the Mandate is copied into storage); `src/factory/FundFactory.sol:478,509` (the init code carries the ABI-encoded Mandate); `src/factory/Create3.sol:48-53`.
- Rule: best practice (bounded work, explicit errors); DEPLOYMENT.md ("Both fit the 32M per-transaction limit").
- What:
  - Gas: `createFund` execution gas is 20.7M with the fixture Mandate, then 24.0M, 27.6M, 32.0M and 37.0M with 10, 20, 30 and 40 extra hub V4 pools, each also an unwind step. The real transaction adds about 0.6M for its 36 KB of calldata. A fund with about 30 or more hub pools can never be created on Arbitrum, and the transaction fails for gas with no explanation.
  - Init code: at 66 extra pools (Mandate encoding 14,528 B) the Core Vault's init code is 49,316 B, above EIP-3860's 49,152. The CREATE3 proxy's CREATE fails and `createFund` reverts with empty data (probe under the mainnet limit).
  - Tests: this repository's test EVM enforces neither wall. The same probe deploys 49,153 B of init code under the default configuration, so the suite cannot see these limits.
- PoC: `test/review/factory/L01_MandateSizeInitcodeCliff.t.sol`, 3 tests.
  - Command: `forge test --match-path 'test/review/factory/L01_*' -vv`. Result: PASS (gas table above; init code 49,316).
  - Probe: `FOUNDRY_CODE_SIZE_LIMIT=24576 forge test --match-path 'test/review/factory/L01_*' --match-contract L01_InitCodeLimitProbe -vv`. Result: PASS, deployment refused with 0 bytes of revert data.
- Fix: bound each list in `MandateLib.validate` with named errors, sized from a measured gas budget (for example per-chain pools, unwind steps, spokes). Consider storing only the per-chain slices each contract needs. Add a creation test under mainnet limits (`code_size_limit`, a 32M gas cap).
- Known?: No.

### [I-01] `wiring().coreVaultLogic` and `wiring().spokeCrossChainLib` are not bound to the code the factory deploys
- `src/factory/FundFactory.sol:93-96,112-115`; NatSpec at `:25-28` and `src/interfaces/IFundFactory.sol:41-44`. The factory checks only that the libraries have code. The pinned hashes are whatever the operator passes, so "the code linked to `coreVaultLogic`" is not enforced, and `wiring()` can name a library the funds do not use. Verification rests on recomputing the hashes from a local build (DEPLOYMENT.md). Either say so in the NatSpec or take the unlinked code and link offsets and check them.

### [I-02] Code-store immutability rests on the operator's chunk list
- `src/factory/CodeStore.sol:53-70` never checks the leading STOP byte, and `src/factory/FundFactory.sol:507-510` never re-hashes the stored code at deployment. A "chunk" that is not a CodeStore data contract, such as an EIP-7702-delegated EOA whose EXTCODECOPY returns its mutable 23-byte designator, could change the bytes after `creationCodeHash` was recorded. This needs a careless or hostile operator. Fix: check `code[0] == 0x00` and `code.length > 23` at construction, or take the expected hashes as constructor inputs (this also covers I-05).

### [I-03] The Core Vault creation code travels in the calldata of every `createFund`
- `src/interfaces/IFundFactory.sol:102-107`, `src/factory/FundFactory.sol:154-157`. This puts 34 KB of L1 data on every Arbitrum fund creation, and every manager has to rebuild the operator's exact linked build: any other build reverts `ForeignCreationCode`, which DEPLOYMENT.md does not mention. A CodeStore role, as used for the 32.6 KB Spoke Vault, removes both.

### [I-04] Script defaults and docs (lead 3)
1. `script/FundMandate.sol:124-126` writes no hub Operating Cash entry, so every scripted fund has hub floor and top-up 0 (DEC-096 suggests about 1 and 3 USD on Arbitrum).
2. `script/FactoryDeployment.sol:70` sets the ETH/USD max age to 1 h against the feed's 24 h heartbeat and 0.05% deviation. The feed updated every 1 to 4 minutes on 2026-09-30, but a flat hour closes mints for any fund holding WETH.
3. `.env.example` lists none of the variables the scripts read (`PROTOCOL_RECIPIENT`, `ADAPTER_GUARDIAN`, `REGISTRY_OWNER`, `FUND_FACTORY`, `MANAGER`, `CREATION_NUMBER`, `MANDATE_HASH`, the optional plan values) and lists `DEPLOYER_ADDRESS`, which no script reads.
4. DEPLOYMENT.md's manager flow has no fork rehearsal, and its "check `mandateHash()`" advice does not protect investors (H-01, H-02).

### [I-05] Factory deployment has no guard against a divergent broadcast
- `src/factory/FundFactory.sol:86-131` takes the chunk addresses without expected hashes, and nothing exposes `_codeStores`. If a broadcast's nonces diverge from the simulation (the key used concurrently, a dropped transaction), the factory is created at the operator's single canonical address with the wrong code. That (operator, `FACTORY_SALT`) pair can never be reused on that chain, which breaks the same-address property for every chain. Pass the expected hashes into the constructor and add a `codeStores(role)` view.

### [I-06] Q59 identity is unique only per factory
- `src/factory/FundFactory.sol:274-277,475-477`. `NUMBER_OFFSET` is a free constructor input, so a future factory version on Arbitrum with offset 0 reissues `PP-1` / `Pool Party Fund 1`. The 11-character symbol bound is not enforced; this is fine up to n = 99,999,999.

### [I-07] Dead code in the Mandate library
- `src/mandate/Mandate.sol:146,239-255`. `MandateLib.bridgeAdapterFor` and `NoBridgeAdapter` are used only by tests; the vaults have their own lookups.

### [I-08] No upper bound on `standardPayoutTerm`
- `src/mandate/Mandate.sol:163-182`. Under a multi-year term, a Standard request can neither be claimed nor cancelled (DEC-024), it keeps the holder from opening an Instant request, and its reserve holds Free Idle for the whole term (bounded by FV-OQ-1). The holder opts in, but the value is shown in seconds.

## Checks and validations
| Function | Access control | Input validation | Reentrancy guard | CEI | Event | Gaps |
|---|---|---|---|---|---|---|
| `FundFactory` constructor | deploy-time (operator via `Create3Deployer`) | zero checks on base token, Across pool, Wormhole Core, recipient, guardian, SpokeCrossChainLib; flow fee ≤ 100 bps; libraries have code; store hashes recorded | n/a | n/a | none (`Create3Deployer.Deployed`) | libraries not bound to the code (I-01); registry and price source code not checked; no expected hashes (I-02, I-05); `numberOffset` free (I-06) |
| `FundFactory.createFund` | `msg.sender == m.manager` (permissionless creation, DEC-001) | hub chain; hub configured; `m.usdc` is the base token; next number; Core Vault code hash; every Mandate address predicted; V4 PoolKeys hash to the ids in order; Aave keys are addresses; `validate` runs in the vault constructors | `nonReentrant` (transient) | counter and registry written before the deployments; atomic | `FundCreated(n, fundId, manager, mandateHash, addresses)` | nothing links a send to an existing spoke (H-01); spoke Wormhole id and lifetime unchecked (M-01); list sizes unbounded (L-01) |
| `FundFactory.createSpoke` | `msg.sender == m.manager` | hash equals the parameter (self-consistency only); not the hub chain; this chain is a spoke; spoke token is the base token; addresses predicted; not created twice | `nonReentrant` | no factory state written | `SpokeCreated` | Mandate not tied to the hub's (H-02) |
| `Create3Deployer.deploy` | anyone; salt bound to `msg.sender` | salt reuse refused (`SaltAlreadyUsed`) | none needed (no state) | n/a | `Deployed` | none |
| `CoreVaultBase` constructor | factory-supplied | `validate`; zero checks; `c.usdc == m.usdc`; chain; flow fee cap; pins hub bridge targets and codehashes | n/a | n/a | none | price-source coverage (known); reporting parameters (M-01) |
| `ShareToken` constructor | Core Vault | Core Vault non-zero; name and symbol from the factory | n/a | n/a | none | none |
| `ManagerFeeVault` constructor | Core Vault | fund and manager non-zero | n/a | n/a | none | none |
| `SpokeVault` constructor | factory-supplied | `validate`; chain; fund id; zero addresses; base token; Wormhole; pins adapters, pools (`poolTokens`), unwind steps, spoke bridge targets | n/a | n/a | none | no `address(this) == spokeVault` (known); own copy of the rules (H-02) |
| `UniswapV4Adapter` constructor | factory-supplied | zero addresses; `tickSpacing > 0`; no native pool; no duplicate | n/a | n/a | `PoolRegistered` | accepts unsorted or uninitialized keys (dead entries, harmless) |
| `AaveV3Adapter` constructor | factory-supplied | zero checks; non-empty; no duplicate; reserve listed | n/a | n/a | none | none |
| `AcrossBridgeAdapter` constructor | factory-supplied | vault and pool non-zero; `fillDeadlineBuffer ≥ 21,600` (reverts surface through CREATE3) | n/a | n/a | none | none |
| `ValueReportReceiver` constructor | factory-supplied | zero checks; fund id; band ≤ 100%; spoke fields non-zero; duplicate emitters | n/a | n/a | none | Wormhole id and lifetime unchecked (M-01); no Mandate hash (H-02) |
| `DeployFactory.run` / `CreateFund.run` (scripts) | operator / manager keys | `vm.envAddress` reverts when a required variable is unset or empty; optional values fall back to defaults | n/a | n/a | console logs | I-04 |

## Checked and found correct
- **CREATE3 proxy bytes, decoded by hand.**
  - Init code `75 <22 bytes> 3d 52 6016 600a f3`: MSTORE at 0, then RETURN(10, 22).
  - Runtime `363d3d37363d34f0 601457 3d6000803e3d6000fd 5b00`: CALLDATACOPY, CREATE(callvalue), JUMPI to 0x14 on success, otherwise RETURNDATACOPY and REVERT. It bubbles constructor revert data; `test_DEC066_shortFillDeadlineBufferSurfacesAtCreation` confirms `FillDeadlineBufferTooShort` surfaces.
- **Address formulas.**
  - CREATE2 is `keccak(0xff ++ deployer ++ salt ++ keccak(PROXY_INITCODE))`; the child is RLP `0xd6 0x94 proxy nonce`, and the proxy's first CREATE uses nonce 1 (EIP-161).
  - `createAddress` refuses nonce 0 (RLP 0x80) and nonces above 0x7f.
  - The repository tests match these against `vm.computeCreate2Address` and `computeCreateAddress`.
- **Salt reuse.** Salt reuse is refused before the attempt. A reverting child reverts the proxy creation too, so the salt stays free (`test_DEC058_verify_invalidMandateLeavesNoPartialDeployment`). Used proxies can only CREATE at nonce 2 and above, never at a fund address. There is no value forwarding (no value in the factory, and `deploy` is not payable).
- **Squatting.** Fund addresses come from the factory's CREATE2 only. Both entry points require `m.manager`, and the fund id binds the manager. The factory address is bound to the operator through the salt, and the deterministic deployer's address commits to its code. Nobody but the manager reaches a fund's addresses, and nobody but the operator reaches the factory's, on any chain, including chains where the operator has not deployed yet (there the only exposure is H-01).
- **CodeStore.**
  - The chunk init code `61 SIZE 80 600a 3d 39 3d f3 00 ++ part` is CODECOPY(0, 10, n) followed by RETURN(0, n), with n = size + 1; the runtime is `0x00 ++ part`.
  - `read` skips byte 0. Chunks cannot change after Cancun, because execution stops at byte 0 and no SELFDESTRUCT is reachable (I-02 covers chunks that are not CodeStore contracts).
  - A hash is recorded for every configured role; a role with no code reverts `RoleNotConfigured`.
- **Deployment order against constructor dependencies.**
  - The hub order is adapters, hub Spoke Vault (needs adapter code, `poolTokens` and `target()`), receiver (addresses only), Core Vault (needs the hub Across adapter's `target()`). The spoke order is adapters, then Spoke Vault.
  - Every `abi.encode` in `FundFactory` matches its constructor's parameter order, field by field.
- **Wiring.** The hub Across adapter's vault is the Core Vault (FF-OQ-3). The V4 and Aave adapters' vault is the chain's Spoke Vault, and the spoke's Across adapter's vault is its Spoke Vault. The guardian is factory-wide, and `excessRecipient` is the Protocol Recipient everywhere. The receiver's spoke indices equal the Core Vault's. The Core Vault makes no CREATE before its ShareToken (nonce 1) and ManagerFeeVault (nonce 2), so `predictAddresses` is right.
- **Mandate hash.**
  - `keccak256(abi.encode(m))` of one struct with dynamic arrays is injective and does not depend on the chain; hub and spoke hash identical bytes.
  - Not in the hash: adapter codehashes (pinned in the vaults, OQ-13), library addresses, factory wiring (flow fee, recipient, guardian, registry, price source, Across and Wormhole addresses), share name and symbol, fund id and number.
- **`validate` extremes (lead 2).**
  - Rejected: zero manager, USDC or hub chain id; empty adapters, pools or unwind order; duplicate adapters, pools, unwind steps, spokes (by EVM or Wormhole id) and Operating Cash chains; a bridge adapter that is also a position adapter; entries on chains outside the fund; a spoke on the hub chain; a spoke with no bridge adapter on either side; a zero report lifetime.
  - Accepted and harmless: `spokeCap` 0 (sends revert) or huge (visible); `minFirstDeposit` 0 (the one-share floor applies, and donations cannot move the price) or huge (the fund never starts); `maxBridgeFeeBps` 0 (no relayer fills, the deposit is refunded); performance fee at the 2,500 cap.
  - At creation: hooked or native V4 pools are refused; unsorted or uninitialized keys are accepted but inoperable; Aave assets must be listed reserves.
- **Atomicity, reentrancy and chain separation.** Registry writes come before the deployments, but any revert unwinds them. Constructors call only trusted wiring (Across `fillDeadlineBuffer`, Aave `getReserveData`) or the fund's own new adapters. `createSpoke` cannot consume hub salts (`SpokeOnHubChain` plus the derived fund id; repository tests).
- **Script environment.** `vm.envOr` returns the default for an unset or an empty value, and `vm.envAddress` reverts on an empty value, so no variable silently becomes zero (`test/review/factory/Check_ScriptEnvironment.t.sol`, 3 PASS). The scripts leave no privileged role with the deployer by default: the ManagerRegistry owner is `REGISTRY_OWNER`, and ChainlinkPriceSource, the factory and `Create3Deployer` have no owner.
- **Fork rehearsal against broadcast.** Both run the same code path. Library and `Create3Deployer` addresses are fixed by their code, the factory address by the operator and salt, and chunk addresses by the operator's nonce, so the broadcast matches as long as `--slow` is used and the key is not used concurrently (I-05). The cross-chain comparison of the factory address and the Spoke Vault hash is manual, as the docs say.
- **Slither and Aderyn leads in scope, all dismissed.**
  - Slither #1 (`FundFactory:478` encode-packed-collision) and Aderyn H-1 (`CodeStore:42`, `FundFactory:478,509`): these build CREATE payloads that are never hashed; `creationCodeHash` covers the code alone.
  - Slither #47, #48 and #51 (uninitialized locals): counters, or structs whose fields are all assigned.
  - Slither #73, #74 and #75 (unused returns): the spoke index is not needed, and `Create3.deploy`'s result is checked by `DeploymentWithoutCode`.
- **Chainlink ETH/USD cadence, read on chain.** 21 rounds between 1790781753 and 1790783524, 30 s to 4 min apart (see I-04 for the 1 h bound).

## Not covered
- The three PoCs run on unit fixtures. Only the Across fill to a codeless recipient was run against a live chain (Robinhood fork at block 76649566). An end-to-end fork run of H-01 and H-02 was not done.
- Robinhood's per-transaction gas cap was not read: its block header shows the Orbit placeholder limit. Arbitrum's 32M cap is taken from DEPLOYMENT.md and spoke-b's measurement.
- `createSpoke` gas growth with many spoke pools (only `createFund` was measured).
- The runtime behaviour of `ShareToken` and `ManagerFeeVault` beyond their constructors (other reviewers' scope).
