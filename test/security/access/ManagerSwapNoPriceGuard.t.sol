// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {MockV3Pool} from "../../mocks/swap/MockV3.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: a manager swap accepts the price of the pool it runs in, so a manager that moves every V3 tier of the
///        pair first trades the fund against itself (risk accepted by DEC-129 and DEC-142)
/// @notice ATTACK. Since DEC-136 the manager swaps only through the Mandate swap adapter (`SpokeVault.swap`), never in
///         a fund pool; without an API route the adapter trades in the best direct Uniswap V3 fee tier it quotes
///         (DEC-153), and the manager's maximum loss is optional, without a protocol cap, measured against that pool's
///         mid just before the trade (DEC-142). A manager that is a contract (nothing requires an EOA) can, in one
///         transaction, push the mid of every tier of the pair with its own capital or a flash loan, call
///         `swap(all Unallocated USDC)` and trade back. The mid is pushed too, so even a maximum loss does not bind.
///         DEC-142 records the consequence: neither bound protects against whoever moves the pool first, in the same
///         transaction, the risk DEC-129 accepted.
/// @notice IMPACT. The manager can move nearly all of a Spoke Vault's Unallocated Balance to itself in one transaction
///         when it can push every tier of the pair (here the pair has one). Shareholders cannot react: a Payout
///         Request is priced after the fact.
/// @notice WHAT THE SWAP ADAPTER CHANGED. The manager no longer chooses where the fund trades: one tier the manager did
///         not push is enough, the adapter quotes every tier and trades in the best (second test).
/// @notice FIX (needs a ruling). Anchor manager swaps to a price the manager does not control: on the hub the fund
///         already has `IPriceSource`; require `amountOut >= oracle value less a Mandate bound in bps` for tokens it
///         prices. On a spoke without a price source, bound the pool's spot against a time-weighted price, or accept
///         the risk explicitly (DEC-142 as decided).
/// @dev The fund's swap adapter is the factory-deployed `UniswapV3SwapAdapter` over the V3 stand-in; `setSqrtPriceX96`
///      stands in for the manager's trade that pushes a pool before the fund's swap.
contract ManagerSwapNoPriceGuardPoC is AccessFundFixture {
    CoreVault internal core;
    SpokeVault internal hub;
    address internal swapAdapter;

    function setUp() public override {
        super.setUp();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        core = CoreVault(a.coreVault);
        hub = _hubVault(a);
        swapAdapter = a.chains[0].uniswapV3SwapAdapter;
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        vm.prank(manager);
        core.allocateToHubSpokeVault(900_000e6);
        assertEq(core.shareAssets(), SEED_IDLE + 997_500e6);
    }

    function test_POC_managerSwapsUnallocatedBalanceAtAPriceItSet() public {
        // The manager pushes the pair's only V3 tier: 1 unit of WETH now costs 100 units of USDC (the oracle still
        // says 1). A 1% maximum loss does not bind: it is measured against the pushed mid.
        _push(_v3WethUsdcPool());
        vm.prank(manager);
        uint256 wethOut = hub.swap(swapAdapter, address(usdc), address(weth), 900_000e6, 100, "");

        // Within 2 units: the pushed price's square root is not exact in one token order.
        assertApproxEqAbs(wethOut, 8999.1e6, 2, "900,000 USDC of Unallocated Balance bought 8,999.1 USDC of WETH");
        assertEq(hub.unallocatedBalance(address(usdc)), 0);
        assertApproxEqAbs(
            core.shareAssets(), SEED_IDLE + 97_500e6 + 8999.1e6, 2, "about 891,000 USDC left the fund in one call"
        );
        assertLt(core.sharePrice(), 0.11e24, "Share Price: from 1.00 to under 0.11");
    }

    /// @dev One tier the manager did not push defeats it: the adapter trades in the best quote (DEC-153).
    function test_SEC_DEC153_oneHonestTierDefeatsThePush() public {
        _push(_v3WethUsdcPool());
        v3.createPool(address(weth), address(usdc), 500, uint160(1 << 96), 1e24);
        vm.prank(manager);
        uint256 wethOut = hub.swap(swapAdapter, address(usdc), address(weth), 900_000e6, 100, "");

        assertEq(wethOut, 899_550e6, "the honest 0.05% tier, at the oracle price less its fee");
        assertEq(core.shareAssets(), SEED_IDLE + 997_500e6 - 450e6, "only the pool fee left the fund");
    }

    /// @dev WETH 100 times dearer in USDC, whatever the token order.
    function _push(MockV3Pool pool) internal {
        bool wethIsToken0 = address(weth) < address(usdc);
        uint256 q96 = 1 << 96;
        pool.setSqrtPriceX96(uint160(wethIsToken0 ? 10 * q96 : q96 / 10));
    }
}
