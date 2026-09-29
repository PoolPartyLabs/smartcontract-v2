// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
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
///      WETH/USDG 0.05% on Uniswap V4 on Robinhood. The rule values are the manager's (DEC-053) and come from the
///      environment with the defaults below.
/// @dev Environment: `FUND_FACTORY`, `MANAGER` (the broadcaster; DEC-001: the creator is the Manager); on Robinhood also
///      `CREATION_NUMBER` and `MANDATE_HASH` from the hub's `FundCreated` event. Optional: `SPOKE_CAP`,
///      `MIN_FIRST_DEPOSIT`, `PERFORMANCE_FEE_BPS`, `MAX_BRIDGE_FEE_BPS`.
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
            IFundFactory.HubParams memory p =
                _hubParams(n, plan, _coreVaultCreationCode(factory.wiring().coreVaultLogic));
            vm.startBroadcast(manager);
            IFundFactory.FundAddresses memory a = factory.createFund(m, p);
            vm.stopBroadcast();
            console.log("CREATION_NUMBER", n);
            console.log("MANDATE_HASH");
            console.logBytes32(MandateLib.hash(m));
            console.log("fund id");
            console.logBytes32(a.fundId);
            console.log("Core Vault", a.coreVault);
            console.log("ShareToken", a.shareToken);
            console.log("ManagerFeeVault", a.managerFeeVault);
            console.log("ValueReportReceiver", a.valueReportReceiver);
            console.log("hub Spoke Vault", a.chains[0].spokeVault);
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
            console.log("Across bridge adapter", c.acrossBridgeAdapter);
        } else {
            revert UnsupportedChain(block.chainid);
        }
    }

    function _plan(address manager) internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = ARBITRUM;
        plan.usdc = ARB_USDC;
        plan.hubPool = PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), 500, 10, IHooks(address(0)));
        plan.hubAaveAsset = ARB_USDC;
        plan.spokeChainId = ROBINHOOD;
        plan.spokeWormholeChainId = WORMHOLE_ROBINHOOD;
        plan.spokeToken = RH_USDG;
        plan.spokePool = PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, 10, IHooks(address(0)));
        plan.spokeCap = vm.envOr("SPOKE_CAP", uint256(10_000e6));
        plan.maxReportAge = ROBINHOOD_MAX_REPORT_AGE;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = vm.envOr("MIN_FIRST_DEPOSIT", uint256(100e6));
        plan.performanceFeeBps = SafeCast.toUint16(vm.envOr("PERFORMANCE_FEE_BPS", uint256(2000)));
        plan.maxBridgeFeeBps = SafeCast.toUint16(vm.envOr("MAX_BRIDGE_FEE_BPS", uint256(50)));
    }
}
