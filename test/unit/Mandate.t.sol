// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../src/mandate/Mandate.sol";

contract MandateHarness {
    function validate(Mandate memory m) external pure {
        MandateLib.validate(m);
    }

    function hash(Mandate memory m) external pure returns (bytes32) {
        return MandateLib.hash(m);
    }

    function isAllowedPool(Mandate memory m, uint256 chainId, address adapter, bytes32 poolKey)
        external
        pure
        returns (bool)
    {
        return MandateLib.isAllowedPool(m, chainId, adapter, poolKey);
    }

    function isAdapter(Mandate memory m, uint256 chainId, address adapter) external pure returns (bool) {
        return MandateLib.isAdapter(m, chainId, adapter);
    }

    function isBridgeAdapter(Mandate memory m, uint256 chainId, address adapter) external pure returns (bool) {
        return MandateLib.isBridgeAdapter(m, chainId, adapter);
    }

    function spokeByChainId(Mandate memory m, uint256 chainId) external pure returns (uint256, SpokeConfig memory) {
        return MandateLib.spokeByChainId(m, chainId);
    }

    function bridgeAdapterFor(Mandate memory m, uint256 spokeChainId, uint256 chainId, uint256 rank)
        external
        pure
        returns (address)
    {
        return MandateLib.bridgeAdapterFor(m, spokeChainId, chainId, rank);
    }

    function operatingCashFor(Mandate memory m, uint256 chainId) external pure returns (uint256, uint256) {
        return MandateLib.operatingCashFor(m, chainId);
    }
}

contract MandateTest is Test {
    MandateHarness internal h;

    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;

    address internal manager = makeAddr("manager");
    address internal usdc = makeAddr("usdc");
    address internal usdg = makeAddr("usdg");
    address internal hubUniswap = makeAddr("hubUniswapV4Adapter");
    address internal hubAave = makeAddr("hubAaveV3Adapter");
    address internal spokeUniswap = makeAddr("spokeUniswapV4Adapter");
    address internal hubAcross = makeAddr("hubAcrossAdapter");
    address internal hubAcrossFallback = makeAddr("hubAcrossFallback");
    address internal spokeAcross = makeAddr("spokeAcrossAdapter");
    address internal spokeVaultAddress = makeAddr("spokeVault");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant AAVE_USDC = keccak256("aave USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    function setUp() public {
        h = new MandateHarness();
    }

    function _valid() internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = usdc;

        m.adapters = new AdapterConfig[](3);
        m.adapters[0] = AdapterConfig(HUB, hubUniswap);
        m.adapters[1] = AdapterConfig(HUB, hubAave);
        m.adapters[2] = AdapterConfig(SPOKE, spokeUniswap);

        m.pools = new PoolConfig[](3);
        m.pools[0] = PoolConfig(HUB, hubUniswap, HUB_POOL);
        m.pools[1] = PoolConfig(HUB, hubAave, AAVE_USDC);
        m.pools[2] = PoolConfig(SPOKE, spokeUniswap, SPOKE_POOL);

        m.unwindOrder = new UnwindStep[](2);
        m.unwindOrder[0] = UnwindStep(HUB, hubAave, AAVE_USDC);
        m.unwindOrder[1] = UnwindStep(HUB, hubUniswap, HUB_POOL);

        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig({
            chainId: SPOKE,
            wormholeChainId: WH_SPOKE,
            spokeVault: bytes32(uint256(uint160(spokeVaultAddress))),
            spokeToken: usdg,
            spokeCap: 100_000e6,
            maxReportAge: 1588
        });

        m.bridgeAdapters = new BridgeAdapterConfig[](3);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, hubAcross);
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, spokeAcross);
        m.bridgeAdapters[2] = BridgeAdapterConfig(SPOKE, HUB, hubAcrossFallback);

        m.operatingCash = new OperatingCashConfig[](2);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        m.operatingCash[1] = OperatingCashConfig(SPOKE, 5e6, 10e6);

        m.payoutFeeBps = MandateLib.DEFAULT_PAYOUT_FEE_BPS;
        m.standardPayoutTerm = MandateLib.DEFAULT_STANDARD_PAYOUT_TERM;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
        m.maxBridgeFeeBps = 50;
    }

    // ------------------------------------------------------------------ defaults and happy path

    function test_DEC095_startingValuesPayoutFee2PercentTerm72h() public pure {
        assertEq(MandateLib.DEFAULT_PAYOUT_FEE_BPS, 200);
        assertEq(MandateLib.DEFAULT_STANDARD_PAYOUT_TERM, 72 hours);
    }

    function test_LC57_openCapConstantsCarryProposedValues() public pure {
        assertEq(MandateLib.MAX_PERFORMANCE_FEE_BPS, 2500);
        assertEq(MandateLib.MAX_MANAGEMENT_FEE_BPS, 200);
    }

    function test_DEC053_validMandatePasses() public view {
        h.validate(_valid());
    }

    function test_DEC054_hubOnlyMandateWithoutSpokesPasses() public view {
        Mandate memory m = _valid();
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, hubUniswap);
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, hubUniswap, HUB_POOL);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, hubUniswap, HUB_POOL);
        m.operatingCash = new OperatingCashConfig[](0);
        h.validate(m);
    }

    function test_DEC053_hashIsDeterministicAndCommitsToEveryField() public view {
        Mandate memory m = _valid();
        bytes32 hashA = h.hash(m);
        assertEq(hashA, h.hash(_valid()));
        m.spokes[0].spokeCap += 1;
        assertTrue(h.hash(m) != hashA);
    }

    // ------------------------------------------------------------------ identity fields

    function test_DEC002_zeroManagerReverts() public {
        Mandate memory m = _valid();
        m.manager = address(0);
        vm.expectRevert(MandateLib.ZeroManager.selector);
        h.validate(m);
    }

    function test_DEC011_zeroUsdcOrHubChainReverts() public {
        Mandate memory m = _valid();
        m.usdc = address(0);
        vm.expectRevert(MandateLib.ZeroUsdc.selector);
        h.validate(m);
        m = _valid();
        m.hubChainId = 0;
        vm.expectRevert(MandateLib.ZeroHubChainId.selector);
        h.validate(m);
    }

    // ------------------------------------------------------------------ closed lists

    function test_DEC053_emptyAdapterListReverts() public {
        Mandate memory m = _valid();
        m.adapters = new AdapterConfig[](0);
        vm.expectRevert(MandateLib.EmptyAdapters.selector);
        h.validate(m);
    }

    function test_DEC030_emptyPoolListReverts() public {
        Mandate memory m = _valid();
        m.pools = new PoolConfig[](0);
        vm.expectRevert(MandateLib.EmptyPools.selector);
        h.validate(m);
    }

    function test_DEC069_emptyUnwindOrderReverts() public {
        Mandate memory m = _valid();
        m.unwindOrder = new UnwindStep[](0);
        vm.expectRevert(MandateLib.EmptyUnwindOrder.selector);
        h.validate(m);
    }

    function test_DEC058_duplicateAdapterReverts() public {
        Mandate memory m = _valid();
        m.adapters[1] = AdapterConfig(HUB, hubUniswap);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateAdapter.selector, HUB, hubUniswap));
        h.validate(m);
    }

    function test_DEC058_zeroAdapterReverts() public {
        Mandate memory m = _valid();
        m.adapters[0].adapter = address(0);
        vm.expectRevert(MandateLib.ZeroAdapter.selector);
        h.validate(m);
    }

    function test_DEC053_adapterOnUnknownChainReverts() public {
        Mandate memory m = _valid();
        m.adapters[2].chainId = 8453;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownChain.selector, 8453));
        h.validate(m);
    }

    function test_DEC030_poolBehindUnlistedAdapterReverts() public {
        Mandate memory m = _valid();
        m.pools[2] = PoolConfig(SPOKE, hubUniswap, SPOKE_POOL);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.PoolAdapterNotListed.selector, SPOKE, hubUniswap));
        h.validate(m);
    }

    function test_DEC030_duplicatePoolReverts() public {
        Mandate memory m = _valid();
        m.pools[1] = PoolConfig(HUB, hubUniswap, HUB_POOL);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicatePool.selector, HUB, hubUniswap, HUB_POOL));
        h.validate(m);
    }

    function test_DEC069_unwindStepOutsidePoolListReverts() public {
        Mandate memory m = _valid();
        m.unwindOrder[1] = UnwindStep(HUB, hubUniswap, SPOKE_POOL);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnwindStepNotInPools.selector, HUB, hubUniswap, SPOKE_POOL));
        h.validate(m);
    }

    function test_DEC069_duplicateUnwindStepReverts() public {
        Mandate memory m = _valid();
        m.unwindOrder[1] = UnwindStep(HUB, hubAave, AAVE_USDC);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateUnwindStep.selector, HUB, hubAave, AAVE_USDC));
        h.validate(m);
    }

    // ------------------------------------------------------------------ spokes

    function test_DEC011_spokeOnHubChainReverts() public {
        Mandate memory m = _valid();
        m.spokes[0].chainId = HUB;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.SpokeIsHubChain.selector, HUB));
        h.validate(m);
    }

    function test_DEC086_duplicateSpokeReverts() public {
        Mandate memory m = _valid();
        SpokeConfig[] memory spokes = new SpokeConfig[](2);
        spokes[0] = m.spokes[0];
        spokes[1] = m.spokes[0];
        spokes[1].chainId = 8453; // different EVM chain, same Wormhole chain id
        m.spokes = spokes;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateSpoke.selector, 8453, WH_SPOKE));
        h.validate(m);
    }

    function test_DEC087_spokeWithoutVaultReverts() public {
        Mandate memory m = _valid();
        m.spokes[0].spokeVault = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.InvalidSpoke.selector, SPOKE));
        h.validate(m);
    }

    function test_DEC099_zeroMaxReportAgeReverts() public {
        Mandate memory m = _valid();
        m.spokes[0].maxReportAge = 0;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.InvalidSpoke.selector, SPOKE));
        h.validate(m);
    }

    function test_DEC031_spokeByChainIdFindsSpokeAndRevertsOtherwise() public {
        (uint256 index, SpokeConfig memory s) = h.spokeByChainId(_valid(), SPOKE);
        assertEq(index, 0);
        assertEq(s.wormholeChainId, WH_SPOKE);
        assertEq(s.spokeToken, usdg);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownSpokeChain.selector, 1));
        h.spokeByChainId(_valid(), 1);
    }

    // ------------------------------------------------------------------ bridge adapters

    function test_DEC088_bridgeAdaptersOrderedPrimaryThenFallback() public {
        Mandate memory m = _valid();
        assertEq(h.bridgeAdapterFor(m, SPOKE, HUB, 0), hubAcross);
        assertEq(h.bridgeAdapterFor(m, SPOKE, HUB, 1), hubAcrossFallback);
        assertEq(h.bridgeAdapterFor(m, SPOKE, SPOKE, 0), spokeAcross);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.NoBridgeAdapter.selector, SPOKE, SPOKE, 1));
        h.bridgeAdapterFor(m, SPOKE, SPOKE, 1);
    }

    function test_DEC089_spokeWithoutHubSideBridgeAdapterReverts() public {
        Mandate memory m = _valid();
        BridgeAdapterConfig[] memory b = new BridgeAdapterConfig[](1);
        b[0] = BridgeAdapterConfig(SPOKE, SPOKE, spokeAcross);
        m.bridgeAdapters = b;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.MissingBridgeAdapter.selector, SPOKE, HUB));
        h.validate(m);
    }

    function test_DEC089_spokeWithoutSpokeSideBridgeAdapterReverts() public {
        Mandate memory m = _valid();
        BridgeAdapterConfig[] memory b = new BridgeAdapterConfig[](1);
        b[0] = BridgeAdapterConfig(SPOKE, HUB, hubAcross);
        m.bridgeAdapters = b;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.MissingBridgeAdapter.selector, SPOKE, SPOKE));
        h.validate(m);
    }

    function test_DEC087_bridgeAdapterForUnknownSpokeReverts() public {
        Mandate memory m = _valid();
        m.bridgeAdapters[2] = BridgeAdapterConfig(8453, HUB, hubAcrossFallback);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownSpokeChain.selector, 8453));
        h.validate(m);
    }

    function test_DEC087_bridgeAdapterOnThirdChainReverts() public {
        Mandate memory m = _valid();
        SpokeConfig[] memory spokes = new SpokeConfig[](2);
        spokes[0] = m.spokes[0];
        spokes[1] = SpokeConfig(8453, 30, bytes32(uint256(1)), usdg, 1, 1);
        m.spokes = spokes;
        // An adapter serving the Robinhood spoke cannot live on the Base spoke.
        m.bridgeAdapters[2] = BridgeAdapterConfig(SPOKE, 8453, hubAcrossFallback);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BridgeAdapterSideInvalid.selector, SPOKE, 8453));
        h.validate(m);
    }

    function test_DEC087_addressCannotBeBothPositionAndBridgeAdapter() public {
        Mandate memory m = _valid();
        m.bridgeAdapters[2] = BridgeAdapterConfig(SPOKE, HUB, hubUniswap);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateAdapter.selector, HUB, hubUniswap));
        h.validate(m);
    }

    function test_DEC088_duplicateBridgeAdapterForSameSpokeReverts() public {
        Mandate memory m = _valid();
        m.bridgeAdapters[2] = BridgeAdapterConfig(SPOKE, HUB, hubAcross);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateAdapter.selector, HUB, hubAcross));
        h.validate(m);
    }

    function test_DEC053_lookupHelpers() public view {
        Mandate memory m = _valid();
        assertTrue(h.isAllowedPool(m, HUB, hubUniswap, HUB_POOL));
        assertFalse(h.isAllowedPool(m, SPOKE, hubUniswap, HUB_POOL));
        assertFalse(h.isAllowedPool(m, HUB, hubUniswap, SPOKE_POOL));
        assertTrue(h.isAdapter(m, SPOKE, spokeUniswap));
        assertFalse(h.isAdapter(m, HUB, spokeUniswap));
        assertTrue(h.isBridgeAdapter(m, HUB, hubAcross));
        assertFalse(h.isBridgeAdapter(m, SPOKE, hubAcross));
    }

    // ------------------------------------------------------------------ Operating Cash

    function test_DEC096_operatingCashForReturnsCreationValues() public view {
        (uint256 floorHub, uint256 topUpHub) = h.operatingCashFor(_valid(), HUB);
        assertEq(floorHub, 1e6);
        assertEq(topUpHub, 3e6);
        (uint256 floorOther, uint256 topUpOther) = h.operatingCashFor(_valid(), 1);
        assertEq(floorOther + topUpOther, 0);
    }

    function test_DEC096_duplicateOperatingCashChainReverts() public {
        Mandate memory m = _valid();
        m.operatingCash[1].chainId = HUB;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.DuplicateOperatingCashChain.selector, HUB));
        h.validate(m);
    }

    function test_DEC096_operatingCashOnUnknownChainReverts() public {
        Mandate memory m = _valid();
        m.operatingCash[1].chainId = 1;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownChain.selector, 1));
        h.validate(m);
    }

    // ------------------------------------------------------------------ fees

    function test_DEC110_performanceFeeAboveOpenCapReverts() public {
        Mandate memory m = _valid();
        m.performanceFeeBps = 2501;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 2501, 2500));
        h.validate(m);
        m.performanceFeeBps = 2500;
        h.validate(m);
    }

    function test_DEC108_managementFeeMustBeZeroInMvp() public {
        Mandate memory m = _valid();
        m.managementFeeBps = 1;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.ManagementFeeNotSupported.selector, 1));
        h.validate(m);
    }

    function test_DEC006_payoutFeeAboveHundredPercentReverts() public {
        Mandate memory m = _valid();
        m.payoutFeeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_001, 10_000));
        h.validate(m);
    }

    function test_DEC030_bridgeFeeAboveHundredPercentReverts() public {
        Mandate memory m = _valid();
        m.maxBridgeFeeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_001, 10_000));
        h.validate(m);
    }
}
