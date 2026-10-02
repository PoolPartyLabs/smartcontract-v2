// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";

contract ProportionalUnwindForkTest is EndToEndScenario {
    function test_DEC148_forkStrictMaximumExcludesV4ButAaveDeliversAndRetrySkipsAave() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        ISpokeVaultUnwind.UnwindRequest memory request = ISpokeVaultUnwind.UnwindRequest({
            requestId: keccak256("strict-maximum retry"),
            fracNum: 1,
            fracDen: 10,
            maxLossBps: 1,
            mode: ICoreVaultPayouts.PayoutMode.Instant
        });
        uint256 v4Before = IAdapter(hubUniswap).positionValue(hubUniswapPosition).liquidity;
        vm.prank(address(core));
        ISpokeVaultUnwind.UnwindResult memory first = hubSpoke.unwindForPayout(request);
        assertGt(first.excluded, 0, "real V3 fee and impact exceed the one-basis-point maximum");
        assertTrue(hubSpoke.unwindDelivered(request.requestId, hubAave, hubAavePosition));
        assertFalse(hubSpoke.unwindDelivered(request.requestId, hubUniswap, hubUniswapPosition));
        assertEq(IAdapter(hubUniswap).positionValue(hubUniswapPosition).liquidity, v4Before);
        uint256 aaveAfterFirst = IAdapter(hubAave).positionValue(hubAavePosition).principal0;
        request.maxLossBps = 100;
        vm.prank(address(core));
        ISpokeVaultUnwind.UnwindResult memory retry = hubSpoke.unwindForPayout(request);
        assertEq(retry.excluded, 0);
        assertGt(retry.proceeds, 0);
        assertTrue(hubSpoke.unwindDelivered(request.requestId, hubUniswap, hubUniswapPosition));
        assertEq(IAdapter(hubAave).positionValue(hubAavePosition).principal0, aaveAfterFirst);
        assertEq(
            IAdapter(hubUniswap).positionValue(hubUniswapPosition).liquidity, v4Before - Math.ceilDiv(v4Before, 10)
        );
    }

    function test_DEC137_forkSixteenPositionsUseTheSameFractionBelowTheGasCap() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        vm.prank(manager);
        core.allocateToHubSpokeVault(1000e6);
        for (uint256 index; index < 14; ++index) {
            uint256 half = 10e6;
            uint256 weth = _swapHubUsdcForWeth(half);
            bytes memory params = _openParams(_center(ARB_V4_STATE_VIEW, ARB_WETH_USDC_POOL_ID), weth, half);
            vm.prank(manager);
            hubSpoke.openPosition(hubUniswap, ARB_WETH_USDC_POOL_ID, weth, half, params);
        }
        IAdapter.PositionValue[] memory beforePositions = _positionValues();
        assertEq(beforePositions.length, 16);
        uint256 idleBefore = core.idle();
        ISpokeVaultUnwind.UnwindRequest memory request = ISpokeVaultUnwind.UnwindRequest({
            requestId: keccak256("sixteen-position unwind"),
            fracNum: 1,
            fracDen: 10,
            maxLossBps: 100,
            mode: ICoreVaultPayouts.PayoutMode.Standard
        });
        vm.prank(address(core));
        uint256 gasBefore = gasleft();
        ISpokeVaultUnwind.UnwindResult memory result = hubSpoke.unwindForPayout(request);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Hub unwind at sixteen positions, gas", gasUsed);
        assertLt(gasUsed, 32_000_000);
        assertEq(result.excluded, 0);
        assertGe(result.delivered, 16);
        assertGt(result.spotOut, 0, "WETH principal sold through the real V3 adapter");
        assertEq(core.idle() - idleBefore, result.proceeds);
        assertEq(IERC20(ARB_WETH).allowance(address(hubSpoke), hubSwapAdapter), 0);
        IAdapter.PositionValue[] memory afterPositions = _positionValues();
        for (uint256 index; index < beforePositions.length; ++index) {
            if (beforePositions[index].token1 != address(0)) {
                uint256 removed = Math.mulDiv(beforePositions[index].liquidity, 1, 10, Math.Rounding.Ceil);
                assertEq(afterPositions[index].liquidity, beforePositions[index].liquidity - removed);
            } else {
                assertApproxEqAbs(
                    afterPositions[index].principal0,
                    beforePositions[index].principal0 - Math.mulDiv(beforePositions[index].principal0, 1, 10),
                    2
                );
            }
        }
        vm.prank(address(core));
        ISpokeVaultUnwind.UnwindResult memory retry = hubSpoke.unwindForPayout(request);
        assertEq(retry.delivered, 0, "DEC-151: successful positions never deliver twice");
        assertEq(retry.proceeds, 0);
    }

    function _positionValues() private view returns (IAdapter.PositionValue[] memory values) {
        SpokeVault.PositionRef[] memory positions = hubSpoke.positions();
        values = new IAdapter.PositionValue[](positions.length);
        for (uint256 index; index < positions.length; ++index) {
            values[index] = IAdapter(positions[index].adapter).positionValue(positions[index].positionKey);
        }
    }
}
