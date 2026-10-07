// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAaveV3Pool} from "../../../src/interfaces/external/IAaveV3Pool.sol";
import {IAToken} from "../../../src/interfaces/external/IAToken.sol";

interface IAavePoolExtra {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getVirtualUnderlyingBalance(address asset) external view returns (uint128);
}

/// @notice (adapters review) The Aave V3 adapter against the live Pool (revision 11) and aArbUSDCn on Arbitrum One.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100>
///      forge test --match-path 'test/review/adapters/AaveLiveReserveFork.t.sol' -vv
contract AaveLiveReserveFork is Test {
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 internal constant RAY = 1e27;

    AaveV3Adapter internal adapter;
    address internal vault = makeAddr("vault");
    address internal borrower = makeAddr("borrower");
    bytes32 internal key = bytes32(uint256(uint160(USDC)));

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        adapter = new AaveV3Adapter(vault, makeAddr("guardian"), POOL, assets);
        deal(USDC, vault, 100_000_000e6);
        deal(WETH, borrower, 30_000 ether);
        vm.startPrank(borrower);
        IERC20(WETH).approve(POOL, type(uint256).max);
        IAaveV3Pool(POOL).supply(WETH, 30_000 ether, borrower, 0);
        vm.stopPrank();
    }

    function _open(uint256 amount) internal {
        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), amount);
        adapter.openPosition(key, abi.encode(amount));
        vm.stopPrank();
    }

    function _virtual() internal view returns (uint256) {
        return IAavePoolExtra(POOL).getVirtualUnderlyingBalance(USDC);
    }

    /// @dev Borrowers take the reserve's virtual liquidity (what `withdraw` can actually pay) down to `target`.
    function _drainVirtualTo(uint256 target) internal {
        uint256 amount = _virtual() - target;
        vm.prank(borrower);
        IAavePoolExtra(POOL).borrow(USDC, amount, 2, 0, borrower);
        assertEq(_virtual(), target);
    }

    /// Income is withdrawn "best effort up to the reserve's available liquidity", but the bound is the aToken's USDC
    /// `balanceOf`, which on the live reserve is above the virtual balance `withdraw` checks (stray USDC sent to the
    /// aToken). Whenever the pending income exceeds the virtual liquidity, the adapter asks for more than Aave can pay,
    /// the withdrawal reverts inside the try and the collect pays 0, although Aave could pay the whole virtual
    /// liquidity.
    /// @dev Ported to fix/pp-sc-fix-independent-review: STILL PRESENT (review L-08 second half, register S-34
    ///      Acknowledged: income only, delayed not lost). e5c778a: stray 40.946615 USDC, 4,839.65 pending, 2,419.82 of
    ///      virtual liquidity, 0 paid.
    function test_POC_REVIEW_L08_incomeBoundUsesTheATokenBalanceNotTheVirtualLiquidity() public {
        uint256 stray = IERC20(USDC).balanceOf(A_USDC) - _virtual();
        console2.log("USDC held by aArbUSDCn above the virtual balance (stray)", stray);
        assertGt(stray, 0);

        _open(1_000_000e6);
        vm.warp(block.timestamp + 60 days);
        vm.roll(block.number + 1);
        uint256 pending = adapter.positionValue(key).income0;
        console2.log("pending income", pending);

        _drainVirtualTo(pending / 2);
        uint256 before = IERC20(USDC).balanceOf(vault);
        vm.prank(vault);
        IAdapter.Amounts memory c = adapter.collectIncome(key);
        console2.log("virtual liquidity", _virtual());
        console2.log("income the collect paid", c.income0);
        assertEq(c.income0, 0, "the collect paid nothing");
        assertEq(IERC20(USDC).balanceOf(vault), before);

        // The reserve could have paid half the income: a withdrawal of the virtual liquidity succeeds.
        vm.prank(address(adapter));
        uint256 paid = IAaveV3Pool(POOL).withdraw(USDC, pending / 2, makeAddr("sink"));
        assertEq(paid, pending / 2, "Aave pays the virtual liquidity when asked for it");
    }

    /// Foreign aTokens (a stranger's supply on the adapter's behalf, DEC-080) plus a reserve whose virtual liquidity is
    /// between the fund's value and the adapter's whole aToken balance: the one-shot maximum withdrawal fails, the
    /// fallback withdraws the principal, then the income withdrawal burns one scaled unit more than the ledger holds.
    /// @dev Ported to fix/pp-sc-fix-independent-review (review L-08, plan F1): FIXED. e5c778a: 6 of the 12 principal
    ///      sizes reverted `LedgerUnderflow` (7 and 9 of 12 at two other blocks). Now every close completes with the
    ///      whole principal and the whole income.
    function test_REVIEW_L08_foreignATokensNoLongerBlockTheCloseOnTheLivePool() public {
        uint256 incomeShort;
        for (uint256 j; j < 12; ++j) {
            uint256 snap = vm.snapshotState();
            (IAdapter.PositionValue memory v, IAdapter.Amounts memory a) = _close(1_000_000e6 + j * 7_777_777);
            assertEq(a.principal0, v.principal0, "the whole principal left");
            assertGe(a.income0 + 1, v.income0, "and the income, up to one unit of rounding");
            if (a.income0 < v.income0) ++incomeShort;
            vm.revertToState(snap);
        }
        console2.log("principal sizes tried / closes paid one unit of income short", uint256(12), incomeShort);
    }

    function _close(uint256 principal) internal returns (IAdapter.PositionValue memory v, IAdapter.Amounts memory a) {
        _open(principal);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);
        v = adapter.positionValue(key);

        address stranger = makeAddr("stranger");
        deal(USDC, stranger, 1000e6);
        vm.startPrank(stranger);
        IERC20(USDC).approve(POOL, 1000e6);
        IAaveV3Pool(POOL).supply(USDC, 1000e6, address(adapter), 0);
        vm.stopPrank();

        // Enough virtual liquidity for the fund's own principal and income, not for the foreign aTokens too.
        _drainVirtualTo(v.principal0 + v.income0 + 500e6);
        vm.prank(vault);
        a = adapter.closePosition(key, "");
    }
}
