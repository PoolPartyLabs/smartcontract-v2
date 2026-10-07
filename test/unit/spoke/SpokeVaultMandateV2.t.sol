// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockSpokeToken} from "../../mocks/spoke/MockSpokeToken.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";

/// @notice WP-07 B4: the Spoke Vault pins the Mandate v2 entries of its chain: the swap adapters with their codehash
///         (DEC-136, Q17-4) and the Mandate tokens as the ledger's closed list, base token first; every pool token must
///         be a Mandate token of the chain (WP-07 B1).
contract SpokeVaultMandateV2Test is SpokeVaultTestBase {
    using MandateFixture for Mandate;

    function setUp() public {
        _setUpMocks();
    }

    function test_DEC136_hubPinsItsSwapAdapterAndItsMandateTokens() public {
        _deployHub();
        address[] memory swaps = vault.swapAdapters();
        assertEq(swaps.length, 1, "the hub's swap adapter only");
        assertEq(swaps[0], address(hubSwap));
        assertEq(vault.adapterCodehash(address(hubSwap)), address(hubSwap).codehash, "Q17-4: codehash pinned");
        assertEq(vault.adapterCodehash(address(spokeSwap)), bytes32(0), "another chain's adapter is not pinned");

        address[] memory tokens = vault.ledgerTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc), "base token first");
        assertEq(tokens[1], address(weth));
        assertTrue(vault.isMandateToken(address(usdc)));
        assertTrue(vault.isMandateToken(address(weth)));
        assertFalse(vault.isMandateToken(address(usdg)), "a spoke's token is not a hub Mandate token");
    }

    function test_DEC136_spokePinsItsSwapAdapterAndItsMandateTokens() public {
        _deploySpoke();
        address[] memory swaps = vault.swapAdapters();
        assertEq(swaps.length, 1);
        assertEq(swaps[0], address(spokeSwap));
        assertEq(vault.adapterCodehash(address(spokeSwap)), address(spokeSwap).codehash);
        address[] memory tokens = vault.ledgerTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdg), "base token first");
        assertEq(tokens[1], address(weth));
        assertFalse(vault.isMandateToken(address(usdc)));
    }

    /// @dev A Mandate token no pool holds is still a ledger token: the vault can hold it (a swap output) and the
    ///      report lists it.
    function test_DEC136_mandateTokenOutsideEveryPoolIsALedgerToken() public {
        MockSpokeToken stock = new MockSpokeToken("Stock", "STK", 18);
        Mandate memory m = _mandate();
        m.addToken(SPOKE, address(stock));
        vault = _spokeVault(m);
        assertTrue(vault.isMandateToken(address(stock)));
        address[] memory tokens = vault.ledgerTokens();
        assertEq(tokens.length, 3);
        assertEq(tokens[2], address(stock));
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.unallocated.length, 3, "every Mandate token of the chain travels in the report");
        assertEq(r.unallocated[2].token, address(stock));
    }

    /// @dev WP-07 B1: the pool's tokens come from the adapter, so the Spoke Vault is where a pool token outside the
    ///      Mandate token list is refused.
    function test_DEC136_poolTokenOutsideTheMandateTokensReverts() public {
        MockSpokeToken stock = new MockSpokeToken("Stock", "STK", 18);
        spokeUni.addPool(SPOKE_POOL, address(stock), address(usdg));
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeVaultTypes.PoolTokenNotInMandate.selector, address(spokeUni), SPOKE_POOL, address(stock)
            )
        );
        _spokeVault(_mandate());
    }

    /// @dev Q17-4: like every Mandate adapter of the chain, a swap adapter must hold code to be pinned.
    function test_DEC136_swapAdapterWithoutCodeReverts() public {
        Mandate memory m = _mandate();
        address codeless = makeAddr("codelessSwapAdapter");
        m.swapAdapters[1].adapter = codeless;
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.AdapterHasNoCode.selector, codeless));
        _spokeVault(m);
    }

    function _spokeVault(Mandate memory m) internal returns (SpokeVault v) {
        vm.chainId(SPOKE);
        v = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(wormhole),
            address(escrowImplementation),
            excessRecipient
        );
    }
}
