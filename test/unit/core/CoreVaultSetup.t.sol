// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ExpensePayer} from "../../../src/interfaces/FundTypes.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {Mandate, MandateLib, OperatingCashConfig} from "../../../src/mandate/Mandate.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Deploys a Core Vault at a CREATE2 address, as the Fund Factory will (DEC-053, DEC-054). The init code
///         comes in calldata: a factory that embeds CoreVault's creation code (`new CoreVault{salt: ...}`) would itself
///         exceed the 24,576-byte runtime limit.
contract CoreVaultCreate2Deployer {
    error DeployFailed();

    function deploy(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (deployed == address(0)) revert DeployFailed();
    }
}

contract CoreVaultSetupTest is CoreVaultFixture {
    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC053_storesMandateAndWiring() public view {
        Mandate memory m = vault.mandate();
        assertEq(keccak256(abi.encode(m)), keccak256(abi.encode(_mandate(2000))));
        assertEq(vault.mandateHash(), MandateLib.hash(_mandate(2000)));
        assertEq(vault.fundId(), FUND_ID);
        assertEq(vault.manager(), manager);
        assertEq(vault.usdc(), address(usdc));
        assertEq(vault.hubSpokeVault(), address(hubVault));
        assertEq(vault.reportReceiver(), address(receiver));
        assertEq(vault.managerRegistry(), address(registry));
        assertEq(vault.priceSource(), address(prices));
        assertEq(vault.acrossSpokePool(), address(pool));
        assertEq(vault.protocolRecipient(), protocol);
        assertEq(vault.excessRecipient(), excess);
        assertEq(vault.flowFeeBps(), 25);
        assertEq(vault.payoutFeeBps(), 200);
        assertEq(vault.standardPayoutTerm(), 72 hours, "DEC-154: a protocol constant");
        assertEq(vault.performanceFeeBps(), 2000);
        assertEq(vault.managementFeeBps(), 0);
        assertTrue(vault.incomeToken(0, address(usdc)).registered);
        assertTrue(vault.incomeToken(0, address(weth)).registered);
    }

    function test_Q59_deploysAndOwnsItsShareToken() public view {
        ShareToken token = ShareToken(vault.shareToken());
        assertEq(token.name(), "Pool Party Fund 1");
        assertEq(token.symbol(), "PP-1");
        assertEq(token.coreVault(), address(vault));
        assertEq(token.decimals(), 18);
    }

    function test_DEC053_deployableAtCreate2Address() public {
        CoreVaultCreate2Deployer factory = new CoreVaultCreate2Deployer();
        bytes32 salt = keccak256("fund-2");
        Mandate memory m = _mandate(2000);
        CoreVaultConfig memory c = _config(25);
        bytes memory initCode = abi.encodePacked(type(CoreVault).creationCode, abi.encode(m, c));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(factory));
        assertEq(factory.deploy(salt, initCode), predicted);
        assertEq(CoreVault(predicted).manager(), manager, "no msg.sender assumption");
    }

    function test_DEC011_onlyOnHubChain() public {
        vm.chainId(SPOKE);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotOnHubChain.selector, SPOKE, HUB));
        new CoreVault(_mandate(2000), _config(25));
    }

    function test_DEC110_flowFeeCapInConstructor() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.FlowFeeAboveCap.selector, 101));
        new CoreVault(_mandate(2000), _config(101));
    }

    function test_DEC011_usdcMustMatchMandate() public {
        CoreVaultConfig memory c = _config(25);
        c.usdc = address(weth);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UsdcMismatch.selector, address(weth), address(usdc)));
        new CoreVault(_mandate(2000), c);
    }

    function test_DEC053_zeroWiringRefused() public {
        CoreVaultConfig memory c = _config(25);
        c.excessRecipient = address(0);
        vm.expectRevert(ICoreVault.ZeroAddress.selector);
        new CoreVault(_mandate(2000), c);
    }

    /// @dev DEC-114, DEC-115: a management fee up to 500 bps a year is accepted; above, the Mandate is refused.
    function test_DEC115_mandateValidatedAtConstruction() public {
        Mandate memory m = _mandate(2000);
        m.managementFeeBps = 501;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 501, 500));
        new CoreVault(m, _config(25));
    }

    function test_DEC087_bridgeTargetPinnedAtCreation() public {
        MockBridgeAdapter unset = new MockBridgeAdapter(address(0));
        Mandate memory m = _mandate(2000);
        m.bridgeAdapters[0].adapter = address(unset);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeTargetUnset.selector, address(unset)));
        new CoreVault(m, _config(25));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Operating Cash (DEC-041, DEC-096, DEC-100)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC096_initialParametersFromMandate() public {
        Mandate memory m = _mandate(2000);
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        _deploy(m, _config(25));
        assertEq(vault.operatingCashFloor(), 1e6);
        assertEq(vault.operatingCashTopUp(), 3e6);
    }

    function test_DEC096_parametersManagerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, address(this)));
        vault.setOperatingCashParameters(1e6, 3e6);
        vm.expectEmit(address(vault));
        emit ICoreVault.OperatingCashParametersSet(1e6, 3e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
    }

    function test_DEC096_belowFloorTopsUpFromShareAssetsOnNextOperation() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
        uint256 idleBefore = vault.idle();
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 100e6);
        vm.expectEmit(address(vault));
        emit ICoreVault.OperatingCashToppedUp(3e6, 3e6);
        vm.expectEmit(address(vault));
        emit ICoreVault.OperatingExpensePaid(
            HUB, address(0), keccak256("OPERATING_CASH_TOP_UP"), 3e6, ExpensePayer.ShareAssets
        );
        (uint256 minted, uint256 charged) = vault.deposit(100e6, 0);
        vm.stopPrank();
        assertEq(vault.operatingCash(), 3e6);
        // DEC-100: the top-up lowers Share Price before the entrant is priced (994 over 997 shares).
        uint256 price = uint256(994e6) * 1e36 / 997e18;
        assertEq(minted, ShareMath.sharesForDeposit(99.75e6, price));
        assertEq(vault.idle(), idleBefore - 3e6 + charged - 0.25e6);
        // Operating Cash is back at the floor: the next operation does not top up again.
        _deposit(bob, 100e6);
        assertEq(vault.operatingCash(), 3e6);
    }

    function test_DEC041_routineTopUpIsNotInsufficientCash() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
        vm.recordLogs();
        _deposit(bob, 100e6);
        assertEq(vault.operatingCash(), 3e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ICoreVault.OperatingCashInsufficient.selector, "routine top-up");
        }
    }

    function test_DEC041_shortTopUpIsInsufficientCash() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(996e6 + SEED_IDLE); // Free Idle 1
        vm.prank(manager);
        vault.setOperatingCashParameters(5e6, 10e6);
        _request(alice, 1e6, ICoreVaultPayouts.PayoutMode.Standard); // reserves the last unit
        vm.warp(block.timestamp + 72 hours);
        // Operating Cash 0, floor 5, top-up 10, Free Idle 0: cash cannot be restored.
        vm.expectEmit(address(vault));
        emit ICoreVault.OperatingCashInsufficient(0, 5e6, 0);
        _claim(alice);
        assertEq(vault.operatingCash(), 0);
    }

    function test_DEC072_topUpNeverTakesThePayoutReserve() public {
        _deposit(alice, 1000e6);
        _request(alice, 5000e6, ICoreVaultPayouts.PayoutMode.Standard); // reserves all Idle
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 1, 0));
        vault.allocateToHubSpokeVault(1);
        assertEq(vault.operatingCash(), 0);
        assertLe(vault.payoutReserve(), vault.idle());
    }

    /// @dev DEC-144: the top-up is a logic of its own; the Payout Fee stays in Idle.
    function test_DEC144_payoutFeeStaysOutOfOperatingCash() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
        _request(alice, 100e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // Topped up 3 first (below floor); the 2% Payout Fee of the amount paid out stays in Idle.
        assertEq(r.payoutFee, r.usdcGross * 200 / 10_000);
        assertEq(vault.operatingCash(), 3e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hub allocation (DEC-017, DEC-072)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC017_allocateMovesFreeIdleToHubSpokeVault() public {
        _deposit(alice, 1000e6);
        uint256 assets = vault.shareAssets();
        vm.expectEmit(address(vault));
        emit ICoreVault.AllocatedToHubSpokeVault(400e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(400e6);
        assertEq(vault.idle(), SEED_IDLE + 597e6);
        assertEq(usdc.balanceOf(address(hubVault)), 400e6);
        assertEq(hubVault.unallocatedUsdc(), 400e6);
        assertEq(vault.shareAssets(), assets);
        hubVault.returnToCore(100e6);
        assertEq(vault.idle(), SEED_IDLE + 697e6);
        assertEq(vault.shareAssets(), assets);
    }

    function test_DEC080_returnToIdleMustBeBacked() public {
        vm.prank(address(hubVault));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnbackedCredit.selector, address(usdc), 1e6, 0));
        vault.returnToIdle(1e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotHubSpokeVault.selector, address(this)));
        vault.returnToIdle(1e6);
    }

    function test_DEC098_grossAssetsAddsSpokeCollectedIncomeAndOperatingCash() public {
        _deposit(alice, 1000e6);
        uint256 before = vault.grossAssets();
        ReportCodec.Report memory r = _spokeReport(0, 0);
        r.collectedIncome = new ReportCodec.TokenAmount[](2);
        r.collectedIncome[0] = ReportCodec.TokenAmount(address(usdg), 30e6);
        r.collectedIncome[1] = ReportCodec.TokenAmount(address(spokeWeth), 0.01e18); // 25 USDC
        r.operatingCash = 5e6;
        _deliver(r);
        assertEq(vault.shareAssets(), SEED_IDLE + 997e6, "outside Share Assets");
        assertEq(vault.grossAssets(), before + 30e6 + 25e6 + 5e6, "inside Gross Assets");
    }

    function test_DEC098_grossAssetsAddsCashAndIncome() public {
        _deposit(alice, 1000e6);
        _hubIncomeCollected(address(usdc), 100e6); // 80 net to holders at 20% performance
        hubVault.setPositionIncome(7e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 2e6);
        _request(alice, 10e6, ICoreVaultPayouts.PayoutMode.Instant);
        _claim(alice);
        assertEq(vault.grossAssets(), vault.shareAssets() + vault.operatingCash() + 80e6 + 7e6);
    }
}
