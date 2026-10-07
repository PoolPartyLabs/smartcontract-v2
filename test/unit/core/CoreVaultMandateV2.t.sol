// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice WP-07 B2 and B3: the Core Vault reads the Mandate v2 token list and Hub Wormhole chain id at creation. Every Mandate token of every
///         chain must have a price (DEC-123 level 1: an asset without a reliable source is not admitted), and the hub
///         income tokens are USDC then the Mandate's other hub tokens.
contract CoreVaultMandateV2Test is CoreVaultFixture {
    using MandateFixture for Mandate;

    /// @dev The fixture lists USDC and WETH on the hub, USDG and Robinhood WETH on the spoke: the Hub income source
    ///      (0) holds the hub's, the spoke's source (1) the spoke's (DEC-161, doc 10 section 6).
    function test_DEC136_incomeTokensAreTheMandateTokensOfEachSource() public view {
        assertTrue(vault.incomeToken(0, address(usdc)).registered, "USDC on the Hub");
        assertTrue(vault.incomeToken(0, address(weth)).registered);
        assertFalse(vault.incomeToken(0, address(usdg)).registered, "a spoke token is not a Hub income token");
        assertTrue(vault.incomeToken(1, address(usdg)).registered, "the spoke's own source");
        assertTrue(vault.incomeToken(1, address(spokeWeth)).registered);
        assertFalse(vault.incomeToken(1, address(usdc)).registered);
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

    /// @dev D-15 (DEC-120, DEC-139): the Core the Hub publishes its orders through must sit on the Mandate's Hub
    ///      Wormhole chain, or every spoke would refuse every order.
    function test_DEC120_coreVaultChecksTheHubWormholeChainId() public {
        assertEq(vault.wormholeCore(), address(hubWormhole));
        hubWormhole.setChainId(72);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.HubWormholeChainIdMismatch.selector, uint16(72), uint16(23)));
        this.deployWith(_mandate(2000));

        hubWormhole.setChainId(23);
        Mandate memory m = _mandate(2000);
        m.hubWormholeChainId = 30;
        m.spokes[0].wormholeChainId = 72;
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.HubWormholeChainIdMismatch.selector, uint16(23), uint16(30)));
        this.deployWith(m);
    }

    function test_DEC120_coreVaultRequiresAWormholeCore() public {
        CoreVaultConfig memory c = _config(25);
        c.wormholeCore = address(0);
        vm.expectRevert(ICoreVault.ZeroAddress.selector);
        this.deployWithConfig(c);
    }

    function deployWith(Mandate memory m) external {
        _deploy(m, _config(25));
    }

    function deployWithConfig(CoreVaultConfig memory c) external {
        _deploy(_mandate(2000), c);
    }
}
