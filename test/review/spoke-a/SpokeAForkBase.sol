// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";

interface IPermit2Holder {
    function permit2() external view returns (address);
}

/// @notice A trader on the real PoolManager: swaps to a price limit and adds or removes liquidity, paying and taking
///         what it owes in each `unlock`.
contract PoolTrader is IUnlockCallback {
    IPoolManager internal immutable pm;
    PoolKey internal key;

    constructor(IPoolManager pm_, PoolKey memory key_) {
        pm = pm_;
        key = key_;
    }

    function swapTo(bool zeroForOne, int24 limitTick) public {
        pm.unlock(abi.encode(uint8(0), abi.encode(zeroForOne, limitTick)));
    }

    function modify(int24 lo, int24 hi, int256 liquidity) public {
        pm.unlock(abi.encode(uint8(1), abi.encode(lo, hi, liquidity)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 op, bytes memory p) = abi.decode(data, (uint8, bytes));
        BalanceDelta d;
        if (op == 0) {
            (bool zeroForOne, int24 limitTick) = abi.decode(p, (bool, int24));
            d = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(uint256(type(uint128).max)),
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
                }),
                ""
            );
        } else {
            (int24 lo, int24 hi, int256 liq) = abi.decode(p, (int24, int24, int256));
            (d,) = pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, liq, bytes32(0)), "");
        }
        _resolve(key.currency0, d.amount0());
        _resolve(key.currency1, d.amount1());
        return "";
    }

    function _resolve(Currency currency, int128 amount) private {
        if (amount < 0) {
            pm.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(pm), uint256(uint128(-amount)));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice Fork base (spoke-a): a hub-only fund on Arbitrum One wired to the real Uniswap V4 WETH/USDC 0.05% pool
///         (docs/INTEGRATIONS.md), the real PoolManager, PositionManager, StateView and Permit2, with the real
///         CoreVault + hub SpokeVault + UniswapV4Adapter. The oracle is set to the pool's price at the fork block.
abstract contract SpokeAForkBase is Test, FundSeed {
    using MandateFixture for Mandate;

    address internal constant PM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant POSM = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant SV = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 internal constant HUB = 42_161;

    PoolKey internal key;
    bytes32 internal poolId;
    UniswapV4Adapter internal adapter;
    SpokeVault internal hubVault;
    MockSwapAdapter internal hubSwap;
    CoreVault internal vault;
    ShareToken internal shares;
    MockPriceSource internal prices;
    int24 internal tick0;
    bytes32 internal positionKey;

    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), 500, 10, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        (, tick0,,) = IStateView(SV).getSlot0(PoolId.wrap(poolId));

        prices = new MockPriceSource();
        MockManagerRegistry registry = new MockManagerRegistry();
        MockReportReceiver receiver = new MockReportReceiver();
        TransitEscrow escrowImpl = new TransitEscrow();

        hubSwap = new MockSwapAdapter();
        uint64 n = vm.getNonce(address(this));
        address hubVaultAt = vm.computeCreateAddress(address(this), n + 1);
        address coreAt = vm.computeCreateAddress(address(this), n + 2);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = new UniswapV4Adapter(
            hubVaultAt,
            makeAddr("guardian"),
            IPoolManager(PM),
            IPositionManager(POSM),
            IStateView(SV),
            IAllowanceTransfer(IPermit2Holder(POSM).permit2()),
            keys
        );
        Mandate memory m = _mandate(address(adapter));
        hubVault = new SpokeVault(
            m,
            keccak256("fork fund"),
            HUB,
            coreAt,
            USDC,
            makeAddr("across"),
            address(0),
            address(escrowImpl),
            makeAddr("x")
        );
        // The oracle agrees with the pool before any action (price1e18 = USDC base units per 1e18 wei); priced before
        // the Core Vault, which refuses a hub pool token its price source cannot price (review M-03).
        prices.setPrice(WETH, adapter.spotQuote(poolId, WETH, 1e18));
        vault = new CoreVault(m, _config(address(hubVault), address(registry), address(receiver), address(escrowImpl)));
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(vault), vault.usdc(), vault.flowFeeBps());
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

    /// @dev Round toward negative infinity to a multiple of the tick spacing (10).
    function _floor10(int24 t) internal pure returns (int24) {
        int24 r = t / 10 * 10;
        return r > t ? r - 10 : r;
    }

    function _mandate(address adapter_) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = USDC;
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, USDC);
        m.addToken(HUB, WETH);
        m.addSwapAdapter(HUB, address(hubSwap));
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, adapter_);
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, adapter_, poolId);
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        // DEC-127: no hub Operating Cash here. With a one-share seed, the first deposit's top-up (floor 1, top-up 3)
        // would take all of the seed's Idle before pricing and leave the Share Price at 0.
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
    }

    function _config(address hubVault_, address registry, address receiver, address escrowImpl)
        internal
        returns (CoreVaultConfig memory c)
    {
        c.fundId = keccak256("fork fund");
        c.usdc = USDC;
        c.hubSpokeVault = hubVault_;
        c.reportReceiver = receiver;
        c.managerRegistry = registry;
        c.priceSource = address(prices);
        c.acrossSpokePool = makeAddr("across");
        c.protocolRecipient = makeAddr("protocol");
        c.excessRecipient = makeAddr("x");
        c.escrowImplementation = escrowImpl;
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = WETH;
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }
}
