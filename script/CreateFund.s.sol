// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../src/factory/FundFactory.sol";
import {Mandate, MandateLib} from "../src/mandate/Mandate.sol";
import {FactoryDeployment} from "./FactoryDeployment.sol";
import {FundMandate} from "./FundMandate.sol";

/// @title CreateFund
/// @notice Creates a fund with Arbitrum One as Hub Chain and Robinhood Chain as Spoke Chain: on Arbitrum it predicts the
///         addresses, builds the Mandate and calls `createFund`; on Robinhood it rebuilds the same Mandate and calls
///         `createSpoke` with the `mandateHash` the hub emitted (docs/DEPLOYMENT.md).
/// @dev The fund uses the docs/INTEGRATIONS.md pools: WETH/USDC 0.05% on Uniswap V4 and USDC on Aave V3 on the hub,
///      WETH/USDG 0.05% on Uniswap V4 on Robinhood. Mandate v2 (WP-07 B): the Mandate tokens are Arbitrum USDC and
///      WETH and Robinhood USDG and WETH, each chain has the fund's Uniswap V3 swap adapter (DEC-136), and the Hub's
///      Wormhole chain id is 23. The rule values are the manager's (DEC-053) and come from the environment with the
///      defaults below.
/// @dev Environment: `FUND_FACTORY`, `MANAGER` (the broadcaster; DEC-001: the creator is the Manager); on Robinhood also
///      `CREATION_NUMBER` and `MANDATE_HASH` from the hub's `FundCreated` event. Optional: `SPOKE_CAP`,
///      `MIN_FIRST_DEPOSIT`, `PERFORMANCE_FEE_BPS` (default 2,000, within [1,000, 9,000]: DEC-182, DEC-184),
///      `MANAGEMENT_FEE_BPS` (default 0, at most 500: DEC-184, DEC-186), `SPOKE_OPERATING_CASH_FLOOR` and
///      `SPOKE_OPERATING_CASH_TOP_UP` (Robinhood USDG base units, default 0; DEC-096), `SEED_AMOUNT` (default
///      `MIN_FIRST_DEPOSIT`).
/// @dev Operating Cash is out of the MVP (ruling 2026-10-02): nothing spends it, and native Operating Cash (DEC-130,
///      DEC-144) and the gas refund come after the buildathon, so a fund locks no value there by default. The hub has
///      no Operating Cash entry in the Mandate, so its floor and top-up are 0 as well.
/// @dev DEC-127: the manager seeds the fund in the creation transaction; on Arbitrum the script approves the factory
///      for `SEED_AMOUNT` USDC first, so `MANAGER` must hold it.
contract CreateFund is Script, FactoryDeployment, FundMandate {
    /// @notice Ruling 2026-09-29: Robinhood report lifetime 1,587 s plus one block, rounded up.
    uint32 internal constant ROBINHOOD_MAX_REPORT_AGE = 1588;

    function run() external {
        FundFactory factory = FundFactory(vm.envAddress("FUND_FACTORY"));
        address manager = vm.envAddress("MANAGER");
        FundPlan memory plan = _plan(manager);

        if (block.chainid == ARBITRUM) {
            uint256 n = factory.nextCreationNumber();
            Mandate memory m = _buildMandate(factory, factory.fundIdOf(ARBITRUM, n, manager), plan);
            IFundFactory.HubParams memory p = _hubParams(n, plan, _coreVaultCreationCode(_libraryAddresses(true)));
            vm.startBroadcast(manager);
            IERC20(ARB_USDC).approve(address(factory), p.seedAmount);
            IFundFactory.FundAddresses memory a = factory.createFund(m, p);
            vm.stopBroadcast();
            console.log("CREATION_NUMBER", n);
            console.log("seed (USDC base units)", p.seedAmount);
            console.log("MANDATE_HASH");
            console.logBytes32(MandateLib.hash(m));
            console.log("fund id");
            console.logBytes32(a.fundId);
            console.log("Core Vault", a.coreVault);
            console.log("ShareToken", a.shareToken);
            console.log("ManagerFeeVault", a.managerFeeVault);
            console.log("ValueReportReceiver", a.valueReportReceiver);
            console.log("hub Spoke Vault", a.chains[0].spokeVault);
            console.log("hub Uniswap V3 swap adapter", a.chains[0].uniswapV3SwapAdapter);
            console.log(
                "Robinhood Spoke Vault (predicted)",
                m.spokes.length != 0 ? address(uint160(uint256(m.spokes[0].spokeVault))) : address(0)
            );
        } else if (block.chainid == ROBINHOOD) {
            uint256 n = vm.envUint("CREATION_NUMBER");
            Mandate memory m = _buildMandate(factory, factory.fundIdOf(ARBITRUM, n, manager), plan);
            IFundFactory.SpokeParams memory p = _spokeParams(vm.envBytes32("MANDATE_HASH"), plan);
            vm.startBroadcast(manager);
            IFundFactory.ChainAddresses memory c = factory.createSpoke(n, m, p);
            vm.stopBroadcast();
            console.log("Spoke Vault", c.spokeVault);
            console.log("Uniswap V4 adapter", c.uniswapV4Adapter);
            console.log("Uniswap V3 swap adapter", c.uniswapV3SwapAdapter);
            console.log("Across bridge adapter", c.acrossBridgeAdapter);
        } else {
            revert UnsupportedChain(block.chainid);
        }
    }

    function _plan(address manager) internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = ARBITRUM;
        plan.hubWormholeChainId = WORMHOLE_ARBITRUM;
        plan.usdc = ARB_USDC;
        plan.hubPool = PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), 500, 10, IHooks(address(0)));
        plan.hubAaveAsset = ARB_USDC;
        plan.spokeChainId = ROBINHOOD;
        plan.spokeWormholeChainId = WORMHOLE_ROBINHOOD;
        plan.spokeToken = RH_USDG;
        plan.spokePool = PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, 10, IHooks(address(0)));
        plan.spokeCap = vm.envOr("SPOKE_CAP", uint256(10_000e6));
        plan.maxReportAge = ROBINHOOD_MAX_REPORT_AGE;
        plan.spokeOperatingCashFloor = vm.envOr("SPOKE_OPERATING_CASH_FLOOR", uint256(0));
        plan.spokeOperatingCashTopUp = vm.envOr("SPOKE_OPERATING_CASH_TOP_UP", uint256(0));
        plan.minFirstDeposit = vm.envOr("MIN_FIRST_DEPOSIT", uint256(100e6));
        plan.performanceFeeBps = SafeCast.toUint16(vm.envOr("PERFORMANCE_FEE_BPS", uint256(2000)));
        plan.managementFeeBps = SafeCast.toUint16(vm.envOr("MANAGEMENT_FEE_BPS", uint256(0)));
        plan.seedAmount = vm.envOr("SEED_AMOUNT", plan.minFirstDeposit);
    }
}
