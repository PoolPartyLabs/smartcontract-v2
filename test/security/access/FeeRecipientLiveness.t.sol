// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
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

    function _update(address from, address to, uint256 value) internal override {
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}

/// @title PoC: every deposit, payout and income collection pushes USDC to one immutable third-party address; when
///        that address cannot receive USDC, no shareholder of any fund can enter or exit
/// @notice TRUST BOUNDARY. The Protocol Recipient is a factory immutable copied into every fund (FundFactory.sol:109,
///         CoreVaultBase.sol:90) and the fund pays it by push, inside the shareholder's own transaction:
///         - `deposit` pulls the flow fee straight into it (CoreVault.sol:86);
///         - `claimPayout` transfers the flow fee to it before paying the claimant (CoreVault.sol:259), for every
///           claim of at least 400 USDC base units, i.e. every claim (a request is at least one share, DEC-035);
///         - `receiveCollectedIncome`, a matched spoke-to-hub Income arrival and `onReportAccepted` (through
///           `_matchReturnLeg`) transfer the protocol slice to it and the manager portion to the fund's
///           `ManagerFeeVault` (CoreVaultLogic.sol:395-396).
///         USDC is FiatToken: a transfer to (or from) a blacklisted address reverts. The addresses are immutable, the
///         contracts have no owner and no setter (DEC-022, DEC-058), and the fee is not bounded to zero anywhere. So
///         the moment Circle blacklists the Protocol Recipient (a legal order against Pool Party Labs, a compromised
///         fee wallet added to a sanctions list, or an operator that wires a contract which reverts), every fund
///         created by that factory stops at once: no deposit, no payout, no income collection, and no report can be
///         accepted while it lists an Income transfer that already arrived. Only `withdrawIncome` keeps working.
/// @notice IMPACT. Permanent DoS of deposits and payouts of every fund on the hub, with the customers' USDC intact
///         and unreachable: the flow fee (0.25%) blocks the 99.75% the shareholder is owed. The rubric calls a
///         permanent DoS of payouts high; the trigger is outside the protocol's code, so this is rated medium, but it
///         is a single point of failure the design created for a 25 bps fee, with no remedy once it happens.
/// @notice FIX. Pull, never push, to third parties in a shareholder's path: accrue the flow fee, the protocol slice
///         and the manager portion in per-recipient buckets inside the Core Vault (outside every value base, like
///         `unmatchedArrivals`) and let each recipient `claimFees(token)`. Alternatively wrap each fee transfer in a
///         try/catch that books the fee for a later pull when the transfer fails.
contract FeeRecipientLivenessPoC is AccessFundFixture {
    BlacklistableUsdc internal fiatUsdc;
    CoreVault internal core;
    SpokeVault internal hub;
    address internal adapter;
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
        poolId = _hubPoolId();
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        assertEq(core.idle(), 997_500e6, "both deposits sit in Idle, net of the flow fee");
    }

    function test_POC_blacklistedProtocolRecipientBricksEveryDepositAndPayout() public {
        // Control: with the recipient reachable, a claim pays out.
        uint256 snapshot = vm.snapshotState();
        assertEq(
            _exitAll(core, alice, ICoreVault.PayoutMode.Instant),
            585_033_750_000,
            "control: Alice exits in full, less the Payout Fee and the flow fee"
        );
        vm.revertToState(snapshot);

        // Circle blacklists the Protocol Recipient. Nothing in the fund changes: same code, same balances.
        fiatUsdc.blacklist(recipient);
        assertEq(core.idle(), 997_500e6);
        assertEq(_balance(usdc, address(core)), 997_500e6, "the customers' USDC is all there");

        // No new shareholder can enter: the flow fee cannot reach the recipient.
        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(core), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(BlacklistableUsdc.Blacklisted.selector, recipient));
        core.deposit(1_000e6, 0);
        vm.stopPrank();

        // No shareholder can leave: Instant and Standard alike, for any amount, in full or in part.
        vm.startPrank(alice);
        core.requestPayout(100_000e6, ICoreVault.PayoutMode.Instant);
        vm.expectRevert(abi.encodeWithSelector(BlacklistableUsdc.Blacklisted.selector, recipient));
        core.claimPayout("");
        vm.stopPrank();

        vm.startPrank(bob);
        core.requestPayout(1_000e6, ICoreVault.PayoutMode.Standard);
        vm.stopPrank();
        vm.warp(block.timestamp + core.standardPayoutTerm());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BlacklistableUsdc.Blacklisted.selector, recipient));
        core.claimPayout("");

        // The requests are now open for good: not cancellable (DEC-024), not claimable, and a second one is refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.PayoutRequestAlreadyOpen.selector, alice));
        core.requestPayout(1e6, ICoreVault.PayoutMode.Standard);

        // Nobody can help: the recipient is an immutable, there is no owner, and the fee never rounds to zero for a
        // claim of at least one share.
        assertEq(core.protocolRecipient(), recipient);
        assertEq(core.flowFeeBps(), 25);
        assertEq(_shares(core, alice) + _shares(core, bob), 997_500e18, "every share is still outstanding");
    }

    function test_POC_blacklistedFeeAddressBricksIncomeCollection() public {
        // The manager earns fees in the Mandate's hub pool and collects them into the hub Spoke Vault's bucket.
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(400_000e6);
        hub.swapExactInput(adapter, poolId, address(usdc), 200_000e6, 0, "");
        (bytes32 positionKey,,) = hub.openPosition(adapter, poolId, 200_000e6, 200_000e6, _openParams(200_000e6, 200_000e6));
        v4.accrueFees(poolId, 1 << 100, 1 << 100);
        hub.collectIncome(adapter, positionKey);
        vm.stopPrank();
        uint256 collected = hub.collectedIncome(address(usdc));
        assertGt(collected, 0, "USDC fees wait in the hub Spoke Vault");

        // Circle blacklists the fund's ManagerFeeVault (or the Protocol Recipient: either leg is enough).
        fiatUsdc.blacklist(core.managerFeeVault());

        // The permissionless hand-off to the Core Vault reverts, so the income can never reach the shareholders'
        // accumulator (the split is a push in the same call, CoreVaultLogic.sol:395-396).
        vm.expectRevert(abi.encodeWithSelector(BlacklistableUsdc.Blacklisted.selector, core.managerFeeVault()));
        hub.forwardIncomeToCoreVault(address(usdc));
        assertEq(hub.collectedIncome(address(usdc)), collected, "the fees are stuck in the hub Spoke Vault");
        assertEq(core.collectedIncome(address(usdc)), 0, "nothing ever reaches the holders");

        // The only way out is the manager giving up its whole fee for the life of the fund (a zero fee pushes
        // nothing; DEC-110 makes the decrease irreversible). With the Protocol Recipient blacklisted instead, not even
        // that helps: the flow fee still blocks every deposit and payout.
        vm.prank(manager);
        core.decreaseManagerFee(0, 0);
        hub.forwardIncomeToCoreVault(address(usdc));
        assertEq(core.performanceFeeBps(), 0, "income flows again only at a fee of zero, for ever");
    }

    /// @dev A Payout Request for everything `who` holds, claimed at once (after the term for Standard); returns the
    ///      USDC received.
    function _exitAll(CoreVault core_, address who, ICoreVault.PayoutMode mode) internal returns (uint256 paid) {
        uint256 before = _balance(usdc, who);
        vm.startPrank(who);
        core_.requestPayout(1_000_000e6, mode);
        if (mode == ICoreVault.PayoutMode.Standard) vm.warp(block.timestamp + core_.standardPayoutTerm());
        core_.claimPayout("");
        vm.stopPrank();
        paid = _balance(usdc, who) - before;
    }
}
