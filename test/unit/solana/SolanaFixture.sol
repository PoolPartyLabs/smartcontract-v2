pragma solidity 0.8.28;

import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeConfig} from "../../../src/mandate/Mandate.sol";

/// @notice Shared full-width key fixtures for DEC-188, DEC-190, DEC-192.
library SolanaFixture {
    bytes32 internal constant USDC = 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
    bytes32 internal constant STOCK = 0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a;
    bytes32 internal constant SOL = 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001;
    bytes32 internal constant EMITTER = 0xec7372995d5cc8732397fb0ad35c0121e0eaa90d26f828a534cab54391b3a4f5;
    uint256 internal constant CHAIN = 1;

    function nativeConfig() internal pure returns (SolanaMandateV6.Config memory config) {
        config.program = bytes32(uint256(100));
        config.spoke = EMITTER;
        config.usdcMint = USDC;
        config.managerKey = bytes32(uint256(200));
        config.chainId = CHAIN;
        config.transport = SolanaMandateV6.Transport(
            address(0),
            0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
            0x81D40F21F12A8F0E3252Bccb954D722d4c464B64,
            5,
            bytes32(uint256(9001)),
            bytes32(uint256(9002)),
            bytes32(uint256(1234)),
            bytes32(uint256(9003)),
            50_000
        );
        config.assets = new SolanaMandateV6.Asset[](3);
        config.assets[0] = SolanaMandateV6.Asset(USDC, SolanaMandateV6.accountingId(USDC), false);
        config.assets[1] = SolanaMandateV6.Asset(STOCK, SolanaMandateV6.accountingId(STOCK), true);
        config.assets[2] = SolanaMandateV6.Asset(SOL, SolanaMandateV6.accountingId(SOL), false);
        config.venues = new SolanaMandateV6.Venue[](2);
        config.venues[0] = SolanaMandateV6.Venue(bytes32(uint256(300)), bytes32(uint256(400)), 0, STOCK, USDC);
        config.venues[1] = SolanaMandateV6.Venue(bytes32(uint256(500)), 0, bytes32(uint256(600)), USDC, 0);
    }

    function spokes() internal pure returns (SpokeConfig[] memory configs) {
        configs = new SpokeConfig[](2);
        configs[0] = SpokeConfig(4663, 72, bytes32(uint256(700)), address(800), 100e6, 1600);
        configs[1] = SpokeConfig(CHAIN, 1, EMITTER, SolanaMandateV6.accountingId(USDC), 100e6, 1600);
    }

    function report(uint64 timestamp) internal pure returns (ReportCodecV6.Report memory result) {
        result.fundId = bytes32(uint256(1));
        result.mandateHash = bytes32(uint256(2));
        result.nativeMandateHash = SolanaMandateV6.hash(nativeConfig());
        result.sequence = 1;
        result.spokeChainId = CHAIN;
        result.slot = 453_978_307;
        result.timestamp = timestamp;
        result.unallocated = new ReportCodecV6.TokenAmount[](1);
        result.unallocated[0] = ReportCodecV6.TokenAmount(USDC, 50e6);
        result.mintStates = new ReportCodecV6.MintState[](1);
        result.mintStates[0] =
            ReportCodecV6.MintState(STOCK, 0x3ff0000000000000, 0x3ff0000000000000, 0, false, false, 0);
        result.arrivedTransits = new ReportCodec.TransitAmount[](1);
        result.arrivedTransits[0] = ReportCodec.TransitAmount(bytes32(uint256(900)), 49_990_000);
    }
}
