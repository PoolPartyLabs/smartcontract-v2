// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool as AcrossPoolStandIn} from "../../mocks/across/MockAcrossSpokePool.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-b M01, consolidated finding M-01 (register S-9), restated for DEC-158 and DEC-162. On
///         `e5c778a` the manager named itself Across exclusive relayer for the whole fill window and kept
///         `inputAmount - outputAmount` on every send, and MandateLib accepted `maxBridgeFeeBps` up to 10,000 (one send
///         of 100,000 USDC delivered 1 base unit). S-9 then refused exclusivity and capped the Mandate bound at 1%,
///         which a manager could still give away on every send. Since DEC-162 the Across adapter fixes every term of
///         the deposit: the manager passes no amount to arrive, relayer, exclusivity or quote time (DEC-158), so the
///         most a send gives the relayer that fills it is the adapter's rule fee, whoever triggers or fills it. Mandate
///         v2 removed the Mandate bound itself (DEC-156: no protocol cap in the Mandate; the adapter's 1% `CAP_RATE`
///         bounds the rule).
/// @dev The hub's bridge adapter here is the real AcrossBridgeAdapter over the offline SpokePool stand-in.
contract M01_ManagerCapturesBridgeFee is CoreVaultFixture {
    uint256 internal constant SENT = 40_000e6;
    /// @dev A first send on the route: 0.08% plus 0.03 (DEC-162, doc 12 §6).
    uint256 internal constant RULE_FEE = 32e6 + 30_000;

    AcrossPoolStandIn internal acrossPool;
    AcrossBridgeAdapter internal across;

    /// @dev The fixture's Core Vault, with the real Across adapter as its hub bridge adapter.
    function _deployWithAcross() internal {
        (across, acrossPool) = _deployWithAcross(1_000_000e6);
    }

    /// @dev The exact `depositV3` call the vault's next send makes: every term but the route, recipient, tokens, amount
    ///      and message is the adapter's.
    function _expectedDeposit(uint256 transitNonce, uint256 amountToArrive) internal view returns (bytes memory) {
        bytes32 id = keccak256(abi.encode(block.chainid, address(vault), transitNonce));
        address escrow = vm.computeCreateAddress(address(vault), vm.getNonce(address(vault)));
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                escrow,
                spokeVaultAddress,
                address(usdc),
                address(usdg),
                SENT,
                amountToArrive,
                SPOKE,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                TransitMessage.encode(FUND_ID, HUB, id, TransferKind.Principal)
            )
        );
    }

    /// @dev DEC-158: the manager has no way to pass an amount to arrive, a relayer or an exclusivity period; a quote
    ///      in `bridgeData` is refused by the Across adapter and nothing leaves the fund.
    function test_REVIEW_M01_managerCannotNameARelayerOrAnAmountToArrive() public {
        _deployWithAcross();
        uint256 assets = vault.shareAssets();
        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        vault.sendToSpoke(0, SENT, 0, abi.encode(uint256(1), makeAddr("managerRelayer"), uint32(21_600)));
        assertEq(vault.shareAssets(), assets, "nothing left the fund");
    }

    /// @dev DEC-162: the S-9 residual is gone. A 40,000 send leaves Share Assets by the adapter's 32.03 (against 400
    ///      at the old 1% Mandate bound), with no exclusive relayer and the quote time and deadline the adapter's; a
    ///      second send on the route is priced from the first, not by the manager.
    function test_REVIEW_M01_aSendCostsTheRuleFeeNotTheMandateBound() public {
        _deployWithAcross();
        uint256 assets = vault.shareAssets();

        vm.expectCall(address(acrossPool), _expectedDeposit(1, SENT - RULE_FEE));
        vm.prank(manager);
        vault.sendToSpoke(0, SENT, 0, "");
        console2.log("given to the relayer per 40,000 send", assets - vault.shareAssets());
        assertEq(assets - vault.shareAssets(), RULE_FEE, "0.08% plus 0.03, never the 1% bound");

        vm.expectCall(address(acrossPool), _expectedDeposit(2, SENT - RULE_FEE));
        vm.prank(manager);
        vault.sendToSpoke(0, SENT, 0, "");
    }
}
