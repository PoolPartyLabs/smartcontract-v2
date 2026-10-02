// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";
import {IAcrossSpokePoolLive} from "../../mocks/across/IAcrossSpokePoolLive.sol";
import {AcrossPoolObserver} from "../../mocks/across/AcrossPoolObserver.sol";
import {Eip1271Depositor} from "../../mocks/across/Eip1271Depositor.sol";

/// @notice Founder chat of 2026-10-02 ("make tests to see if in standalone contract connection we can read the latest
///         transactions in the bridge to know an average of the values being offered"; DEC-158, DEC-162, LC-159):
///         what a contract on Arbitrum One or Robinhood Chain can read from the live Across SpokePool about other
///         users' recent transfers, and whether a contract depositor can reprice a stuck transfer through a speed-up.
///         Ported from the bridge fee research (branch test/pp-sc-test-bridge-fee-research, commits 9b97892 and
///         85c6926). The answer is why the Across adapter averages the fund's own sends (divergence D-04).
/// @dev Findings proven here against the live pools (fork blocks: ARBITRUM_FORK_BLOCK / ROBINHOOD_FORK_BLOCK):
///      1. The SpokePool's readable state is counters, buffers, flags and admin addresses. The Across LP-fee state
///         (HubPool utilization, ConfigStore rate model) lives on Ethereum: no code at the HubPool address here.
///      2. A deposit changes exactly one storage word of the origin pool: the uint32 deposit counter. Two deposits
///         that differ only in `outputAmount` (the relayer's fee) leave byte-identical pool state, so no contract can
///         learn the fee another depositor offered. The pool accepts a 99% fee (the doc 11 drain example).
///      3. A fill changes exactly one storage word of the destination pool: `fillStatuses[relayHash] = Filled`. The
///         key hashes every field, amounts included, so a contract can only confirm a transfer it already knows.
///         Any address fills, with no deposit on record and at any fee (pre-fill and backstop-relayer facts).
///      4. Speed-up: the keyless TransitEscrow cannot sign (InvalidDepositorSignature); an EIP-1271 depositor can on
///         the origin chain, but `fillRelayWithUpdatedDeposit` re-verifies on the destination chain, so it only
///         works if a contract that approves the same digest exists at the same address on the destination chain.
contract AcrossSpokePoolReadabilityForkTest is Test {
    // Arbitrum One (Hub Chain)
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Robinhood Chain (Spoke Chain)
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Across HubPool on Ethereum mainnet; both SpokePools return it as `crossDomainAdmin`.
    address internal constant ETHEREUM_HUB_POOL = 0xc186fA914353c44b2E33eBE05f21846F1048bEda;

    /// @dev Doc 11 example: a 20,400 send. Market quote measured on 2026-10-02 03:27 UTC (/suggested-fees, hub to
    ///      spoke): outputAmount 20,387.746950, a 0.0601% fee. Drain quote: 204 arrives, 20,196 to the relayer.
    uint256 internal constant INPUT = 20_400e6;
    uint256 internal constant OUT_MARKET = 20_387_746_950;
    uint256 internal constant OUT_DRAIN = 204e6;

    /// @dev Across EIP-712 domain (EIP712CrossChainUpgradeable): name, version and the origin chain id only.
    bytes32 internal constant ACROSS_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId)");
    bytes32 internal constant UPDATE_TYPEHASH = keccak256(
        "UpdateDepositDetails(uint256 depositId,uint256 originChainId,uint256 updatedOutputAmount,bytes32 updatedRecipient,bytes updatedMessage)"
    );

    /// @dev `FillStatus.Filled` in V3SpokePoolInterface (Unfilled, RequestedSlowFill, Filled).
    uint256 internal constant FILLED = 2;

    address internal stranger = makeAddr("stranger");
    address internal relayer = makeAddr("relayer");
    address internal recipient = makeAddr("recipient");
    address internal guardian = makeAddr("guardian");

    struct Route {
        address pool;
        address inputToken;
        address outputToken;
        uint256 originChainId;
        uint256 destinationChainId;
    }

    struct Diff {
        bytes32[] slots;
        bytes32[] before;
        bytes32[] after_;
    }

    // ------------------------------------------------------------------ setup helpers

    /// @dev Hub to spoke: USDC on Arbitrum One, USDG on Robinhood Chain.
    function _hubToSpoke() internal pure returns (Route memory) {
        return Route(ARB_SPOKE_POOL, ARB_USDC, RH_USDG, ARBITRUM_CHAIN_ID, ROBINHOOD_CHAIN_ID);
    }

    /// @dev Spoke to hub: USDG on Robinhood Chain, USDC on Arbitrum One.
    function _spokeToHub() internal pure returns (Route memory) {
        return Route(RH_SPOKE_POOL, RH_USDG, ARB_USDC, ROBINHOOD_CHAIN_ID, ARBITRUM_CHAIN_ID);
    }

    /// @dev Forks Arbitrum One at the suite's pin (export a recent block: the RPCs are not archive nodes); returns the
    ///      route that originates there.
    function _forkArbitrum() internal returns (Route memory) {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        assertEq(block.chainid, ARBITRUM_CHAIN_ID);
        return _hubToSpoke();
    }

    /// @dev Forks Robinhood Chain at the suite's pin; returns the route that originates there.
    function _forkRobinhood() internal returns (Route memory) {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID);
        return _spokeToHub();
    }

    function _word(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev A stranger's plain deposit on `r`, with `outputAmount` as the only free choice.
    function _strangerDeposit(Route memory r, uint256 outputAmount) internal {
        vm.prank(stranger);
        IAcrossSpokePoolLive(r.pool)
            .depositV3(
                stranger,
                stranger,
                r.inputToken,
                r.outputToken,
                INPUT,
                outputAmount,
                r.destinationChainId,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                ""
            );
    }

    function _fundStranger(Route memory r) internal {
        deal(r.inputToken, stranger, INPUT);
        vm.prank(stranger);
        IERC20(r.inputToken).approve(r.pool, INPUT);
    }

    /// @dev Storage words of `account` whose value differs before and after the recorded session (a word written and
    ///      restored, like the reentrancy guard, is not a change).
    function _changes(Vm.AccountAccess[] memory accesses, address account) internal pure returns (Diff memory d) {
        bytes32[] memory slots = new bytes32[](64);
        bytes32[] memory first = new bytes32[](64);
        bytes32[] memory last = new bytes32[](64);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory s = accesses[i].storageAccesses;
            for (uint256 j; j < s.length; ++j) {
                if (s[j].account != account || !s[j].isWrite || s[j].reverted) continue;
                uint256 k;
                while (k < n && slots[k] != s[j].slot) ++k;
                if (k == n) {
                    slots[n] = s[j].slot;
                    first[n] = s[j].previousValue;
                    ++n;
                }
                last[k] = s[j].newValue;
            }
        }
        uint256 changed;
        for (uint256 k; k < n; ++k) {
            if (first[k] != last[k]) ++changed;
        }
        d.slots = new bytes32[](changed);
        d.before = new bytes32[](changed);
        d.after_ = new bytes32[](changed);
        uint256 m;
        for (uint256 k; k < n; ++k) {
            if (first[k] == last[k]) continue;
            d.slots[m] = slots[k];
            d.before[m] = first[k];
            d.after_[m] = last[k];
            ++m;
        }
    }

    function _relayData(Route memory r, uint256 outputAmount, address depositor)
        internal
        view
        returns (IAcrossSpokePoolLive.V3RelayData memory)
    {
        // `r` is the route of the deposit; this runs on its destination chain.
        return IAcrossSpokePoolLive.V3RelayData({
            depositor: _word(depositor),
            recipient: _word(recipient),
            exclusiveRelayer: bytes32(0),
            inputToken: _word(r.inputToken),
            outputToken: _word(r.outputToken),
            inputAmount: INPUT,
            outputAmount: outputAmount,
            originChainId: r.originChainId,
            depositId: 987_654_321,
            fillDeadline: uint32(block.timestamp) + 21_600,
            exclusivityDeadline: 0,
            message: ""
        });
    }

    // ------------------------------------------------------------------ 1. readable state

    function _assertReadableState(Route memory r) internal view {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(r.pool);
        assertEq(pool.chainId(), r.originChainId, "chainId");
        assertGt(pool.numberOfDeposits(), 0, "a counter, not a list");
        assertEq(pool.depositQuoteTimeBuffer(), 3600, "depositQuoteTimeBuffer");
        assertEq(pool.fillDeadlineBuffer(), 21_600, "fillDeadlineBuffer (DEC-066)");
        assertFalse(pool.pausedDeposits(), "deposits open");
        assertFalse(pool.pausedFills(), "fills open");
        assertEq(pool.getCurrentTime(), block.timestamp, "pool time is block time");
        // The only fee state Across keeps on-chain (LP fee: HubPool utilization and the ConfigStore rate model) lives
        // on Ethereum. The pool names the HubPool as its admin, and nothing is deployed at that address here.
        assertEq(pool.crossDomainAdmin(), ETHEREUM_HUB_POOL, "admin is the Ethereum HubPool");
        assertEq(pool.withdrawalRecipient(), ETHEREUM_HUB_POOL, "withdrawal recipient is the Ethereum HubPool");
        assertEq(ETHEREUM_HUB_POOL.code.length, 0, "no HubPool on this chain");
        assertEq(pool.UPDATE_BYTES32_DEPOSIT_DETAILS_HASH(), UPDATE_TYPEHASH, "speed-up type string");
    }

    /// LC-159: on Arbitrum One the SpokePool exposes counters, buffers, flags and admin addresses, and no fee oracle.
    function test_LC159_arbitrum_readableStateIsCountersBuffersAndFlags() public {
        _assertReadableState(_forkArbitrum());
    }

    /// LC-159: the same on Robinhood Chain.
    function test_LC159_robinhood_readableStateIsCountersBuffersAndFlags() public {
        _assertReadableState(_forkRobinhood());
    }

    // ------------------------------------------------------------------ 2. a deposit stores only the counter

    function _assertDepositWritesOnlyTheCounter(Route memory r) internal {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(r.pool);
        _fundStranger(r);
        uint32 id = pool.numberOfDeposits();

        vm.startStateDiffRecording();
        _strangerDeposit(r, OUT_MARKET);
        Diff memory d = _changes(vm.stopAndReturnStateDiff(), r.pool);

        assertEq(d.slots.length, 1, "one pool word changes");
        // Packed word: DEPRECATED_wrappedNativeToken (20 bytes), DEPRECATED_depositQuoteTimeBuffer (4),
        // numberOfDeposits (4, bits 192..223), pausedFills (1), pausedDeposits (1).
        assertEq(uint32(uint256(d.before[0]) >> 192), id, "counter before");
        assertEq(uint32(uint256(d.after_[0]) >> 192), id + 1, "counter after");
        assertEq(uint256(d.after_[0]) - uint256(d.before[0]), uint256(1) << 192, "nothing else in the word moved");
        assertEq(pool.numberOfDeposits(), id + 1);
    }

    /// LC-159: a deposit on Arbitrum One changes one word of the pool, the deposit counter; amounts are not stored.
    function test_LC159_arbitrum_depositWritesOnlyTheDepositCounter() public {
        _assertDepositWritesOnlyTheCounter(_forkArbitrum());
    }

    /// LC-159: the same on Robinhood Chain.
    function test_LC159_robinhood_depositWritesOnlyTheDepositCounter() public {
        _assertDepositWritesOnlyTheCounter(_forkRobinhood());
    }

    // ------------------------------------------------------------------ 3. the fee leaves no trace

    function _depositAndObserve(Route memory r, uint256 outputAmount, AcrossPoolObserver observer)
        internal
        returns (Diff memory d, AcrossPoolObserver.Observation memory o)
    {
        _fundStranger(r);
        vm.startStateDiffRecording();
        _strangerDeposit(r, outputAmount);
        d = _changes(vm.stopAndReturnStateDiff(), r.pool);
        o = observer.observe(r.pool, r.inputToken);
    }

    function _assertFeeLeavesNoTrace(Route memory r) internal {
        AcrossPoolObserver observer = new AcrossPoolObserver();
        AcrossPoolObserver.Observation memory before = observer.observe(r.pool, r.inputToken);
        uint256 snapshot = vm.snapshotState();
        (Diff memory market, AcrossPoolObserver.Observation memory oMarket) =
            _depositAndObserve(r, OUT_MARKET, observer);
        vm.revertToState(snapshot);
        // Doc 11 §1.5: the pool does not judge the price; a deposit leaving 99% to the relayer is accepted.
        (Diff memory drain, AcrossPoolObserver.Observation memory oDrain) = _depositAndObserve(r, OUT_DRAIN, observer);

        assertEq(market.slots, drain.slots, "same words written");
        assertEq(market.after_, drain.after_, "same values written");
        assertEq(oMarket.deposits, oDrain.deposits, "same counter");
        assertEq(oMarket.poolBalance, oDrain.poolBalance, "same balance");
        // What the standalone observer learns: one more deposit and the input amount (balance delta, and only when
        // nothing else moved the pool's balance in between). The output amount, hence the fee, is not observable.
        assertEq(oMarket.deposits, before.deposits + 1, "one more deposit");
        assertEq(oMarket.poolBalance, before.poolBalance + INPUT, "input amount via balance delta");
    }

    /// LC-159: on Arbitrum One a 0.06% deposit and a 99% deposit leave identical pool state: no contract can average
    /// the fees other depositors offered.
    function test_LC159_arbitrum_offeredFeeLeavesNoTraceInPoolState() public {
        _assertFeeLeavesNoTrace(_forkArbitrum());
    }

    /// LC-159: the same on Robinhood Chain.
    function test_LC159_robinhood_offeredFeeLeavesNoTraceInPoolState() public {
        _assertFeeLeavesNoTrace(_forkRobinhood());
    }

    // ------------------------------------------------------------------ 4. destination side

    /// @dev Runs on the destination chain of `deposit`; fills it from `relayer` and checks the single word written.
    function _assertFillWritesOnlyItsStatus(Route memory deposit, address destinationPool) internal {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(destinationPool);
        AcrossPoolObserver observer = new AcrossPoolObserver();
        IAcrossSpokePoolLive.V3RelayData memory rd = _relayData(deposit, OUT_MARKET, stranger);
        IAcrossSpokePoolLive.V3RelayData memory other = _relayData(deposit, OUT_DRAIN, stranger);

        deal(deposit.outputToken, relayer, OUT_MARKET);
        vm.prank(relayer);
        IERC20(deposit.outputToken).approve(destinationPool, OUT_MARKET);

        vm.startStateDiffRecording();
        // A fill needs no deposit on record: id 987,654,321 was never deposited (doc 11 §1.3, pre-fill).
        vm.prank(relayer);
        pool.fillRelay(rd, block.chainid, _word(relayer));
        Diff memory d = _changes(vm.stopAndReturnStateDiff(), destinationPool);

        assertEq(d.slots.length, 1, "one pool word changes");
        assertEq(uint256(d.after_[0]), FILLED, "the word is a status flag");
        assertEq(pool.fillStatuses(pool.getV3RelayHash(rd)), FILLED, "status keyed by the full relay data");
        assertTrue(observer.isFilled(destinationPool, rd), "a contract that knows every field can confirm the fill");
        assertEq(pool.fillStatuses(pool.getV3RelayHash(other)), 0, "change the output amount: another key");
        assertEq(IERC20(deposit.outputToken).balanceOf(recipient), OUT_MARKET, "delivered");
    }

    /// LC-159: a hub-to-spoke fill on Robinhood Chain writes only `fillStatuses[relayHash] = Filled`.
    function test_LC159_robinhood_fillWritesOnlyTheStatusOfItsRelayHash() public {
        Route memory hubToSpoke = _hubToSpoke();
        _forkRobinhood();
        _assertFillWritesOnlyItsStatus(hubToSpoke, RH_SPOKE_POOL);
    }

    /// LC-159: a spoke-to-hub fill on Arbitrum One writes only `fillStatuses[relayHash] = Filled`.
    function test_LC159_arbitrum_fillWritesOnlyTheStatusOfItsRelayHash() public {
        Route memory spokeToHub = _spokeToHub();
        _forkArbitrum();
        _assertFillWritesOnlyItsStatus(spokeToHub, ARB_SPOKE_POOL);
    }

    /// LC-159 stuck-send remedy: the pool does not price a fill. Any address fills a deposit that pays the relayer
    /// nothing (output equal to input) or less than nothing; it is repaid `inputAmount` on the origin chain later.
    /// This is what a backstop relayer run by the operator would do for an under-priced send.
    function test_LC159_robinhood_anyAddressFillsAnUnderpricedDeposit() public {
        Route memory hubToSpoke = _hubToSpoke();
        _forkRobinhood();
        address backstop = makeAddr("backstop");
        IAcrossSpokePoolLive.V3RelayData memory zeroFee = _relayData(hubToSpoke, INPUT, stranger);
        IAcrossSpokePoolLive.V3RelayData memory negativeFee = _relayData(hubToSpoke, INPUT + 1e6, stranger);
        negativeFee.depositId += 1;

        deal(RH_USDG, backstop, 3 * INPUT);
        vm.startPrank(backstop);
        IERC20(RH_USDG).approve(RH_SPOKE_POOL, 3 * INPUT);
        IAcrossSpokePoolLive(RH_SPOKE_POOL).fillRelay(zeroFee, ARBITRUM_CHAIN_ID, _word(backstop));
        IAcrossSpokePoolLive(RH_SPOKE_POOL).fillRelay(negativeFee, ARBITRUM_CHAIN_ID, _word(backstop));
        vm.stopPrank();

        assertEq(IERC20(RH_USDG).balanceOf(recipient), 2 * INPUT + 1e6, "both delivered");
    }

    // ------------------------------------------------------------------ 5. speed-up

    /// @dev One production-shaped send: the real AcrossBridgeAdapter, executed by the harness vault with a keyless
    ///      TransitEscrow clone as depositor of record (DEC-066, QA6).
    function _sendThroughTransitEscrow(Route memory r, address destinationVault)
        internal
        returns (address escrow, uint256 depositId, bytes memory message)
    {
        AcrossHarnessVault harness = new AcrossHarnessVault();
        harness.pin(new AcrossBridgeAdapter(address(harness), guardian, r.pool));
        deal(r.inputToken, address(harness), INPUT);
        message = TransitMessage.encode(keccak256("fund"), r.originChainId, bytes32(uint256(1)), TransferKind.Principal);
        IBridgeAdapter.SendRequest memory req = IBridgeAdapter.SendRequest({
            inputToken: r.inputToken,
            outputToken: r.outputToken,
            inputAmount: INPUT,
            destinationChainId: r.destinationChainId,
            recipient: _word(destinationVault),
            message: message
        });
        IBridgeAdapter.BridgeCall memory call;
        (call, escrow) = harness.send(req);
        depositId = uint256(call.transitRef);
    }

    function _assertKeylessEscrowCannotSpeedUp(Route memory r, address destinationVault) internal {
        (address escrow, uint256 depositId, bytes memory message) = _sendThroughTransitEscrow(r, destinationVault);
        uint256 raised = OUT_MARKET - 10e6;

        // No signature at all.
        vm.expectRevert(IAcrossSpokePoolLive.InvalidDepositorSignature.selector);
        IAcrossSpokePoolLive(r.pool).speedUpV3Deposit(escrow, depositId, raised, destinationVault, message, "");

        // An ECDSA signature by an unrelated key over the right digest.
        bytes memory signature =
            _signBy("someone", _speedUpDigest(depositId, r.originChainId, raised, _word(destinationVault), message));
        vm.expectRevert(IAcrossSpokePoolLive.InvalidDepositorSignature.selector);
        IAcrossSpokePoolLive(r.pool).speedUpV3Deposit(escrow, depositId, raised, destinationVault, message, signature);
    }

    function _signBy(string memory key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256(bytes(key))), digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The Across speed-up digest (`_verifyUpdateV3DepositMessage`): the same on both chains, because the
    ///      domain carries only the origin chain id and no verifying contract.
    function _speedUpDigest(
        uint256 depositId,
        uint256 originChainId,
        uint256 updatedOutput,
        bytes32 updatedRecipient,
        bytes memory message
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(ACROSS_DOMAIN_TYPEHASH, keccak256("ACROSS-V2"), keccak256("1.0.0"), originChainId)
        );
        bytes32 structHash = keccak256(
            abi.encode(UPDATE_TYPEHASH, depositId, originChainId, updatedOutput, updatedRecipient, keccak256(message))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// LC-159: the production depositor of record, a keyless TransitEscrow clone, cannot speed up a hub-to-spoke send
    /// on Arbitrum One: the live pool rejects every signature (DEC-066, QA6 hold).
    function test_LC159_arbitrum_keylessTransitEscrowCannotSpeedUp() public {
        _assertKeylessEscrowCannotSpeedUp(_forkArbitrum(), makeAddr("spokeVault"));
    }

    /// LC-159: the same for a spoke-to-hub send on Robinhood Chain.
    function test_LC159_robinhood_keylessTransitEscrowCannotSpeedUp() public {
        _assertKeylessEscrowCannotSpeedUp(_forkRobinhood(), makeAddr("coreVault"));
    }

    function _eip1271Deposit(Route memory r, Eip1271Depositor depositor) internal {
        bytes memory data = abi.encodeCall(
            IAcrossSpokePoolLive.depositV3,
            (
                address(depositor),
                recipient,
                r.inputToken,
                r.outputToken,
                INPUT,
                OUT_MARKET,
                r.destinationChainId,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                ""
            )
        );
        depositor.execute(r.inputToken, r.pool, INPUT, data);
    }

    function _assertEip1271DepositorCanSpeedUpOnOrigin(Route memory r) internal {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(r.pool);
        Eip1271Depositor depositor = new Eip1271Depositor(address(this));
        deal(r.inputToken, address(depositor), INPUT);
        uint256 depositId = pool.numberOfDeposits();
        _eip1271Deposit(r, depositor);

        uint256 raised = OUT_MARKET - 10e6;
        bytes32 digest = _speedUpDigest(depositId, r.originChainId, raised, _word(recipient), "");

        vm.expectRevert(IAcrossSpokePoolLive.InvalidDepositorSignature.selector);
        pool.speedUpV3Deposit(address(depositor), depositId, raised, recipient, "", "");

        depositor.approveDigest(digest);
        vm.expectEmit(true, true, false, true, r.pool);
        emit IAcrossSpokePoolLive.RequestedSpeedUpDeposit(
            raised, depositId, _word(address(depositor)), _word(recipient), "", ""
        );
        vm.prank(stranger); // anyone may submit it; the depositor's EIP-1271 answer is what counts
        pool.speedUpV3Deposit(address(depositor), depositId, raised, recipient, "", "");
    }

    /// LC-159: an EIP-1271 depositor's speed-up is accepted by the live Arbitrum One pool.
    function test_LC159_arbitrum_eip1271DepositorCanSpeedUpOnOrigin() public {
        _assertEip1271DepositorCanSpeedUpOnOrigin(_forkArbitrum());
    }

    /// LC-159: the same on Robinhood Chain.
    function test_LC159_robinhood_eip1271DepositorCanSpeedUpOnOrigin() public {
        _assertEip1271DepositorCanSpeedUpOnOrigin(_forkRobinhood());
    }

    /// @dev Runs on the destination chain of `deposit`. The depositor is an origin-chain contract address.
    function _assertUpdatedFillNeedsTheDepositorOnDestination(Route memory deposit, address destinationPool) internal {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(destinationPool);
        address depositorAddress = makeAddr("eip1271DepositorOnOrigin");
        assertEq(depositorAddress.code.length, 0, "nothing at the depositor address on the destination");
        IAcrossSpokePoolLive.V3RelayData memory rd = _relayData(deposit, OUT_MARKET, depositorAddress);
        uint256 raised = OUT_MARKET - 10e6;
        bytes32 digest = _speedUpDigest(rd.depositId, deposit.originChainId, raised, rd.recipient, "");

        deal(deposit.outputToken, relayer, OUT_MARKET);
        vm.prank(relayer);
        IERC20(deposit.outputToken).approve(destinationPool, OUT_MARKET);

        // The origin-chain approval does not travel: the destination pool re-verifies against the depositor address
        // on its own chain, where there is no code.
        vm.prank(relayer);
        vm.expectRevert(IAcrossSpokePoolLive.InvalidDepositorSignature.selector);
        pool.fillRelayWithUpdatedDeposit(rd, block.chainid, _word(relayer), raised, rd.recipient, "", "");

        // A twin at the same address that approves the same digest makes the updated fill go through.
        deployCodeTo("Eip1271Depositor.sol:Eip1271Depositor", abi.encode(address(this)), depositorAddress);
        Eip1271Depositor(depositorAddress).approveDigest(digest);
        vm.prank(relayer);
        pool.fillRelayWithUpdatedDeposit(rd, block.chainid, _word(relayer), raised, rd.recipient, "", "");

        assertEq(IERC20(deposit.outputToken).balanceOf(recipient), raised, "the updated (lower) amount arrives");
        assertEq(IERC20(deposit.outputToken).balanceOf(relayer), OUT_MARKET - raised, "relayer kept the difference");
        assertEq(pool.fillStatuses(pool.getV3RelayHash(rd)), FILLED, "the original deposit is the one filled");
    }

    /// LC-159: a hub-to-spoke speed-up only fills on Robinhood Chain if the depositor contract exists there too.
    function test_LC159_robinhood_updatedFillNeedsTheDepositorContractOnDestination() public {
        Route memory hubToSpoke = _hubToSpoke();
        _forkRobinhood();
        _assertUpdatedFillNeedsTheDepositorOnDestination(hubToSpoke, RH_SPOKE_POOL);
    }

    /// LC-159: a spoke-to-hub speed-up only fills on Arbitrum One if the depositor contract exists there too.
    function test_LC159_arbitrum_updatedFillNeedsTheDepositorContractOnDestination() public {
        Route memory spokeToHub = _spokeToHub();
        _forkArbitrum();
        _assertUpdatedFillNeedsTheDepositorOnDestination(spokeToHub, ARB_SPOKE_POOL);
    }
}
