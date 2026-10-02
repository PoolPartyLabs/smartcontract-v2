// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice WP-07 B2 and B3: the Core Vault reads the Mandate v2 token list at creation. Every Mandate token of every
///         chain must have a price (DEC-123 level 1: an asset without a reliable source is not admitted), and the hub
///         income tokens are USDC then the Mandate's other hub tokens.
contract CoreVaultMandateV2Test is CoreVaultFixture {
    using MandateFixture for Mandate;

    /// @dev The fixture lists USDC and WETH on the hub, USDG and Robinhood WETH on the spoke.
    function test_DEC136_incomeTokensAreTheMandateHubTokens() public view {
        address[] memory tokens = vault.incomeTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc), "USDC first");
        assertEq(tokens[1], address(weth));
        assertEq(vault.mandate().tokens.length, 4, "the Mandate copy keeps every chain's tokens");
    }

    /// @dev DEC-123 level 1: a spoke token the price source cannot price is refused when the fund is created, before it
    ///      could close every mint (independent review M-03, spoke half).
    function test_DEC123_unpricedSpokeTokenIsRefusedAtCreation() public {
        CoreMockToken stock = new CoreMockToken("Robinhood stock", "STK", 18);
        Mandate memory m = _mandate(2000);
        m.addToken(SPOKE, address(stock));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.TokenNotPriced.selector, SPOKE, address(stock)));
        this.deployWith(m);
    }

    function test_DEC123_unpricedHubTokenIsRefusedAtCreation() public {
        prices.setReverts(address(weth), true);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.TokenNotPriced.selector, HUB, address(weth)));
        this.deployWith(_mandate(2000));
    }

    /// @dev A zero price is no price: such a token would be valued at 0 in every base.
    function test_DEC123_zeroPriceIsRefusedAtCreation() public {
        prices.setPrice(address(usdg), 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.TokenNotPriced.selector, SPOKE, address(usdg)));
        this.deployWith(_mandate(2000));
    }

    /// @dev Hub USDC is the unit: never read from the price source (the fixture's source has no USDC entry).
    function test_DEC123_hubUsdcIsNeverPriced() public {
        prices.setReverts(address(usdc), true);
        this.deployWith(_mandate(2000));
    }

    function deployWith(Mandate memory m) external {
        _deploy(m, _config(25));
    }
}
