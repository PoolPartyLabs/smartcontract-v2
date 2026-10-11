// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";

/// @notice Core Vault custody against the live Across SpokePool on Arbitrum One (docs/INTEGRATIONS.md): the vault
///         approves exactly, the SpokePool pulls exactly the input amount from the vault with the per-send escrow as
///         depositor, the approval is reset, and a fill callback from the SpokePool address is matched by transit id.
contract CoreVaultAcrossForkTest is Test, FundSeed {
    using MandateFixture for Mandate;

    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant USDG_ROBINHOOD = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    bytes32 internal constant FUND_ID = keccak256("fork-fund");

    CoreVault internal vault;
    MockBridgeAdapter internal bridge;
    MockHubSpokeVault internal hubVault;
    MockReportReceiver internal receiver;
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal spokeVaultAddress = makeAddr("robinhoodSpokeVault");

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        bridge = new MockBridgeAdapter(SPOKE_POOL);
        hubVault = new MockHubSpokeVault(USDC);
        receiver = new MockReportReceiver();
        receiver.setMaxReportAge(0, 1587);
        MockPriceSource prices = new MockPriceSource();
        prices.setPrice(USDG_ROBINHOOD, 1e18);

        Mandate memory m;
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = USDC;
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, USDC);
        m.addToken(SPOKE, USDG_ROBINHOOD);
        m.addSwapAdapter(HUB, makeAddr("hubSwap"));
        m.addSwapAdapter(SPOKE, makeAddr("spokeSwap"));
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, makeAddr("hubAdapter"));
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, m.adapters[0].adapter, keccak256("pool"));
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] =
            SpokeConfig(SPOKE, 72, bytes32(uint256(uint160(spokeVaultAddress))), USDG_ROBINHOOD, 1_000_000e6, 1587);
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(bridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, makeAddr("spokeBridge"));
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = MandateLib.MIN_PERFORMANCE_FEE_BPS;

        CoreVaultConfig memory c;
        c.fundId = FUND_ID;
        c.usdc = USDC;
        c.hubSpokeVault = address(hubVault);
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(new MockManagerRegistry());
        c.priceSource = address(prices);
        c.acrossSpokePool = SPOKE_POOL;
        c.wormholeCore = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46; // Arbitrum One Wormhole Core (chain id 23)
        c.protocolRecipient = makeAddr("protocol");
        c.excessRecipient = makeAddr("excess");
        c.escrowImplementation = address(new TransitEscrow());
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
        vault = new CoreVault(m, c);
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(vault), vault.usdc(), vault.flowFeeBps());
        hubVault.setCoreVault(address(vault));
        receiver.setCoreVault(address(vault));

        deal(USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, 0);
        vm.stopPrank();
    }

    function test_DEC087_sendThroughLiveSpokePoolDebitsExactlyAndResetsApproval() public {
        // Security review S-14: the spoke's first report, before the hub funds it.
        ReportCodec.Report memory first;
        first.fundId = FUND_ID;
        first.mandateHash = vault.mandateHash();
        first.sequence = 1;
        first.spokeChainId = SPOKE;
        first.timestamp = uint64(block.timestamp);
        receiver.deliver(0, first);
        uint32 depositId = IAcrossSpokePool(SPOKE_POOL).numberOfDeposits();
        uint256 poolBefore = IERC20(USDC).balanceOf(SPOKE_POOL);
        // DEC-162: the bridge adapter fixes the amount to arrive (the mock adapter takes 0.6 here).
        bridge.setFee(0.6e6);
        vm.prank(manager);
        bytes32 id = vault.sendToSpoke(0, 1000e6, 0, "");
        Transit memory t = vault.transit(id);
        assertEq(uint8(t.state), uint8(TransitState.Sent));
        assertEq(t.bridgeRef, bytes32(uint256(depositId)), "Across deposit id");
        assertEq(IAcrossSpokePool(SPOKE_POOL).numberOfDeposits(), depositId + 1);
        assertEq(IERC20(USDC).balanceOf(SPOKE_POOL), poolBefore + 1000e6);
        assertEq(IERC20(USDC).allowance(address(vault), SPOKE_POOL), 0);
        assertEq(vault.idle(), SEED_IDLE + 9975e6 - 1000e6);
        assertEq(vault.inFlightValue(), 999.4e6);
    }

    function test_OQ01_fillFromLiveSpokePoolAddressMatchedByReport() public {
        bytes32 homeId = keccak256("home-1");
        deal(USDC, address(vault), IERC20(USDC).balanceOf(address(vault)) + 500e6);
        vm.prank(SPOKE_POOL);
        vault.handleV3AcrossMessage(
            USDC, 500e6, makeAddr("relayer"), TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        assertEq(vault.unmatchedArrivals(), 500e6);
        ReportCodec.Report memory r;
        r.fundId = FUND_ID;
        r.mandateHash = vault.mandateHash(); // security review S-6
        r.sequence = 1;
        r.spokeChainId = SPOKE;
        r.timestamp = uint64(block.timestamp);
        r.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        r.inFlightToHub[0] = ReportCodec.HubBoundAmount(homeId, 500e6, TransferKind.Principal);
        receiver.deliver(0, r);
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.idle(), SEED_IDLE + 9975e6 + 500e6);
        assertEq(vault.sweepExcess(USDC), 0);
    }
}
