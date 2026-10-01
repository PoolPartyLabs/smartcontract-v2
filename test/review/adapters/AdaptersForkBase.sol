// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";

interface IPermit2Of {
    function permit2() external view returns (address);
}

/// @notice Fork base (adapters review): a hub-only fund on Arbitrum One built from the real CoreVault, hub SpokeVault
///         and UniswapV4Adapter on the real PoolManager, PositionManager, StateView and Permit2, with TWO Mandate pools:
///         the live WETH/USDC 0.05% pool (docs/INTEGRATIONS.md) and a second hookless WETH/USDC pool whose static LP fee
///         the test chooses (`_secondFee()`), initialized at the live pool's price before the fund is created.
///         Performance fee at the Mandate cap (2,500 bps, MandateLib.MAX_PERFORMANCE_FEE_BPS), protocol slice 50%.
abstract contract AdaptersForkBase is Test {
    address internal constant PM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant POSM = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant SV = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 internal constant HUB = 42_161;
    bytes32 internal constant FUND_ID = keccak256("adapters review fund");

    PoolKey internal liveKey;
    bytes32 internal livePool;
    PoolKey internal secondKey;
    bytes32 internal secondPool;
    int24 internal tick0;
    uint160 internal sqrtP0;

    UniswapV4Adapter internal adapter;
    SpokeVault internal hubVault;
    CoreVault internal vault;
    ShareToken internal shares;
    MockPriceSource internal prices;

    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal protocolRecipient = makeAddr("protocol");

    /// @dev Static LP fee of the second Mandate pool, in pips (V4 accepts up to 1,000,000 = 100% for a hookless pool).
    function _secondFee() internal pure virtual returns (uint24);

    function _secondTickSpacing() internal pure virtual returns (int24) {
        return 60;
    }

    function setUp() public virtual {
        _forkAndInitializeSecondPool();
        _deployFund();
    }

    /// @dev Port to fix/pp-sc-fix-independent-review: set-up split in two so a test can assert that the adapter refuses
    ///      the second pool (`UniswapV4Adapter.PoolFeeTooHigh`, review M-02) without deploying the fund.
    function _forkAndInitializeSecondPool() internal {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        liveKey = PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), 500, 10, IHooks(address(0)));
        livePool = PoolId.unwrap(liveKey.toId());
        (sqrtP0, tick0,,) = IStateView(SV).getSlot0(PoolId.wrap(livePool));

        // Anyone may initialize a hookless V4 pool with any static fee up to 100% (V4 itself bounds nothing below it).
        secondKey =
            PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), _secondFee(), _secondTickSpacing(), IHooks(address(0)));
        secondPool = PoolId.unwrap(secondKey.toId());
        IPoolManager(PM).initialize(secondKey, sqrtP0);
    }

    function _deployFund() internal {
        prices = new MockPriceSource();
        MockManagerRegistry registry = new MockManagerRegistry();
        MockReportReceiver receiver = new MockReportReceiver();
        TransitEscrow escrowImpl = new TransitEscrow();

        uint64 n = vm.getNonce(address(this));
        address hubVaultAt = vm.computeCreateAddress(address(this), n + 1);
        address coreAt = vm.computeCreateAddress(address(this), n + 2);
        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = liveKey;
        keys[1] = secondKey;
        adapter = new UniswapV4Adapter(
            hubVaultAt,
            makeAddr("guardian"),
            IPoolManager(PM),
            IPositionManager(POSM),
            IStateView(SV),
            IAllowanceTransfer(IPermit2Of(POSM).permit2()),
            keys
        );
        Mandate memory m = _mandate(address(adapter));
        hubVault = new SpokeVault(
            m, FUND_ID, HUB, coreAt, USDC, makeAddr("across"), address(0), address(escrowImpl), makeAddr("excess")
        );
        // Priced before the Core Vault: it refuses a hub pool token its price source cannot price (review M-03).
        prices.setPrice(WETH, adapter.spotQuote(livePool, WETH, 1e18));
        vault = new CoreVault(m, _config(address(hubVault), address(registry), address(receiver), address(escrowImpl)));
        require(address(hubVault) == hubVaultAt && address(vault) == coreAt, "wiring");
        shares = ShareToken(vault.shareToken());
    }

    function _depositAs(address who, uint256 amount) internal {
        deal(USDC, who, amount);
        vm.startPrank(who);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev USDC value at the oracle (set to the live pool price at the fork block).
    function _usd(uint256 wethAmount, uint256 usdcAmount) internal view returns (uint256) {
        (uint256 price1e18,) = prices.priceInUsdc(WETH);
        return wethAmount * price1e18 / 1e18 + usdcAmount;
    }

    function _floor(int24 t, int24 spacing) internal pure returns (int24) {
        int24 r = t / spacing * spacing;
        return r > t ? r - spacing : r;
    }

    function _mandate(address adapter_) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = USDC;
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, adapter_);
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, adapter_, livePool);
        m.pools[1] = PoolConfig(HUB, adapter_, secondPool);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, adapter_, livePool);
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        m.payoutFeeBps = 200;
        m.standardPayoutTerm = 72 hours;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 2500; // MandateLib.MAX_PERFORMANCE_FEE_BPS
        m.managementFeeBps = 0;
        m.maxBridgeFeeBps = 50;
    }

    function _config(address hubVault_, address registry, address receiver, address escrowImpl)
        internal
        returns (CoreVaultConfig memory c)
    {
        c.fundId = FUND_ID;
        c.usdc = USDC;
        c.hubSpokeVault = hubVault_;
        c.reportReceiver = receiver;
        c.managerRegistry = registry;
        c.priceSource = address(prices);
        c.acrossSpokePool = makeAddr("across");
        c.protocolRecipient = protocolRecipient;
        c.excessRecipient = makeAddr("excess");
        c.escrowImplementation = escrowImpl;
        c.flowFeeBps = 25;
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = WETH;
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }
}
