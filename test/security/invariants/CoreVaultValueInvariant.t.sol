// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
import {FundSystemFixture} from "./FundSystemFixture.sol";
import {FundSystemHandler} from "./FundSystemHandler.sol";

/// @title Value-base invariants of the Core Vault inside a whole fund
/// @notice The real Core Vault next to the real Spoke Vaults and receiver (FundSystemFixture), driven by
///         FundSystemHandler with shareholders, the manager and a stranger. The handler also asserts, inside every
///         action, that a donation, a fabricated arrival or a sweep never moves the Share Price (DEC-080).
contract CoreVaultValueInvariantTest is FundSystemFixture {
    FundSystemHandler internal handler;

    function setUp() public {
        _deploySystem();
        // The two liveness assumptions of FundSystemHandler hold unless an exploratory run drops them:
        // SEC_UNLISTED_SENDS_HOME=true and SEC_LATE_REFUNDS=true reproduce the counterexamples of the report.
        handler = new FundSystemHandler(
            sys, !vm.envOr("SEC_UNLISTED_SENDS_HOME", false), !vm.envOr("SEC_LATE_REFUNDS", false)
        );
        targetContract(address(handler));
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = FundSystemHandler.settle.selector;
        excluded[1] = FundSystemHandler.deliverFreshReport.selector;
        excludeSelector(StdInvariant.FuzzSelector(address(handler), excluded));
    }

    /// DEC-104 (with DEC-083, DEC-085, DEC-080): Share Assets equal the sum of their buckets, rebuilt here from the
    /// vaults' own ledgers, the state of every transit and the latest accepted report: Idle, the hub Spoke Vault's
    /// Unallocated Balance and principal, every hub-to-spoke transit still Sent or ExpiryAttested at the amount that
    /// will arrive, the pending Principal return leg, and the spoke's reported principal less the value of unknown
    /// origin. DEC-072: the Payout Reserve never exceeds Idle. DEC-091: the supply is whole shares.
    function invariant_DEC104_shareAssetsEqualTheSumOfTheirBuckets() public view {
        uint256 inFlight = handler.hubSendsIn(TransitState.Sent, true)
            + handler.hubSendsIn(TransitState.ExpiryAttested, true) + handler.pendingPrincipalReturnLeg();
        assertEq(sys.core.inFlightValue(), inFlight, "DEC-085: In-flight Value");

        uint256 total = sys.core.idle() + handler.hubVaultPrincipal() + inFlight;
        uint256 unknown;
        if (sys.receiver.hasReport(0)) {
            (ReportCodec.Report memory r,,) = sys.receiver.latestReport(0);
            for (uint256 i; i < r.unallocated.length; ++i) {
                if (r.unallocated[i].token == address(sys.usdg)) total += r.unallocated[i].amount;
                else assertEq(r.unallocated[i].amount, 0, "principal is only ever USDG in this model");
            }
            for (uint256 i; i < r.positions.length; ++i) {
                total += r.positions[i].principal1;
            }
            uint256 confirmed = handler.hubSendsIn(TransitState.ArrivalConfirmed, true);
            if (r.cumulativeReceived > confirmed) unknown = r.cumulativeReceived - confirmed;
        }
        assertEq(sys.core.shareAssets(), total > unknown ? total - unknown : 0, "DEC-104: sum of the buckets");

        assertLe(sys.core.payoutReserve(), sys.core.idle(), "DEC-072: Payout Reserve within Idle");
        assertEq(sys.core.freeIdle(), sys.core.idle() - sys.core.payoutReserve(), "DEC-072: Free Idle");
        assertEq(sys.shares.totalSupply() % 1e18, 0, "DEC-091: whole shares");
        uint256 held;
        uint256 reserved;
        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; ++i) {
            assertEq(sys.shares.balanceOf(actors[i]) % 1e18, 0, "DEC-091: whole balances");
            held += sys.shares.balanceOf(actors[i]);
            ICoreVault.PayoutRequest memory req = sys.core.payoutRequest(actors[i]);
            if (req.open) reserved += req.reserved;
            else assertEq(req.reserved, 0, "DEC-072: a closed request keeps a reserve");
            assertLe(req.usdcOutstanding, req.usdcRequested, "DEC-068: outstanding above requested");
        }
        assertEq(held, sys.shares.totalSupply(), "DEC-004: shares only ever sit with who deposited");
        assertEq(reserved, sys.core.payoutReserve(), "DEC-072: the Payout Reserve is the sum of the open reserves");
    }

    /// DEC-080: the Core Vault's ledger is always backed by its balances. DEC-107, DEC-109, Q60: every collected unit
    /// is a fee that left at collection or sits in the accumulator; holders are never owed, and never took, more than
    /// what was distributed; the fee never exceeds the Mandate's performance fee.
    function invariant_DEC107_feesPlusHolderIncomeNeverExceedCollectedIncome() public view {
        address[2] memory tokens = [address(sys.usdc), address(sys.weth)];
        address[] memory actors = handler.actors();
        for (uint256 t; t < 2; ++t) {
            address token = tokens[t];
            assertGe(
                IERC20Like(token).balanceOf(address(sys.core)),
                handler.ledgerOf(address(sys.core), token),
                "DEC-080: ledger above balance"
            );
            IncomeAccumulator.TokenIncome memory income = sys.core.incomeState(token);
            uint256 gross = handler.incomeGross(token);
            uint256 fees = handler.incomeFees(token);
            assertEq(fees + income.distributed + income.ownerless, gross, "every collected unit is fee or accumulated");
            assertLe(fees * 10_000, gross * PERFORMANCE_FEE_BPS, "DEC-107: fee above the Mandate's performance fee");
            assertLe(income.taken, income.distributed, "Q60: taken above distributed");
            assertEq(
                sys.core.collectedIncome(token),
                income.distributed + income.ownerless - income.taken,
                "LC-100: the collected balance is what the accumulator still holds"
            );
            uint256 owed;
            for (uint256 i; i < actors.length; ++i) {
                owed += sys.core.attributedIncome(actors[i], token);
            }
            assertLe(owed + income.taken, income.distributed, "DEC-014: owed plus taken above distributed");
            assertLe(fees + owed + income.taken, gross, "fees plus holder income above collected income");
        }
    }

    /// No shareholder ends with more USDC value than they put in (income is paid apart, in its own tokens): what they
    /// were paid plus what their shares are worth never exceeds what they paid, beyond rounding (under two base units
    /// per deposit, payout or refund executed by anyone), the bridge fees that recognized refunds gave back, the
    /// Payout Fees leavers left in Idle (DEC-144) and value strangers gave the fund. Checked at the Share Price as it stands and again with the fund at rest.
    function invariant_DEC104_noActorEndsWithMoreThanTheyPutIn() public {
        _assertNoActorProfits("live");
        handler.settle();
        _assertNoActorProfits("at rest");
    }

    function _assertNoActorProfits(string memory when) internal view {
        uint256 price = sys.core.sharePrice();
        uint256 slack =
            2 * handler.valueOps() + handler.refundedBridgeFees() + handler.payoutFees() + handler.strangerGifts();
        address[] memory actors = handler.actors();
        uint256 worth;
        for (uint256 i; i < actors.length; ++i) {
            uint256 value = ShareMath.usdcFor(sys.shares.balanceOf(actors[i]), price);
            worth += value;
            assertLe(handler.paidOut(actors[i]) + value, handler.paidIn(actors[i]) + slack, when);
        }
        assertLe(worth, sys.core.shareAssets(), "DEC-084: the supply is worth more than Share Assets");
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
