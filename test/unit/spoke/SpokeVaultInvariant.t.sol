// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockSpokeToken} from "../../mocks/spoke/MockSpokeToken.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockAcrossSpokePool} from "../../mocks/spoke/MockAcrossSpokePool.sol";

/// @notice Drives a spoke-chain Spoke Vault through random sequences of every verb, donations included. Every action
///         bounds its inputs to what the ledger allows, so no action reverts (`fail_on_revert = true`).
contract SpokeVaultHandler is Test {
    uint256 internal constant HUB = 42_161;
    bytes32 internal constant FUND_ID = keccak256("fund-1");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    SpokeVault internal vault;
    MockSpokeToken internal usdg;
    MockSpokeToken internal weth;
    MockPositionAdapter internal adapter;
    MockAcrossSpokePool internal pool;
    address internal manager;

    uint256 internal nonce;
    bytes32[] internal sent;
    mapping(bytes32 => bool) internal refunded;

    uint256 public lastIncomeUsdg;
    uint256 public lastIncomeWeth;
    bool public incomeRegressed;
    uint64 public lastSequence;
    bool public sequenceViolated;

    constructor(
        SpokeVault vault_,
        MockSpokeToken usdg_,
        MockSpokeToken weth_,
        MockPositionAdapter adapter_,
        MockAcrossSpokePool pool_,
        address manager_
    ) {
        vault = vault_;
        usdg = usdg_;
        weth = weth_;
        adapter = adapter_;
        pool = pool_;
        manager = manager_;
    }

    // ---- actions ----

    function arrive(uint256 amount, bool income) external {
        amount = bound(amount, 1, 1e12);
        usdg.mint(address(pool), amount);
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        pool.fill(address(vault), address(usdg), amount, TransitMessage.encode(FUND_ID, HUB, bytes32(++nonce), kind));
        _check();
    }

    function open(uint256 amount0, uint256 amount1, uint256 useBps) external {
        amount0 = bound(amount0, 0, vault.unallocatedBalance(address(weth)));
        amount1 = bound(amount1, 0, _usdgAfterTopUp());
        if (amount0 == 0 && amount1 == 0) return;
        adapter.setUseBps(bound(useBps, 0, 10_000));
        vm.prank(manager);
        vault.openPosition(address(adapter), SPOKE_POOL, amount0, amount1, "");
        _check();
    }

    function increase(uint256 index, uint256 amount0, uint256 amount1) external {
        (bool found, bytes32 key) = _position(index);
        if (!found) return;
        amount0 = bound(amount0, 0, vault.unallocatedBalance(address(weth)));
        amount1 = bound(amount1, 0, _usdgAfterTopUp());
        if (amount0 == 0 && amount1 == 0) return;
        vm.prank(manager);
        vault.increasePosition(address(adapter), key, amount0, amount1, "");
        _check();
    }

    function decrease(uint256 index, uint256 bps) external {
        (bool found, bytes32 key) = _position(index);
        if (!found) return;
        vm.prank(manager);
        vault.decreasePosition(address(adapter), key, abi.encode(bound(bps, 0, 10_000)));
        _check();
    }

    function close(uint256 index) external {
        (bool found, bytes32 key) = _position(index);
        if (!found) return;
        vm.prank(manager);
        vault.closePosition(address(adapter), key, "");
        _check();
    }

    function collect(uint256 index) external {
        (bool found, bytes32 key) = _position(index);
        if (!found) return;
        vm.prank(manager);
        vault.collectIncome(address(adapter), key);
        _check();
    }

    function earnIncome(uint256 index, uint256 amount0, uint256 amount1) external {
        (bool found, bytes32 key) = _position(index);
        if (!found) return;
        amount0 = bound(amount0, 0, 1e18);
        amount1 = bound(amount1, 0, 1e12);
        weth.mint(address(adapter), amount0);
        usdg.mint(address(adapter), amount1);
        adapter.earnIncome(key, amount0, amount1);
        _check();
    }

    function swap(uint256 amount, bool usdgIn) external {
        address tokenIn = usdgIn ? address(usdg) : address(weth);
        MockSpokeToken tokenOut = usdgIn ? weth : usdg;
        uint256 available = usdgIn ? _usdgAfterTopUp() : vault.unallocatedBalance(address(weth));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        tokenOut.mint(address(adapter), amount);
        adapter.addLiquidity(address(tokenOut), amount);
        vm.prank(manager);
        vault.swapExactInput(address(adapter), SPOKE_POOL, tokenIn, amount, 0, "");
        _check();
    }

    function donate(uint256 amount, bool toUsdg) external {
        amount = bound(amount, 1, 1e18);
        (toUsdg ? usdg : weth).mint(address(vault), amount);
        _check();
    }

    function sweep(bool usdgToken) external {
        vault.sweepExcess(usdgToken ? address(usdg) : address(weth));
        _check();
    }

    function sendHome(uint256 amount) external {
        uint256 available = _usdgAfterTopUp();
        if (available < 10_000) return;
        amount = bound(amount, 10_000, available);
        uint256 outputAmount = amount - amount * 50 / 10_000;
        vm.prank(manager);
        bytes32 id = vault.sendToHub(
            amount, TransferKind.Principal, 0, BridgeQuote(outputAmount, uint32(block.timestamp), 0, address(0))
        );
        sent.push(id);
        _check();
    }

    function refund(uint256 index) external {
        if (sent.length == 0) return;
        bytes32 id = sent[index % sent.length];
        if (refunded[id]) return;
        Transit memory t = vault.hubBoundTransit(id);
        if (block.timestamp <= t.fillDeadline) vm.warp(uint256(t.fillDeadline) + 1);
        refunded[id] = true;
        pool.refund(t.escrow, address(usdg), t.amountSent);
        vault.recognizeRefund(id);
        _check();
    }

    function report() external {
        (uint64 sequence,) = vault.report();
        if (sequence != lastSequence + 1) sequenceViolated = true;
        lastSequence = sequence;
        _check();
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }

    // ---- helpers ----

    function _position(uint256 index) internal view returns (bool found, bytes32 key) {
        ISpokeVault.PositionRef[] memory p = vault.positions();
        if (p.length == 0) return (false, bytes32(0));
        return (true, p[index % p.length].positionKey);
    }

    /// @dev DEC-096: what Unallocated Balance of the base token holds after the top-up the next operation runs.
    function _usdgAfterTopUp() internal view returns (uint256 available) {
        available = vault.unallocatedBalance(address(usdg));
        if (vault.operatingCash() < vault.operatingCashFloor()) {
            uint256 topUp = vault.operatingCashTopUp();
            available -= topUp < available ? topUp : available;
        }
    }

    function _check() internal {
        uint256 incomeUsdg = vault.cumulativeIncome(address(usdg));
        uint256 incomeWeth = vault.cumulativeIncome(address(weth));
        if (incomeUsdg < lastIncomeUsdg || incomeWeth < lastIncomeWeth) incomeRegressed = true;
        lastIncomeUsdg = incomeUsdg;
        lastIncomeWeth = incomeWeth;
    }
}

/// @notice Fitness functions of the Spoke Vault: DEC-080 ledger never above balance, Q60 cumulative income never
///         decreases, DEC-093 report sequence strictly increases.
contract SpokeVaultInvariantTest is SpokeVaultTestBase {
    SpokeVaultHandler internal handler;

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
        spokeUni.setSwapRate(1, 1);
        handler = new SpokeVaultHandler(vault, usdg, weth, spokeUni, spokePool, manager);
        targetContract(address(handler));
    }

    function invariant_DEC080_ledgerNeverExceedsBalance() public view {
        assertLe(_ledgerTotal(address(usdg)), usdg.balanceOf(address(vault)));
        assertLe(_ledgerTotal(address(weth)), weth.balanceOf(address(vault)));
    }

    function invariant_Q60_cumulativeIncomeNeverDecreases() public view {
        assertFalse(handler.incomeRegressed());
        assertGe(vault.cumulativeIncome(address(usdg)), handler.lastIncomeUsdg());
        assertGe(vault.cumulativeIncome(address(weth)), handler.lastIncomeWeth());
    }

    function invariant_DEC093_reportSequenceStrictlyIncreases() public view {
        assertFalse(handler.sequenceViolated());
        assertEq(vault.reportSequence(), handler.lastSequence());
    }
}
