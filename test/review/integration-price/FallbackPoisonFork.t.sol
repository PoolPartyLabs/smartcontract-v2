// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IntegrationPriceBase, PoolActor} from "./IntegrationPriceBase.sol";

/// @notice Part 3 of the integration-price review: the payout fallback (`lastHubValue`, DEC-021 / DEC-056 payout
///         liveness) inherits a valuation read at a pushed pool price. Every successful deposit or payout stores the hub
///         value it computed, at the spot composition, as the value a later payout uses when the hub read fails.
/// @dev The hub read failure itself is mocked (`vm.mockCallRevert` on `buildReport`): report 02 found no way for a
///      stranger to cause it at normal position counts (its L-05 gas case is manager-driven). What this test shows is
///      what the fallback then pays.
/// @notice Ported to fix/pp-sc-fix-independent-review (review C-02 fallback route, report 08 L-01; security sweep S-1):
///         the stored value is the oracle-composition read, so a deposit at a pushed price stores the fair value and a
///         fallback claim burns the fair shares. e5c778a: `lastHubValue` 224,532.12 against a live 199,133.58
///         (+25,398.54); Bruno kept 3,132 shares.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/FallbackPoisonFork.t.sol' -vv
contract FallbackPoisonFork is IntegrationPriceBase {
    function test_REVIEW_C02_lastHubValueIgnoresADepositAtAPushedPrice() public {
        _poison(true);
    }

    /// @dev Re-attack: the same 2 USDC deposit with the pool pushed above the range instead.
    function test_REVIEW_C02_lastHubValueIgnoresADepositAtAPricePushedUp() public {
        _poison(false);
    }

    function _poison(bool down) internal {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0));
        _deposit(alice, 250_000e6);
        _deposit(bruno, 50_000e6);
        _allocate(core.freeIdle() - 100_000e6);
        _openAround(hubKey, 500_000, 500_000, 100_000e6);
        _parkRestInAave();

        // A stranger deposits 2 USDC while the pool sits out of the fund's +-50% range, inside one unlock.
        PoolActor stranger = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(stranger), 5000e6);
        deal(ARB_WETH, address(stranger), 2e18);
        uint160 edge = down
            ? TickMath.getSqrtPriceAtTick(lastLower - hubKey.tickSpacing)
            : TickMath.getSqrtPriceAtTick(lastUpper + hubKey.tickSpacing);
        stranger.around(hubKey, down, edge, address(stranger), abi.encodeCall(PoolActor.deposit, (core, ARB_USDC, 2e6)));
        assertEq(IERC20(shareToken).balanceOf(address(stranger)), 1e18, "one share bought at the pushed price");

        // Baseline: Bruno's Idle-paid claim with the hub read working.
        uint256 snap = vm.snapshotState();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory fair = core.requestPayout(40_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.revertToState(snap);

        // The same claim when the hub read fails: it is priced with the value the stranger's deposit recorded.
        vm.mockCallRevert(address(hubSpoke), abi.encodeWithSelector(ISpokeVault.buildReport.selector), "");
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory fb = core.requestPayout(40_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.clearMockedCalls();
        uint256 lastHub;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICoreVault.HubValuationFallback.selector) {
                lastHub = abi.decode(logs[i].data, (uint256));
            }
        }
        uint256 hubNow = core.shareAssets() - core.idle();
        console2.log("===== payout fallback after a 2 USDC deposit at a pushed price (V4 +-50% worth 100,000)");
        console2.log("lastHubValue used by the fallback", lastHub);
        console2.log("hub value read now (pool restored)", hubNow);
        console2.log("Bruno's 40,000 claim: shares burned with the read / with the fallback");
        console2.log(fair.sharesBurned / 1e18, fb.sharesBurned / 1e18);
        assertGt(lastHub, 0, "the fallback ran");
        assertEq(lastHub, hubNow, "the stored value is the fair read, the push left nothing in it");
        assertEq(fb.sharesBurned, fair.sharesBurned, "a fallback claim burns the fair shares");
    }
}
