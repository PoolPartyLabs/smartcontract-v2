// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {IntegrationPriceBase} from "./IntegrationPriceBase.sol";

/// @notice Part 3 of the integration-price review: what the factory and the scripts actually wire, next to what the
///         module reviewers assumed with hand-wired fixtures.
/// @notice Ported to fix/pp-sc-fix-independent-review: MEASUREMENT, every fact unchanged. Hub Operating Cash 0/0 (I-09
///         scripts), one immutable guardian for every adapter of every fund of a factory (H-07 recommendation D-2,
///         adapters L-05: not rotatable, no delay; the harm itself is gone with S-10), WETH priced on the Arbitrum
///         ETH / USD feed for both chains with a 1 h bound on mints (I-09), USDG at 1:1 (S-35), receiver variation band
///         0 (S-29), `MAX_UNWIND_SLIPPAGE_BPS` 500 (S-2, OPEN).
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/IntegrationFactsFork.t.sol' -vv
contract IntegrationFactsFork is IntegrationPriceBase {
    function test_REVIEW_I09_measure_factoryWiringFacts() public {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0), false);

        // Hub Operating Cash: the scripts' Mandate lists the spoke only, so the hub floor and top-up are 0.
        console2.log("hub Operating Cash floor / top-up", core.operatingCashFloor(), core.operatingCashTopUp());
        assertEq(core.operatingCashFloor(), 0);
        assertEq(core.operatingCashTopUp(), 0);

        // One guardian for every adapter of every fund of this factory.
        assertEq(IAdapterGuard(hubUniswap).guardian(), guardian);
        assertEq(IAdapterGuard(hubAave).guardian(), guardian);
        address otherManager = makeAddr("otherManager");
        manager = otherManager;
        uint256 n = hubDeployment.factory.nextCreationNumber();
        Mandate memory m = _buildMandate(
            hubDeployment.factory, hubDeployment.factory.fundIdOf(ARBITRUM, n, otherManager), _pricePlan(SPOKE_CAP)
        );
        IFundFactory.HubParams memory p = _hubParams(n, _pricePlan(SPOKE_CAP), _coreVaultCreationCode(hubDeployment));
        _fundManagerSeed(ARB_USDC, otherManager, address(hubDeployment.factory), p.seedAmount);
        vm.prank(otherManager);
        IFundFactory.FundAddresses memory a = hubDeployment.factory.createFund(m, p);
        assertTrue(a.chains[0].uniswapV4Adapter != hubUniswap, "a second fund, its own adapter");
        assertEq(IAdapterGuard(a.chains[0].uniswapV4Adapter).guardian(), guardian, "same guardian key");

        // Price source: one per factory, Chainlink ETH / USD for WETH on both chains, 1 h bound on mints.
        IPriceSource ps = IPriceSource(hubDeployment.priceSource);
        (,,, uint256 updatedAt,) = IChainlinkAggregatorV3(ARB_ETH_USD_FEED).latestRoundData();
        console2.log("maxPriceAge(WETH) s", ps.maxPriceAge(ARB_WETH));
        console2.log("ETH / USD answer age at the fork block s", block.timestamp - updatedAt);
        assertEq(
            ChainlinkPriceSource(address(ps)).aggregatorOf(RH_WETH), ARB_ETH_USD_FEED, "spoke WETH on the hub feed"
        );
        assertTrue(ChainlinkPriceSource(address(ps)).isFixed(RH_USDG), "USDG at 1:1");

        // Receiver: the variation band slot is 0 (Q57 (d) not enforced); sweeps go to the Protocol Recipient.
        assertEq(receiver.variationBandBps(), 0);
        assertEq(core.excessRecipient(), recipient);
        assertEq(hubSpoke.excessRecipient(), recipient);

        // The unwind's only price guard.
        console2.log("MAX_UNWIND_SLIPPAGE_BPS", SpokeVault(address(hubSpoke)).MAX_UNWIND_SLIPPAGE_BPS());
        assertEq(SpokeVault(address(hubSpoke)).MAX_UNWIND_SLIPPAGE_BPS(), 500, "the S-2 floor this port measured");
        assertEq(ps.maxPriceAge(ARB_WETH), 1 hours, "I-09: the scripts' 1 h bound against a 24 h heartbeat");
    }
}
