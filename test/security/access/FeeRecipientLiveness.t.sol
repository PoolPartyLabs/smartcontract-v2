// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @notice The hub USDC with the one behaviour of the live token that matters here: Circle's blacklist. FiatToken
///         (USDC on Arbitrum One) rejects every transfer whose sender or recipient is blacklisted.
contract BlacklistableUsdc is MockToken {
    error Blacklisted(address account);

    mapping(address => bool) public blacklisted;

    constructor() MockToken("USDC", 6) {}

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function unblacklist(address account) external {
        blacklisted[account] = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}

/// @title Regression (security review S-12): a Protocol Recipient or ManagerFeeVault that cannot receive USDC no
///        longer freezes deposits, payouts or income collection
/// @notice Was PoCs `test_POC_blacklistedProtocolRecipientBricksEveryDepositAndPayout` and
///         `test_POC_blacklistedFeeAddressBricksIncomeCollection` (medium, access lens): the flow fee, the protocol
///         slice and the manager portion were pushed to immutable third-party addresses inside the Shareholder's own
///         transaction, so a USDC blocklist entry on the fee wallet (or on the fund's ManagerFeeVault) made every
///         deposit, claim and income hand-off revert for good.
/// @notice FIX (S-12, `CoreVaultLogic.payFee`): a fee transfer that fails is booked as owed (`owedFees`, outside every
///         value base, inside the ledger) and paid later by the permissionless `claimOwedFees`. The tests assert the
///         freeze now FAILS: deposits, both payout modes and income collection go through, and the owed fee is paid
///         once the recipient can receive again.
contract FeeRecipientLivenessPoC is AccessFundFixture {
    BlacklistableUsdc internal fiatUsdc;
    CoreVault internal core;
    SpokeVault internal hub;
    address internal adapter;
    address internal swapAdapter;
    bytes32 internal poolId;

    function _newUsdc() internal override returns (MockToken) {
        fiatUsdc = new BlacklistableUsdc();
        return fiatUsdc;
    }

    function setUp() public override {
        super.setUp();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        core = CoreVault(a.coreVault);
        hub = _hubVault(a);
        adapter = a.chains[0].uniswapV4Adapter;
        swapAdapter = a.chains[0].uniswapV3SwapAdapter;
        poolId = _hubPoolId();
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        assertEq(core.idle(), SEED_IDLE + 997_500e6, "both deposits sit in Idle, net of the flow fee");
    }

    function test_SEC_S12_blacklistedProtocolRecipientNoLongerBlocksDepositsOrPayouts() public {
        // Control: with the recipient reachable, a claim pays out.
        uint256 snapshot = vm.snapshotState();
        uint256 control = _exitAll(core, alice, ICoreVaultPayouts.PayoutMode.Instant);
        vm.revertToState(snapshot);

        fiatUsdc.blacklist(recipient);
        uint256 recipientBefore = _balance(usdc, recipient);

        // A new shareholder enters; the flow fee is owed instead of transferred.
        usdc.mint(stranger, 1000e6);
        vm.startPrank(stranger);
        usdc.approve(address(core), 1000e6);
        core.deposit(1000e6, 0);
        vm.stopPrank();
        assertEq(core.owedFees(address(usdc), recipient), 2.5e6, "S-12: the deposit's flow fee is owed");

        // Alice exits in full, exactly as in the control; Bob's Standard Payout completes after the term.
        assertEq(
            _exitAll(core, alice, ICoreVaultPayouts.PayoutMode.Instant),
            control,
            "S-12: Alice is paid as in the control"
        );
        uint256 bobPaid = _exitAll(core, bob, ICoreVaultPayouts.PayoutMode.Standard);
        assertGt(bobPaid, 398_000e6, "S-12: Bob's Standard Payout completes");
        assertEq(_balance(usdc, recipient), recipientBefore, "nothing reached the blacklisted recipient");
        uint256 owed = core.owedFees(address(usdc), recipient);
        assertGt(owed, 2.5e6);
        assertEq(core.sweepExcess(address(usdc)), 0, "S-12: owed fees are ledger value, never swept");

        // While the recipient is blacklisted the claim reverts; once it is not, anyone pays it.
        vm.expectRevert(abi.encodeWithSelector(BlacklistableUsdc.Blacklisted.selector, recipient));
        core.claimOwedFees(address(usdc), recipient);
        fiatUsdc.unblacklist(recipient);
        vm.prank(stranger);
        assertEq(core.claimOwedFees(address(usdc), recipient), owed);
        assertEq(_balance(usdc, recipient), recipientBefore + owed);
        assertEq(core.owedFees(address(usdc), recipient), 0);
    }

    function test_SEC_S12_blacklistedFeeAddressNoLongerBlocksIncomeCollection() public {
        _v3WethUsdcPool();
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(400_000e6);
        // DEC-136: the manager's swap runs through the fund's swap adapter (0.01% V3 pool at price 1).
        uint256 wethOut = hub.swap(swapAdapter, address(usdc), address(weth), 200_000e6, 0, "");
        (bytes32 positionKey,,) =
            hub.openPosition(adapter, poolId, wethOut, wethOut, _openParams(uint128(wethOut), uint128(wethOut)));
        v4.accrueFees(poolId, 1 << 100, 1 << 100);
        hub.collectIncome(adapter, positionKey);
        vm.stopPrank();
        uint256 collected = hub.collectedIncome(address(usdc));
        assertGt(collected, 0, "USDC fees wait in the hub Spoke Vault");

        address feeVault = core.managerFeeVault();
        fiatUsdc.blacklist(feeVault);

        // The collection goes through (DEC-161, DEC-172); the manager's portion is owed to its fee vault.
        core.requestIncomeWithdrawal(0);
        assertEq(hub.collectedIncome(address(usdc)), 0);
        assertGt(core.incomeCollection().heldDollars, 0, "S-12: the holders' share was converted");
        uint256 owed = core.owedFees(address(usdc), feeVault);
        assertGt(owed, 0, "S-12: the manager's portion is owed, not lost");
        assertEq(core.performanceFeeBps(), 2000, "no need to give up the fee");

        fiatUsdc.unblacklist(feeVault);
        core.claimOwedFees(address(usdc), feeVault);
        assertEq(_balance(usdc, feeVault), owed);
    }

    /// @dev A Payout Request for everything `who` holds, claimed at once (after the term for Standard); returns the
    ///      USDC received.
    function _exitAll(CoreVault core_, address who, ICoreVault.PayoutMode mode) internal returns (uint256 paid) {
        uint256 before = _balance(usdc, who);
        vm.startPrank(who);
        core_.requestPayout(1_000_000e6, mode, 0); // an Instant request is its own claim (DEC-120 item 1)
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) {
            vm.warp(block.timestamp + core_.standardPayoutTerm());
            core_.claimPayout(0);
        }
        vm.stopPrank();
        paid = _balance(usdc, who) - before;
    }
}
