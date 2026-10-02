// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {Transit, TransferKind} from "../interfaces/FundTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";

/// @notice Wiring of a Core Vault, fixed at construction.
/// @param fundId Fund identifier shared by every contract of the fund.
/// @param usdc Hub USDC; must equal the Mandate's `usdc` (DEC-011).
/// @param hubSpokeVault The fund's Spoke Vault on the Hub Chain (DEC-054).
/// @param reportReceiver The fund's ValueReportReceiver (DEC-086, DEC-093).
/// @param managerRegistry Per-manager registry holding the protocol slice (DEC-106, DEC-110).
/// @param priceSource Prices non-USDC quantities into hub USDC (docs/ARCHITECTURE.md §5, OPEN).
/// @param acrossSpokePool Across SpokePool on the Hub Chain, the only caller of `handleV3AcrossMessage`.
/// @param protocolRecipient Recipient of the flow fee and the protocol slice: the fee wallet (DEC-106, DEC-116).
/// @param excessRecipient Recipient of swept excess balances: the fee wallet too (DEC-096, DEC-101, DEC-116,
///        DEC-121).
/// @param escrowImplementation TransitEscrow implementation cloned once per send (DEC-066, QA6 OPEN).
/// @param flowFeeBps Protocol flow fee in bps, capped at 100; a fixed value of each factory deploy, immutable per fund
///        (DEC-106, DEC-110, DEC-125 item 1).
/// @param factory The only caller of `seed` (DEC-127). A field, not `msg.sender`: the factory deploys through CREATE3,
///        so the constructor's `msg.sender` is the one-use proxy.
/// @param minPerformanceFeeBps The ManagerRegistry's minimum manager fee when the fund was created; floor of
///        `decreaseManagerFee` (DEC-115, DEC-125 item 3, D-36).
/// @param incomeTokens Hub income tokens besides USDC: the tokens of the Mandate's hub pools, which the factory reads
///        from the hub adapters (`IAdapter.poolTokens`) because a Mandate pool key is a hash and the Core Vault never
///        calls an adapter (DEC-054).
/// @param shareName Share token name (Q59 OPEN: factory-chosen, never manager text).
/// @param shareSymbol Share token symbol (Q59 OPEN).
struct CoreVaultConfig {
    bytes32 fundId;
    address usdc;
    address hubSpokeVault;
    address reportReceiver;
    address managerRegistry;
    address priceSource;
    address acrossSpokePool;
    address protocolRecipient;
    address excessRecipient;
    address escrowImplementation;
    uint16 flowFeeBps;
    address factory;
    uint16 minPerformanceFeeBps;
    address[] incomeTokens;
    string shareName;
    string shareSymbol;
}

/// @notice Immutable addresses the Core Vault hands to its external library on every call.
struct CoreVaultWiring {
    bytes32 fundId;
    bytes32 mandateHash;
    address manager;
    address usdc;
    address shareToken;
    address hubSpokeVault;
    address reportReceiver;
    address managerRegistry;
    address priceSource;
    address escrowImplementation;
    address protocolRecipient;
    address managerFeeVault;
    uint256 hubChainId;
    uint16 maxBridgeFeeBps;
}

/// @notice Per-spoke transit book.
/// @param inFlightSent USDC sent to the spoke whose outcome is unknown (state Sent); counts toward the Spoke Cap
///        (DEC-066 C1).
/// @param inFlightToArrive Spoke token units that will arrive for transits in state Sent or ExpiryAttested; counts in
///        Share Assets (DEC-085; QB11 OPEN: kept until the refund is recognized).
/// @param confirmedArrived Spoke token units of transits the hub confirmed arrived; the spoke's `cumulativeReceived`
///        above this is an arrival the hub never sent and is deducted (DEC-080).
struct SpokeBook {
    uint256 inFlightSent;
    uint256 inFlightToArrive;
    uint256 confirmedArrived;
}

/// @notice A spoke-to-hub transfer, keyed by `keccak256(originChainId, transitId)`.
/// @param listed Amount an accepted report listed in `inFlightToHub` (0 until listed); the first listing is kept.
/// @param credited Amount credited to Idle or collected income against `listed`.
/// @param pending Arrived before any report listed it; held apart (DEC-080, OQ-01).
/// @param kind Kind the report listed (CV-OQ-1): an arrival is credited by it, never by the Across message's claim.
/// @param pendingSince When the last arrival held apart without a listing, at least as large as what was already held,
///        reached the hub; `recoverUnlistedArrival` needs a spoke report built after it (security review S-4, S-45,
///        S-64).
struct HubBoundTransfer {
    uint256 listed;
    uint256 credited;
    uint256 pending;
    TransferKind kind;
    uint64 pendingSince;
}

/// @notice All mutable state of a Core Vault, in one struct so the external library can work on it by reference.
/// @param mandate The Mandate, copied element by element at construction and never written again (DEC-053).
/// @param idle ICoreVault.idle (DEC-055, DEC-072).
/// @param payoutReserve ICoreVault.payoutReserve (DEC-072).
/// @param operatingCash ICoreVault.operatingCash (DEC-096).
/// @param operatingCashFloor Live floor (DEC-096).
/// @param operatingCashTopUp Live top-up (DEC-096).
/// @param performanceFeeBps Live performance fee; only decreases (DEC-110).
/// @param managementFeeBps Live management fee; always 0 in the MVP (DEC-108).
/// @param unmatchedArrivals Spoke-to-hub arrivals held apart: pending plus strays; outside every base, never swept
///        (DEC-080, DEC-104, OQ-01).
/// @param transitNonce Counter behind transit ids.
/// @param income Attributed Income accumulator (Q60).
/// @param collectedIncome Collected income per token, net of fees, payable now to holders (LC-100; ruling 2026-09-29:
///        fees leave at collection, so nothing owed to the manager or the protocol waits here).
/// @param requests Payout Request per address (DEC-024, DEC-046).
/// @param transits Hub-to-spoke transits (DEC-066).
/// @param transitSpoke Mandate spoke index of each transit.
/// @param spokeBooks Transit book per spoke.
/// @param hubBound Spoke-to-hub transfers by key.
/// @param bridgeTarget Protocol target pinned per hub-side bridge adapter at creation (IBridgeAdapter).
/// @param bridgeCodehash Codehash pinned per hub-side bridge adapter at creation (Q17-4 reading O2).
/// @param lastHubValue Last known USDC value of the hub Spoke Vault (Unallocated Balance plus principal), refreshed on
///        every successful deposit or payout and moved by the exact USDC legs between Idle and the hub Spoke Vault
///        (allocation adds, `returnToIdle` subtracts); a payout falls back to it when the hub report read fails (payout
///        liveness, DEC-021, DEC-056).
/// @param lastPrice Last known price1e18 per token (IPriceSource scale), refreshed likewise; a payout falls back to it
///        when the price source reverts.
/// @param owedFees Fees whose transfer to their recipient failed when charged, per token and recipient; outside every
///        value base, never swept, paid by `claimOwedFees` (security review S-12).
/// @param owedFeesTotal Sum of `owedFees` per token (part of the ledger, DEC-080).
/// @param spokeCapHeld An ExpiryAttested transit whose expiry was proven by time alone keeps its Spoke Cap until its
///        arrival is confirmed or its refund recognized (security review S-13).
/// @param managerPeakShares ICoreVaultLifecycle.managerPeakShares (DEC-146); non-zero once the fund is seeded.
/// @param fundState ICoreVaultLifecycle.fundState (DEC-147).
/// @param closingStartedAt ICoreVaultLifecycle.closingStartedAt (DEC-147, DEC-149).
struct CoreVaultState {
    Mandate mandate;
    uint256 idle;
    uint256 payoutReserve;
    uint256 operatingCash;
    uint256 operatingCashFloor;
    uint256 operatingCashTopUp;
    uint16 performanceFeeBps;
    uint16 managementFeeBps;
    uint256 unmatchedArrivals;
    uint256 transitNonce;
    IncomeAccumulator.State income;
    mapping(address token => uint256) collectedIncome;
    mapping(address shareholder => ICoreVault.PayoutRequest) requests;
    mapping(bytes32 transitId => Transit) transits;
    mapping(bytes32 transitId => uint256) transitSpoke;
    mapping(uint256 spokeIndex => SpokeBook) spokeBooks;
    mapping(bytes32 key => HubBoundTransfer) hubBound;
    mapping(address bridgeAdapter => address) bridgeTarget;
    mapping(address bridgeAdapter => bytes32) bridgeCodehash;
    uint256 lastHubValue;
    mapping(address token => uint256) lastPrice;
    mapping(address token => mapping(address recipient => uint256)) owedFees;
    mapping(address token => uint256) owedFeesTotal;
    mapping(bytes32 transitId => bool) spokeCapHeld;
    uint256 managerPeakShares;
    ICoreVaultLifecycle.FundState fundState;
    uint64 closingStartedAt;
}
