// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeUnwindTypes} from "./SpokeUnwindTypes.sol";
import {SpokeLedger} from "./SpokeLedger.sol";
import {SpokeUnwindLib} from "./SpokeUnwindLib.sol";

/// @notice Linked CLOSE preparation and manual-sale accounting (DEC-131/147/149).
library SpokeCloseLib {
    uint256 private constant STANDARD_SALE_LOSS_ABSORB_BPS = SpokeUnwindLib.STANDARD_SALE_LOSS_ABSORB_BPS;
    uint256 private constant BPS = 10_000;

    function manualSwap(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        SpokeUnwindTypes.ManualSale calldata sale
    ) external returns (uint256 amountOut, uint256 spotOut, uint256 minOut) {
        if (!s.isLedgerToken[sale.tokenIn]) revert ISpokeVault.TokenNotInMandate(sale.tokenIn);
        if (!s.isLedgerToken[sale.tokenOut]) revert ISpokeVault.TokenNotInMandate(sale.tokenOut);
        if (sale.amountIn == 0) revert ISpokeVault.ZeroAmount();
        uint256 baseRate = 1e18;
        if (sale.tokenOut != c.baseToken) {
            ISwapAdapter swapAdapter = SpokeLedger.swapAdapter(s, sale.adapter);
            (uint24 fee,) = swapAdapter.bestDirectFee(sale.tokenOut, c.baseToken, 1e18);
            baseRate = swapAdapter.spotValue(sale.tokenOut, c.baseToken, 1e18, fee);
        }
        (amountOut, spotOut, minOut) = SpokeLedger.swapThrough(
            s, sale.adapter, sale.tokenIn, sale.tokenOut, sale.amountIn, sale.maxLossBps, sale.route, false
        );
        uint256 loss = spotOut > amountOut ? spotOut - amountOut : 0;
        uint256 absorbed = Math.mulDiv(spotOut, STANDARD_SALE_LOSS_ABSORB_BPS, BPS);
        uint256 excess = loss > absorbed ? Math.mulDiv(loss - absorbed, baseRate, 1e18) : 0;
        if (c.chainId == c.hubChainId) {
            if (excess != 0 && ICoreVaultLifecycle(c.coreVault).fundState() == ICoreVaultLifecycle.FundState.Closing) {
                s.unwind.closureExcessCost += excess;
            }
        } else if (excess != 0) {
            uint256 count = s.unwind.saleTimes.length;
            uint256 cumulative = excess + (count == 0 ? 0 : s.unwind.saleCosts[count - 1]);
            if (count != 0 && s.unwind.saleTimes[count - 1] == block.timestamp) {
                s.unwind.saleCosts[count - 1] = cumulative;
            } else {
                s.unwind.saleTimes.push(uint64(block.timestamp));
                s.unwind.saleCosts.push(cumulative);
            }
        }
    }

    function _manualClosureCost(SpokeUnwindTypes.Book storage book, uint64 startedAt) private view returns (uint256) {
        uint256 count = book.saleTimes.length;
        if (count == 0) return 0;
        uint256 lower;
        uint256 upper = count;
        while (lower < upper) {
            uint256 middle = (lower + upper) / 2;
            if (book.saleTimes[middle] < startedAt) lower = middle + 1;
            else upper = middle;
        }
        return book.saleCosts[count - 1] - (lower == 0 ? 0 : book.saleCosts[lower - 1]);
    }

    function executeCloseOrder(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        OrderCodec.Order memory order
    ) external {
        if (order.closingStartedAt == 0 || order.closingStartedAt > block.timestamp) {
            revert SpokeUnwindTypes.SpokeClosed();
        }
        if (s.unwind.closureStartedAt == 0) {
            s.unwind.closureStartedAt = order.closingStartedAt;
            s.unwind.closureExcessCost = _manualClosureCost(s.unwind, order.closingStartedAt);
        } else if (s.unwind.closureStartedAt != order.closingStartedAt) {
            revert SpokeUnwindTypes.SpokeClosed();
        }
        order.fracNum = 1;
        order.fracDen = 1;
        order.maxLossBps = 0;
        order.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Standard);
        s.unallocated[c.baseToken] += s.operatingCash;
        s.operatingCash = 0;
        SpokeUnwindLib.executeUnwindOrder(s, c, order);
        s.unwind.closed = true;
    }
}
