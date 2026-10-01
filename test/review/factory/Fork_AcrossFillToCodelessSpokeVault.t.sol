// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

/// @dev Live SpokePool fill entry point, as declared in test/fork/across/AcrossFill.fork.t.sol (selector 0xdeff4b24).
interface ILiveSpokePoolFill {
    struct V3RelayDataBytes32 {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    function fillRelay(V3RelayDataBytes32 calldata relayData, uint256 repaymentChainId, bytes32 repaymentAddress)
        external;
}

/// @notice Supports [H-01] (factory review): what the live Robinhood SpokePool does with a hub-to-spoke send whose
///         recipient (the Mandate's predicted Spoke Vault) has no code yet because `createSpoke` has not run. The fill
///         succeeds, the output tokens are transferred to the empty address and the `handleV3AcrossMessage` callback is
///         skipped although the message is not empty, so no Spoke Vault ledger ever credits the arrival.
/// @dev Run with `ROBINHOOD_RPC_URL` and `ROBINHOOD_FORK_BLOCK` set (about 100 blocks below the head).
/// @dev Re-run on main (consolidated H-05, register S-14) at Robinhood block 76,966,477: the live pool behaviour is
///      unchanged, so the loss path still exists outside the fund; what closes it is S-14, which keeps the hub from
///      sending to a Spoke Vault before it accepted a report from it (H01_SendToASpokeThatDoesNotExist.t.sol).
contract Fork_AcrossFillToCodelessSpokeVault is Test {
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function test_REVIEW_H05_fork_liveFillToAnAddressWithoutCodeCreditsTokensAndSkipsTheCallback() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        // The Mandate's predicted Spoke Vault before `createSpoke`: an address with no code.
        address predictedSpokeVault = makeAddr("predictedSpokeVaultNotCreatedYet");
        assertEq(predictedSpokeVault.code.length, 0);
        address relayer = makeAddr("relayer");
        uint256 outputAmount = 49_970e6;
        bytes memory message =
            TransitMessage.encode(keccak256("fund"), ARBITRUM_CHAIN_ID, bytes32(uint256(1)), TransferKind.Principal);

        deal(RH_USDG, relayer, outputAmount);
        vm.startPrank(relayer);
        IERC20(RH_USDG).approve(RH_SPOKE_POOL, outputAmount);
        ILiveSpokePoolFill(RH_SPOKE_POOL)
            .fillRelay(
                ILiveSpokePoolFill.V3RelayDataBytes32({
                depositor: _word(makeAddr("transitEscrowClone")),
                recipient: _word(predictedSpokeVault),
                exclusiveRelayer: bytes32(0),
                inputToken: _word(makeAddr("arbitrumUsdc")),
                outputToken: _word(RH_USDG),
                inputAmount: 50_000e6,
                outputAmount: outputAmount,
                originChainId: ARBITRUM_CHAIN_ID,
                depositId: 987_654_321,
                fillDeadline: uint32(block.timestamp) + 21_600,
                exclusivityDeadline: 0,
                message: message
            }),
                block.chainid,
                _word(relayer)
            );
        vm.stopPrank();

        // The relay is filled (the relayer is repaid the input on the origin chain by Across) and the USDG sits at the
        // empty address: nothing called `handleV3AcrossMessage`, so no ledger credited it.
        assertEq(IERC20(RH_USDG).balanceOf(predictedSpokeVault), outputAmount, "delivered to the empty address");
        assertEq(IERC20(RH_USDG).balanceOf(relayer), 0, "the relayer paid the fill");
        assertEq(predictedSpokeVault.code.length, 0, "still no code");
    }
}
