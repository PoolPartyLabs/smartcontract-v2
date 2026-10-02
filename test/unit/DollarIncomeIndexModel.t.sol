// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DollarIncomeIndex} from "../../src/libraries/DollarIncomeIndex.sol";
import {DollarIncomeIndexHarness} from "../mocks/income/DollarIncomeIndexHarness.sol";

/// @dev Per-holder reference (doc 10 appendix, `Referencia`): keeps every holder's token claims of the open interval
///      and converts everyone's claims at each collection, with no index at all. Claims are kept in Q128 so the
///      reference is exact to far below one base unit. The collection rule is the library's: each claim converts at
///      `obtained / max(sold, recognized)`; the `recognized - sold` unsold units are recognized again over the shares
///      held at the collection; at zero supply they stay unattributed.
contract DollarIncomeReference {
    address[] internal tokenList;
    address[] internal holderList;
    mapping(address holder => uint256) public sharesOf;
    uint256 public totalShares;
    mapping(address holder => mapping(address token => uint256)) internal tokenClaimQ;
    mapping(address holder => uint256) internal dollarsQ;
    mapping(address token => uint256) public recognized;
    mapping(address token => uint256) public unattributedTokens;
    uint256 public dollarsObtained;

    constructor(address[] memory tokens_, address[] memory holders_) {
        tokenList = tokens_;
        holderList = holders_;
    }

    function mint(address holder, uint256 shares) external {
        sharesOf[holder] += shares;
        totalShares += shares;
    }

    function burn(address holder, uint256 shares) external {
        sharesOf[holder] -= shares;
        totalShares -= shares;
    }

    function recognize(address token, uint256 amount) public returns (bool) {
        if (amount == 0) return true;
        uint256 supply = totalShares;
        if (supply == 0) return false;
        for (uint256 i; i < holderList.length; ++i) {
            address holder = holderList[i];
            uint256 shares = sharesOf[holder];
            if (shares != 0) tokenClaimQ[holder][token] += Math.mulDiv(amount << 128, shares, supply);
        }
        recognized[token] += amount;
        return true;
    }

    function collect(uint256[] memory sold, uint256[] memory obtained) external {
        uint256[] memory carried = new uint256[](tokenList.length);
        for (uint256 k; k < tokenList.length; ++k) {
            address token = tokenList[k];
            uint256 r = recognized[token];
            uint256 denominator = sold[k] > r ? sold[k] : r;
            for (uint256 i; i < holderList.length; ++i) {
                address holder = holderList[i];
                uint256 claim = tokenClaimQ[holder][token];
                if (claim == 0) continue;
                if (denominator != 0) dollarsQ[holder] += Math.mulDiv(claim, obtained[k], denominator);
                tokenClaimQ[holder][token] = 0;
            }
            if (sold[k] < r) carried[k] = r - sold[k];
            recognized[token] = 0;
            dollarsObtained += obtained[k];
        }
        for (uint256 k; k < tokenList.length; ++k) {
            if (carried[k] != 0 && !recognize(tokenList[k], carried[k])) {
                unattributedTokens[tokenList[k]] += carried[k];
            }
        }
    }

    /// @dev Dollars ever attributed to `holder`, floored.
    function dollars(address holder) external view returns (uint256) {
        return dollarsQ[holder] >> 128;
    }

    /// @dev `holder`'s claim on `token` in the open interval, floored.
    function tokens(address holder, address token) external view returns (uint256) {
        return tokenClaimQ[holder][token] >> 128;
    }
}

/// @dev Drives the library (through the harness) and the reference with the same random operations, and checks them
///      against each other. Used by the sequence fuzz and as the invariant handler.
///      Tokens: a 6-decimal dollar token sold near 1:1, WETH (18 decimals, 1,000-4,000 USD) and a stock token
///      (18 decimals, 1-1,000 USD); every rate is at most ~1.01 dollar unit per token unit, so one token unit of
///      rounding is at most two dollar units.
contract DollarIncomeModelHandler is Test {
    DollarIncomeIndexHarness public immutable harness;
    DollarIncomeReference public immutable ref;
    address[3] internal tokenList = [address(0x05DC), address(0xE7E1), address(0x5707)];
    address[5] internal holderList =
        [address(0xA11CE), address(0xB0B), address(0xCA10), address(0xD0A), address(0xE7A)];

    mapping(address holder => uint256) public takenBy;
    /// @dev Rounding budget per holder: one dollar unit per settlement, up to three per adjusted token (one token unit
    ///      at a rate below two, plus the ceiling of the conversion), two per collection (index floors).
    mapping(address holder => uint256) public settlements;
    mapping(address holder => uint256) public adjustments;
    uint256 public collections;

    constructor() {
        harness = new DollarIncomeIndexHarness(1);
        address[] memory tokens_ = new address[](3);
        for (uint256 k; k < 3; ++k) {
            harness.registerToken(tokenList[k]);
            tokens_[k] = tokenList[k];
        }
        address[] memory holders_ = new address[](5);
        for (uint256 i; i < 5; ++i) {
            holders_[i] = holderList[i];
        }
        ref = new DollarIncomeReference(tokens_, holders_);
    }

    // ------------------------------------------------------------------ operations

    function mint(uint256 holderSeed, uint256 wholeShares) public {
        address holder = holderList[holderSeed % 5];
        uint256 shares = bound(wholeShares, 1, 1e9) * 1e18;
        harness.mint(holder, shares);
        ref.mint(holder, shares);
        settlements[holder] += 1;
        adjustments[holder] += 3;
    }

    function burn(uint256 holderSeed, uint256 tenths) public {
        address holder = holderList[holderSeed % 5];
        uint256 balance = harness.sharesOf(holder);
        if (balance == 0) return;
        tenths = bound(tenths, 1, 10);
        uint256 shares = tenths == 10 ? balance : (balance * tenths) / 10;
        if (shares == 0) return;
        harness.burn(holder, shares);
        ref.burn(holder, shares);
        settlements[holder] += 1;
        adjustments[holder] += 3;
    }

    function recognize(uint256 tokenSeed, uint256 amount) public {
        uint256 k = tokenSeed % 3;
        amount = bound(amount, 0, k == 0 ? 1e12 : 1e22);
        assertEq(harness.recognize(tokenList[k], amount), ref.recognize(tokenList[k], amount), "same acceptance");
    }

    /// @dev Per token, one of: sell exactly what was recognized (most often), sell part of it, sell nothing, sell
    ///      more (fee units, income recognized at zero supply), at a random price.
    function collect(uint256 seed) public {
        uint256[] memory sold = new uint256[](3);
        uint256[] memory obtained = new uint256[](3);
        for (uint256 k; k < 3; ++k) {
            uint256 r = harness.incomeToken(tokenList[k]).recognized;
            uint256 draw = uint256(keccak256(abi.encode(seed, k)));
            uint256 mode = draw % 8;
            if (mode < 4) sold[k] = r;
            else if (mode == 4) sold[k] = (r * ((draw >> 8) % 10)) / 10;
            else if (mode == 5) sold[k] = 0;
            else sold[k] = r + (r * ((draw >> 8) % 5)) / 10 + ((draw >> 16) % 1e6);
            uint256 price = draw >> 32;
            if (k == 0) obtained[k] = (sold[k] * (990 + price % 21)) / 1000;
            else if (k == 1) obtained[k] = Math.mulDiv(sold[k], 1000 + price % 3001, 1e12);
            else obtained[k] = Math.mulDiv(sold[k], 1 + price % 1000, 1e12);
        }
        harness.collect(sold, obtained);
        ref.collect(sold, obtained);
        collections += 1;
    }

    function settle(uint256 holderSeed) public {
        address holder = holderList[holderSeed % 5];
        harness.settle(holder);
        settlements[holder] += 1;
    }

    function take(uint256 holderSeed, uint256 maxDollars) public {
        address holder = holderList[holderSeed % 5];
        uint256 cap = maxDollars % 4 == 0 ? type(uint256).max : bound(maxDollars, 0, 1e12);
        takenBy[holder] += harness.take(holder, cap);
        settlements[holder] += 1;
    }

    // ------------------------------------------------------------------ checks

    /// @dev Each holder: dollars (owed plus taken) and open-interval token claims equal the reference within the
    ///      rounding budget, and never above it by more than the reference's own final floor.
    function checkParity() public view {
        for (uint256 i; i < 5; ++i) {
            address holder = holderList[i];
            uint256 lib = harness.owedDollars(holder) + takenBy[holder];
            uint256 expected = ref.dollars(holder);
            uint256 budget = 4 + settlements[holder] + 3 * adjustments[holder] + 2 * collections;
            assertLe(lib, expected + 1, "dollars: never above the reference");
            assertGe(lib + budget, expected, "dollars: within rounding of the reference");
            for (uint256 k; k < 3; ++k) {
                uint256 libTokens = harness.tokenOwed(holder, tokenList[k]);
                uint256 refTokens = ref.tokens(holder, tokenList[k]);
                assertLe(libTokens, refTokens + 1, "tokens: never above the reference");
                assertGe(libTokens + 2 + adjustments[holder], refTokens, "tokens: within rounding of the reference");
            }
        }
    }

    /// @dev Doc 10 section 2: the holders together are never owed more than was recognized (tokens) or obtained
    ///      (dollars); the open-interval and unattributed books match the reference exactly.
    function checkConservation() public view {
        uint256 owedSum;
        for (uint256 i; i < 5; ++i) {
            owedSum += harness.owedDollars(holderList[i]) + takenBy[holderList[i]];
        }
        (uint256 obtained, uint256 attributed, uint256 taken) = harness.totals();
        assertLe(owedSum, attributed, "never more dollars than attributed");
        assertLe(attributed, obtained, "never more dollars than obtained");
        assertEq(obtained, ref.dollarsObtained());
        uint256 takenSum;
        for (uint256 i; i < 5; ++i) {
            takenSum += takenBy[holderList[i]];
        }
        assertEq(taken, takenSum);
        for (uint256 k; k < 3; ++k) {
            address token = tokenList[k];
            DollarIncomeIndex.IncomeToken memory t = harness.incomeToken(token);
            assertEq(t.recognized, ref.recognized(token), "same open-interval recognition");
            assertEq(t.unattributed, ref.unattributedTokens(token), "same unattributed units");
            uint256 tokenSum;
            for (uint256 i; i < 5; ++i) {
                tokenSum += harness.tokenOwed(holderList[i], token);
            }
            assertLe(tokenSum, t.recognized, "never more tokens than recognized");
        }
    }
}

/// @dev DEC-161: the library against the per-holder reference over random sequences of recognize / mint / burn /
///      collect / settle / take, the analogue of the doc 10 appendix's 3,000 x 400 Python run.
contract DollarIncomeIndexModelTest is Test {
    uint256 internal constant STEPS = 64;

    function testFuzz_DEC161_matchesTheReferenceOverRandomSequences(uint256 seed) public {
        DollarIncomeModelHandler handler = new DollarIncomeModelHandler();
        for (uint256 step; step < STEPS; ++step) {
            uint256 draw = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = draw % 100;
            uint256 a = draw >> 8;
            uint256 b = uint256(keccak256(abi.encode(draw)));
            if (op < 22) handler.mint(a, b);
            else if (op < 37) handler.burn(a, b);
            else if (op < 72) handler.recognize(a, b);
            else if (op < 82) handler.collect(b);
            else if (op < 92) handler.settle(a);
            else handler.take(a, b);
            if (draw % 16 == 0) handler.checkParity();
        }
        handler.collect(seed);
        handler.checkParity();
        handler.checkConservation();
    }
}

/// @dev Doc 10 section 3 negative: converting an adjustment with the LATEST collection's rate instead of the rate
///      stored for the interval it belongs to gives a holder the wrong dollars and breaks conservation.
contract DollarIncomeIndexLatestRateTest is Test {
    DollarIncomeIndexHarness internal h;
    DollarIncomeReference internal ref;
    address internal usdc = makeAddr("usdc");
    address internal weth = makeAddr("weth");
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");
    address internal caio = makeAddr("caio");

    uint256 internal constant SHARE = 1e18;
    uint256 internal constant WETH = 1e18;
    uint256 internal constant USD = 1e6;

    function setUp() public {
        h = new DollarIncomeIndexHarness(1);
        h.registerToken(usdc);
        h.registerToken(weth);
        address[] memory tokens_ = new address[](2);
        tokens_[0] = usdc;
        tokens_[1] = weth;
        address[] memory holders_ = new address[](3);
        holders_[0] = ana;
        holders_[1] = bruno;
        holders_[2] = caio;
        ref = new DollarIncomeReference(tokens_, holders_);
    }

    function _mint(address holder, uint256 shares) internal {
        h.mint(holder, shares);
        ref.mint(holder, shares);
    }

    function _recognize(uint256 amount) internal {
        h.recognize(weth, amount);
        ref.recognize(weth, amount);
    }

    /// @dev Sells all recognized WETH at `usdPerWeth`.
    function _collect(uint256 usdPerWeth) internal returns (uint256 obtained) {
        uint256 amount = h.incomeToken(weth).recognized;
        uint256[] memory sold = new uint256[](2);
        uint256[] memory got = new uint256[](2);
        sold[1] = amount;
        obtained = Math.mulDiv(amount, usdPerWeth * USD, WETH);
        got[1] = obtained;
        h.collect(sold, got);
        ref.collect(sold, got);
    }

    /// @dev What `holder` would be owed if a closed interval's adjustments converted at the latest collection's rate.
    function _owedAtLatestRate(address holder) internal view returns (uint256 owed) {
        (uint256 dollars, uint256 mark, uint64 tag, bool adjusted) = h.holderState(holder);
        owed = dollars + Math.mulDiv(h.sharesOf(holder), h.dollarIndex() - mark, DollarIncomeIndex.Q128);
        if (!adjusted || tag == h.interval()) return owed;
        uint256 latest = h.interval() - 1;
        int256 adjustment = h.adjustment(holder, weth);
        uint256 rate = h.rateAt(latest, weth);
        if (adjustment >= 0) {
            owed += Math.mulDiv(uint256(adjustment), rate, DollarIncomeIndex.Q128);
        } else {
            uint256 debit = Math.mulDiv(uint256(-adjustment), rate, DollarIncomeIndex.Q128, Math.Rounding.Ceil);
            owed = owed > debit ? owed - debit : 0;
        }
    }

    /// Doc 10 section 4, case 2 continued: Caio's 0.01 WETH adjustment converted at the latest 2,500 instead of the
    /// stored 2,800 gives him 86 instead of 83, and the three holders 308 out of the 305 the sales obtained.
    function test_DEC161_latestRateInsteadOfStoredBreaksTheModel() public {
        _mint(ana, 100 * SHARE);
        _mint(bruno, 100 * SHARE);
        _recognize((2 * WETH) / 100);
        _mint(caio, 100 * SHARE);
        _recognize((3 * WETH) / 100);
        _collect(2800);
        _recognize((3 * WETH) / 100);
        _collect(3000);
        _recognize((3 * WETH) / 100);
        _collect(2500);

        assertApproxEqAbs(h.owedDollars(caio), 83 * USD, 3);
        assertApproxEqAbs(h.owedDollars(caio), ref.dollars(caio), 3, "the stored rate matches the reference");
        uint256 atLatest = _owedAtLatestRate(caio);
        assertApproxEqAbs(atLatest, 86 * USD, 3);
        uint256 sumAtLatest = h.owedDollars(ana) + h.owedDollars(bruno) + atLatest;
        assertGt(sumAtLatest, 305 * USD, "the latest rate pays more dollars than the sales obtained");
    }

    /// Doc 10 section 3 ("trocar essa taxa pela da coleta mais recente quebra a conta"): for any entrant whose
    /// interval closed at a price different from the latest collection's, the stored rate matches the reference and
    /// the latest rate misses it by the adjustment times the price difference.
    function testFuzz_DEC161_latestRateMissesTheReference(
        uint256 entrantShares,
        uint256 incomeBefore,
        uint256 incomeAfter,
        uint256 price1,
        uint256 price2,
        uint256 price3
    ) public {
        entrantShares = bound(entrantShares, 20, 2000) * SHARE; // 1/10 to 10x the 200 shares already held
        incomeBefore = bound(incomeBefore, 1e16, 1e22);
        // At least 0.01 WETH per sale, so the dollars obtained resolve each price (a sale of a few wei floors to a
        // rate unrelated to the price).
        incomeAfter = bound(incomeAfter, 1e16, 1e22);
        price1 = bound(price1, 1000, 4000);
        price2 = bound(price2, 1000, 4000);
        price3 = bound(price3, 1000, 4000);
        if (price3 < price1 + 100 && price1 < price3 + 100) price3 = price1 > 2500 ? price1 - 100 : price1 + 100;

        _mint(ana, 100 * SHARE);
        _mint(bruno, 100 * SHARE);
        _recognize(incomeBefore);
        _mint(caio, entrantShares);
        _recognize(incomeAfter);
        uint256 obtained = _collect(price1);
        _recognize(incomeBefore);
        obtained += _collect(price2);
        _recognize(incomeAfter);
        obtained += _collect(price3);

        uint256 stored = h.owedDollars(caio);
        uint256 expected = ref.dollars(caio);
        assertApproxEqAbs(stored, expected, 6, "the stored rate matches the reference");
        uint256 atLatest = _owedAtLatestRate(caio);
        // |adjustment| = entrantShares x incomeBefore / 200 shares >= incomeBefore / 10 >= 0.001 WETH.
        uint256 gap = Math.mulDiv(Math.mulDiv(incomeBefore, entrantShares, 200 * SHARE), 100 * USD, WETH);
        if (atLatest > expected) assertGe(atLatest - expected, gap / 2, "the latest rate overpays");
        else assertGe(expected - atLatest, gap / 2, "the latest rate underpays");
        uint256 sumStored = h.owedDollars(ana) + h.owedDollars(bruno) + stored;
        assertLe(sumStored, obtained, "the stored rate never pays more than obtained");
        assertApproxEqAbs(sumStored, obtained, 12, "every dollar of the sales has an owner");
    }
}

/// @dev Invariant campaign over the same handler: random sequences, checked after every call.
contract DollarIncomeIndexModelInvariantTest is StdInvariant, Test {
    DollarIncomeModelHandler internal handler;

    function setUp() public {
        handler = new DollarIncomeModelHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = DollarIncomeModelHandler.mint.selector;
        selectors[1] = DollarIncomeModelHandler.burn.selector;
        selectors[2] = DollarIncomeModelHandler.recognize.selector;
        selectors[3] = DollarIncomeModelHandler.collect.selector;
        selectors[4] = DollarIncomeModelHandler.settle.selector;
        selectors[5] = DollarIncomeModelHandler.take.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// DEC-161, doc 10 section 2: every holder equals the per-holder reference within rounding.
    function invariant_DEC161_eachHolderMatchesTheReference() public view {
        handler.checkParity();
    }

    /// DEC-161: the holders are never owed more than recognized (tokens) or obtained (dollars).
    function invariant_DEC161_neverMoreThanRecognizedOrObtained() public view {
        handler.checkConservation();
    }
}
