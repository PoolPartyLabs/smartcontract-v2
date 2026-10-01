// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {IAToken} from "../interfaces/external/IAToken.sol";
import {AdapterGuard} from "./AdapterGuard.sol";

/// @title AaveV3Adapter
/// @notice Supplies reserve assets (USDC on Arbitrum One) to the Aave V3 Pool for one Spoke Vault and withdraws them.
///         Supply only, never borrows.
/// @dev DEC-018, DEC-028: Aave V3 enters the MVP on the Hub Chain only, without borrowing; this contract has no path to
///      `borrow`, `setUserUseReserveAsCollateral` or any debt function.
/// @dev DEC-059: an aToken supply is an Exact-Value Position, `isExactValue()` is true.
/// @dev DEC-068: the ledger of each position stores the scaled balance and the reserve's normalized income index at the
///      last measurement; `principal` is the amount supplied and not yet withdrawn; income is
///      `scaledBalance * indexNow / 1e27 - principal`, in asset units. Income is never compounded into principal
///      (DEC-064): every verb that moves value realizes the income measured at that block and pays it out as income,
///      but only as far as the reserve's available liquidity allows (final verification, DEC-056, DEC-059, DEC-068):
///      the principal asked is withdrawn first, pending income is withdrawn best effort up to the liquidity left
///      (`IERC20(asset).balanceOf(aToken)`, a sufficiency bound only, never a value base, DEC-080; and a reverting
///      Aave withdrawal is caught), and what the reserve cannot pay stays pending in the position. Income never
///      blocks a principal exit.
/// @dev DEC-079: principal and income are delivered separately from Aave's own accounting; the vault does not classify.
/// @dev DEC-080: `scaledBalance` is an internal ledger credited and debited only by the scaled deltas this adapter's
///      own supply and withdraw calls produce. aTokens anyone transfers to the adapter are never reported as principal
///      or income; a full exit hands their value to the vault unreported, where the garbage collector sweeps it
///      (DEC-096, DEC-101).
/// @dev DEC-058: immutable, one instance per fund per chain; no proxy, no setter, no SELFDESTRUCT. The vault calls it
///      with a plain CALL.
/// @dev Custody (IAdapter): the vault transfers the asset in before `openPosition`/`increasePosition`; unused asset
///      goes back in the same call; every withdrawal is paid by Aave straight to the vault (`to = vault`), so the adapter
///      never holds the underlying between calls. The only balance it keeps is the aToken position itself. The Pool
///      approval is exact and reset to zero after each supply.
contract AaveV3Adapter is IAdapter, AdapterGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Aave's index unit (1e27).
    uint256 internal constant RAY = 1e27;

    /// @notice Ledger of one reserve asset and its single position (positionKey = poolKey).
    /// @param aToken The reserve's aToken, fixed at construction.
    /// @param open Whether the position is open (listed in `positionKeys()`).
    /// @param scaledBalance Scaled units this adapter's own supplies minted minus those its withdrawals burned
    ///        (DEC-068, DEC-080).
    /// @param principal Asset amount supplied and not yet withdrawn (DEC-068).
    /// @param lastIndex Reserve normalized income index at the last measurement, in ray (DEC-068). Informational, for
    ///        off-chain reconciliation only: income is `value - principal` (`_split`), not
    ///        `scaledBalance * (indexNow - lastIndex)`, so this field is never read by the income arithmetic.
    /// @param realizedIncome Income ever paid to the vault, including closed positions (Q60, DEC-092).
    struct Ledger {
        address aToken;
        bool open;
        uint256 scaledBalance;
        uint256 principal;
        uint256 lastIndex;
        uint256 realizedIncome;
    }

    /// @inheritdoc IAdapter
    address public immutable vault;

    /// @notice The Aave V3 Pool.
    IAaveV3Pool public immutable pool;

    /// @dev Closed list of reserve assets fixed at construction (DEC-030, DEC-053).
    address[] internal _assets;

    /// @dev Ledger per reserve asset.
    mapping(address asset => Ledger) internal _ledgers;

    /// @notice The vault address is zero.
    error ZeroVault();

    /// @notice The pool address is zero.
    error ZeroPool();

    /// @notice The reserve asset list is empty or contains address(0).
    error InvalidReserveAsset(address asset);

    /// @notice A reserve asset is listed twice.
    error DuplicateReserveAsset(address asset);

    /// @notice The Pool has no aToken for this asset.
    error ReserveNotListed(address asset);

    /// @notice The asset already has an open position (one position per asset).
    error PositionAlreadyOpen(bytes32 positionKey);

    /// @notice A zero amount was requested.
    error ZeroAmount();

    /// @notice The requested supply exceeds what the vault transferred to the adapter.
    error AmountAboveTransferred(uint256 amount, uint256 transferred);

    /// @notice A decrease asked for more principal than the position holds now.
    error AmountAbovePrincipal(uint256 amount, uint256 principal);

    /// @notice Aave paid a different amount than asked (DEC-068: never accept a silent partial withdrawal).
    error UnexpectedWithdrawnAmount(uint256 expected, uint256 withdrawn);

    /// @notice Aave burned more scaled units than the ledger holds (DEC-080: broken accounting surfaces, never silent).
    error LedgerUnderflow(uint256 burned, uint256 scaledBalance);

    /// @notice `openPosition`/`increasePosition` got empty `params`; the vault always passes `abi.encode(amount)`
    ///         (DEC-080: the supply is never sized from the adapter's own balance).
    error AmountRequired();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    /// @param vault_ The Spoke Vault that owns this adapter (the Hub Chain Spoke Vault, DEC-028, DEC-054).
    /// @param guardian_ Immutable address allowed to pause and deprecate (Q17-2b OPEN, MVP reading L1).
    /// @param pool_ The Aave V3 Pool.
    /// @param assets_ Closed list of reserve assets this adapter may supply (USDC on Arbitrum One).
    constructor(address vault_, address guardian_, address pool_, address[] memory assets_) AdapterGuard(guardian_) {
        if (vault_ == address(0)) revert ZeroVault();
        if (pool_ == address(0)) revert ZeroPool();
        if (assets_.length == 0) revert InvalidReserveAsset(address(0));
        vault = vault_;
        pool = IAaveV3Pool(pool_);
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            if (asset == address(0)) revert InvalidReserveAsset(asset);
            if (_ledgers[asset].aToken != address(0)) revert DuplicateReserveAsset(asset);
            address aToken = IAaveV3Pool(pool_).getReserveData(asset).aTokenAddress;
            if (aToken == address(0)) revert ReserveNotListed(asset);
            _ledgers[asset].aToken = aToken;
            _assets.push(asset);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Static description
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @dev DEC-059: an aToken supply is read, never unwound, while the reserve has liquidity.
    function isExactValue() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IAdapter
    /// @dev poolKey = bytes32(uint256(uint160(asset))); single-token position, `token1 = address(0)`.
    function poolTokens(bytes32 poolKey) external view returns (address token0, address token1) {
        return (_listedAsset(poolKey), address(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Entry verbs (gated by pause and deprecation, DEC-056, DEC-058)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @param params `abi.encode(uint256 amount)` to supply; empty params revert `AmountRequired` (DEC-080, final
    ///        verification). Any asset above `amount` is returned to the vault.
    /// @dev positionKey = poolKey (one position per asset). DEC-068: records principal = amount supplied and the index.
    function openPosition(bytes32 poolKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        _requireEntryAllowed();
        address asset = _listedAsset(poolKey);
        Ledger storage l = _ledgers[asset];
        if (l.open) revert PositionAlreadyOpen(poolKey);
        uint256 index = pool.getReserveNormalizedIncome(asset);

        l.open = true;
        l.lastIndex = index;
        used0 = _supply(asset, l, params);
        l.principal = used0;

        emit PositionOpened(poolKey, poolKey, used0, 0);
        return (poolKey, used0, 0);
    }

    /// @inheritdoc IAdapter
    /// @param params `abi.encode(uint256 amount)` to supply; empty params revert `AmountRequired` (DEC-080).
    /// @dev DEC-068: the principal is re-based to `principal + amount` at the current index and the income measured at
    ///      this block is paid to the vault as income, best effort up to the reserve's available liquidity (what it
    ///      cannot pay stays pending). The supply runs before the income withdrawal so the new liquidity helps serve it.
    function increasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1)
    {
        _requireEntryAllowed();
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        uint256 index = pool.getReserveNormalizedIncome(asset);
        (, uint256 income) = _split(l, index);

        l.lastIndex = index;
        used0 = _supply(asset, l, params);
        l.principal += used0;
        income0 = _takeIncome(asset, l, index, income, _value(l, index));

        emit PositionIncreased(positionKey, used0, 0, income0, 0);
        return (used0, 0, income0, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Exit verbs (never gated, DEC-056)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @param params `abi.encode(uint256 principalAmount)`: principal to withdraw, in asset units, or
    ///        `type(uint256).max` for all of it. The position stays open (possibly empty) until `closePosition`.
    /// @dev DEC-068, DEC-079 (final verification, DEC-056, DEC-059): withdraws `principalAmount` first, then the
    ///      income measured at this block best effort, up to the reserve's available liquidity; returns
    ///      `principal0 = principalAmount` and `income0` = the income actually withdrawn, and the rest of the income
    ///      stays pending. Reverts above the current principal. A reserve without enough liquidity for the principal
    ///      asked makes Aave revert; the adapter never pays less principal than asked (a Partial Payout is the vault's
    ///      decision, DEC-068). With `type(uint256).max`, a reserve that can pay everything is emptied in one
    ///      withdrawal (no scaled dust, AAVE-4).
    function decreasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        address asset = _openAsset(positionKey);
        uint256 principalAmount = abi.decode(params, (uint256));
        if (principalAmount == 0) revert ZeroAmount();
        (amounts,) = _exit(asset, _ledgers[asset], principalAmount);
        emit PositionDecreased(positionKey, amounts);
    }

    /// @inheritdoc IAdapter
    /// @dev Takes no parameters; any `params` are ignored.
    /// @dev DEC-068, DEC-079: withdraws everything and splits it into the principal and the income measured at this
    ///      block; the key leaves `positionKeys()`. `realizedIncome` keeps counting (Q60). Final verification (DEC-056,
    ///      DEC-059): when the reserve cannot pay everything, the whole principal is still withdrawn, the income is
    ///      withdrawn up to the liquidity left, and the key stays open holding only the pending income (emitting
    ///      `PositionDecreased`, not `PositionClosed`), so no income is abandoned; the Spoke Vault keeps the position
    ///      registered while this adapter lists it, and a later `collectIncome` or `closePosition` takes the rest.
    /// @dev Checks-effects-interactions: `open` is cleared before Aave is called, and set back only when pending
    ///      income stays behind. The ledger writes that follow the Aave calls in `_supply`, `_withdraw` and `_exit` are
    ///      inherent (they record the scaled delta Aave produced) and accepted (Slither reentrancy-no-eth): every entry
    ///      is `onlyVault` and `nonReentrant` against the fixed Aave Pool (Aave verifier finding).
    function closePosition(bytes32 positionKey, bytes calldata)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        l.open = false;
        bool emptied;
        (amounts, emptied) = _exit(asset, l, type(uint256).max);
        if (emptied) {
            emit PositionClosed(positionKey, amounts);
        } else {
            l.open = true;
            emit PositionDecreased(positionKey, amounts);
        }
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-068: withdraws only the income measured at this block, best effort up to the reserve's available
    ///      liquidity (final verification: `min(income, available)`, a reverting withdrawal is caught and pays 0); the
    ///      rest stays pending and principal is untouched. No Aave call when there is nothing to withdraw (Aave rejects
    ///      a zero withdrawal).
    function collectIncome(bytes32 positionKey) external onlyVault nonReentrant returns (Amounts memory amounts) {
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        uint256 index = pool.getReserveNormalizedIncome(asset);
        (, uint256 income) = _split(l, index);

        l.lastIndex = index;
        amounts.income0 = _takeIncome(asset, l, index, income, _value(l, index));
        emit IncomeCollected(positionKey, amounts.income0, 0);
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-018, DEC-028: Aave V3 supply has no swap; always reverts.
    function swapExactInput(bytes32, address, uint256, uint256, bytes calldata) external pure returns (uint256) {
        revert UnsupportedOperation();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @dev DEC-068, DEC-079: `principal0 = min(principal, value)`, `income0 = value - principal0`, with
    ///      `value = scaledBalance * indexNow / 1e27` rounded down; `liquidity` is the ledger's scaled balance.
    function positionValue(bytes32 positionKey) external view returns (PositionValue memory value) {
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        (uint256 principalNow, uint256 income) = _split(l, pool.getReserveNormalizedIncome(asset));
        value.poolKey = positionKey;
        value.poolId = positionKey;
        value.liquidity = SafeCast.toUint128(l.scaledBalance);
        value.token0 = asset;
        value.principal0 = principalNow;
        value.income0 = income;
    }

    /// @inheritdoc IAdapter
    /// @dev Q60, DEC-068: income ever paid to the vault plus the income of the open position measured now. Zero for a
    ///      token that is not a reserve asset of this adapter. Income is measured as `value - principal` (`_split`),
    ///      so Aave's scaled rounding loss (up to ceil(index / 1e27) units per supply or withdrawal) is borne by
    ///      principal (AAVE-3): the first interest after an operation restores principal before it counts as income.
    ///      The counter is therefore at most the IAdapter formula `scaledBalance * (indexNow - indexLast)` summed over
    ///      time, and still monotonic.
    function cumulativeIncome(address token) external view returns (uint256) {
        Ledger storage l = _ledgers[token];
        if (!l.open) return l.realizedIncome;
        (, uint256 income) = _split(l, pool.getReserveNormalizedIncome(token));
        return l.realizedIncome + income;
    }

    /// @inheritdoc IAdapter
    function positionKeys() external view returns (bytes32[] memory keys) {
        uint256 count;
        for (uint256 i; i < _assets.length; ++i) {
            if (_ledgers[_assets[i]].open) ++count;
        }
        keys = new bytes32[](count);
        count = 0;
        for (uint256 i; i < _assets.length; ++i) {
            if (_ledgers[_assets[i]].open) keys[count++] = _keyOf(_assets[i]);
        }
    }

    /// @inheritdoc IAdapter
    /// @dev `abi.encode(ceil(principal * numerator / denominator))` for `decreasePosition`; the whole principal is a
    ///      close (which still keeps the key while income the reserve cannot pay stays pending).
    function unwindExitParams(bytes32 positionKey, uint256 numerator, uint256 denominator)
        external
        view
        returns (bool close, bytes memory params)
    {
        address asset = _openAsset(positionKey);
        (uint256 principalNow,) = _split(_ledgers[asset], pool.getReserveNormalizedIncome(asset));
        uint256 part = Math.mulDiv(principalNow, numerator, denominator, Math.Rounding.Ceil);
        if (part >= principalNow) return (true, "");
        return (false, abi.encode(part));
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-018, DEC-028: an Aave V3 supply has no price; always reverts.
    function spotQuote(bytes32, address, uint256) external pure returns (uint256) {
        revert UnsupportedOperation();
    }

    /// @notice The ledger of `asset` (DEC-068).
    function ledger(address asset) external view returns (Ledger memory) {
        return _ledgers[asset];
    }

    /// @notice The closed list of reserve assets.
    function reserveAssets() external view returns (address[] memory) {
        return _assets;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Full or partial exit, principal first (final verification, DEC-056, DEC-059, DEC-068). A full exit
    ///      (`type(uint256).max` or the whole current principal) first tries Aave's `type(uint256).max` withdrawal, which
    ///      empties the adapter's aToken balance with no scaled dust; DEC-080: only the ledger's share of what Aave paid
    ///      is reported and foreign aTokens are paid out unreported. When the reserve cannot pay that (the revert is
    ///      caught and the ledger restored), or for a partial exit, exactly `principalAmount` is withdrawn (Aave
    ///      reverts when even that is not available: genuine illiquidity, DEC-069 waits on it) and the income follows
    ///      best effort (`_takeIncome`).
    /// @return amounts Principal and income paid to the vault (DEC-079).
    /// @return emptied True when the position holds nothing of the ledger's any more (the full withdrawal ran, or the
    ///         value left rounds to zero).
    function _exit(address asset, Ledger storage l, uint256 principalAmount)
        internal
        returns (Amounts memory amounts, bool emptied)
    {
        uint256 index = pool.getReserveNormalizedIncome(asset);
        (uint256 principalNow, uint256 income) = _split(l, index);
        l.lastIndex = index;
        if (principalAmount == type(uint256).max) principalAmount = principalNow;
        else if (principalAmount > principalNow) revert AmountAbovePrincipal(principalAmount, principalNow);

        if (principalAmount == principalNow) {
            uint256 ledgerScaled = l.scaledBalance;
            uint256 ledgerPrincipal = l.principal;
            l.scaledBalance = 0;
            l.principal = 0;
            uint256 heldScaled = IAToken(l.aToken).scaledBalanceOf(address(this));
            if (heldScaled == 0) return (amounts, true);
            try pool.withdraw(asset, type(uint256).max, vault) returns (uint256 withdrawn) {
                uint256 attributable =
                    heldScaled <= ledgerScaled ? withdrawn : Math.mulDiv(withdrawn, ledgerScaled, heldScaled);
                // Rounding: Aave may pay one unit more than the rounded-down ledger value (that unit is income) or,
                // when foreign units share the balance, one unit less (taken from principal so the income counter
                // never regresses).
                if (attributable >= principalNow + income) {
                    amounts.income0 = attributable - principalNow;
                } else {
                    amounts.income0 = Math.min(income, attributable);
                }
                amounts.principal0 = attributable - amounts.income0;
                l.realizedIncome += amounts.income0;
                return (amounts, true);
            } catch {
                l.scaledBalance = ledgerScaled;
                l.principal = ledgerPrincipal;
            }
        }

        // Principal first; the whole current principal leaves the ledger's principal at 0 (a rounding shortfall is
        // borne by principal, AAVE-3).
        uint256 valueLeft = _value(l, index) - principalAmount;
        if (principalAmount != 0) {
            l.principal = principalAmount == principalNow ? 0 : l.principal - principalAmount;
            _withdraw(asset, l, principalAmount, false);
        }
        amounts.principal0 = principalAmount;
        amounts.income0 = _takeIncome(asset, l, index, income, valueLeft);
        emptied = _value(l, index) == 0;
        if (emptied) l.scaledBalance = 0;
    }

    /// @dev Withdraws up to `income` to the vault, bounded by the reserve's available liquidity (the aToken's
    ///      underlying balance, a sufficiency bound only, DEC-080) and never reverting on Aave's side: a failed
    ///      withdrawal pays 0 (final verification, DEC-056, DEC-068). Q60: when only part of the income leaves, Aave's
    ///      burn rounding (up to ceil(index / 1e27) units) is taken from principal (AAVE-3), so the income still
    ///      pending plus what was withdrawn never falls below what was measured and `cumulativeIncome` never regresses.
    ///      `valueBefore` is the value the position should hold before this withdrawal (an exit passes its value net of
    ///      the principal it withdrew, so that withdrawal's rounding is taken from principal too).
    function _takeIncome(address asset, Ledger storage l, uint256 index, uint256 income, uint256 valueBefore)
        internal
        returns (uint256 take)
    {
        if (income == 0) return 0;
        take = Math.min(income, IERC20(asset).balanceOf(l.aToken));
        if (take != 0 && !_withdraw(asset, l, take, true)) take = 0;
        l.realizedIncome += take;
        if (take < income) {
            uint256 valueAfter = _value(l, index);
            uint256 expected = valueBefore - take;
            if (valueAfter < expected) l.principal -= Math.min(l.principal, expected - valueAfter);
        }
    }

    /// @dev Supplies the `params` amount on the adapter's behalf and returns any excess to the vault. DEC-080: the
    ///      amount is always explicit (empty params revert `AmountRequired`, final verification), `balanceOf` is only
    ///      a sufficiency check, and the ledger is credited with the scaled delta Aave minted for this call only.
    function _supply(address asset, Ledger storage l, bytes calldata params) internal returns (uint256 amount) {
        if (params.length == 0) revert AmountRequired();
        // The adapter holds no underlying between calls, so its balance is what the vault just transferred in.
        uint256 transferred = IERC20(asset).balanceOf(address(this));
        amount = abi.decode(params, (uint256));
        if (amount == 0) revert ZeroAmount();
        if (amount > transferred) revert AmountAboveTransferred(amount, transferred);

        IAToken aToken = IAToken(l.aToken);
        uint256 scaledBefore = aToken.scaledBalanceOf(address(this));
        IERC20(asset).forceApprove(address(pool), amount);
        pool.supply(asset, amount, address(this), 0);
        IERC20(asset).forceApprove(address(pool), 0);
        l.scaledBalance += aToken.scaledBalanceOf(address(this)) - scaledBefore;

        if (transferred > amount) IERC20(asset).safeTransfer(vault, transferred - amount);
    }

    /// @dev Withdraws exactly `amount` to the vault and debits the scaled delta Aave burned. DEC-068: a different paid
    ///      amount reverts. With `bestEffort`, a reverting Aave withdrawal returns false instead of reverting (income
    ///      only; principal is never best effort).
    function _withdraw(address asset, Ledger storage l, uint256 amount, bool bestEffort) internal returns (bool) {
        IAToken aToken = IAToken(l.aToken);
        uint256 scaledBefore = aToken.scaledBalanceOf(address(this));
        uint256 withdrawn;
        if (bestEffort) {
            try pool.withdraw(asset, amount, vault) returns (uint256 paid) {
                withdrawn = paid;
            } catch {
                return false;
            }
        } else {
            withdrawn = pool.withdraw(asset, amount, vault);
        }
        if (withdrawn != amount) revert UnexpectedWithdrawnAmount(amount, withdrawn);
        uint256 burned = scaledBefore - aToken.scaledBalanceOf(address(this));
        uint256 scaledBalance = l.scaledBalance;
        // Independent verification plan F1 (review L-08): Aave rounds a burn up, so withdrawing what is left of the
        // ledger can burn one scaled unit more than it holds. Without foreign aTokens Aave refuses that withdrawal;
        // with any foreign aTokens in the adapter it takes the unit from them, and reverting here blocked the whole
        // exit. That one unit empties the ledger; anything more is still an anomaly and fails closed.
        if (burned > scaledBalance + 1) revert LedgerUnderflow(burned, scaledBalance);
        l.scaledBalance = burned > scaledBalance ? 0 : scaledBalance - burned;
        return true;
    }

    /// @dev DEC-068: the ledger's value at `index`, `scaledBalance * index / 1e27` rounded down.
    function _value(Ledger storage l, uint256 index) internal view returns (uint256) {
        return Math.mulDiv(l.scaledBalance, index, RAY);
    }

    /// @dev DEC-068: `value = scaledBalance * index / 1e27` rounded down; principal now is `min(principal, value)` and
    ///      income is the rest. A rounding shortfall of Aave's scaled arithmetic is borne by principal, never by income.
    function _split(Ledger storage l, uint256 index) internal view returns (uint256 principalNow, uint256 income) {
        uint256 value = _value(l, index);
        uint256 principal = l.principal;
        return value >= principal ? (principal, value - principal) : (value, 0);
    }

    /// @dev Reserve asset of a pool key; reverts with `UnknownPool` for a key that is not a listed reserve.
    function _listedAsset(bytes32 poolKey) internal view returns (address asset) {
        if (uint256(poolKey) >> 160 != 0) revert UnknownPool(poolKey);
        asset = address(uint160(uint256(poolKey)));
        if (_ledgers[asset].aToken == address(0)) revert UnknownPool(poolKey);
    }

    /// @dev Reserve asset of an open position key; reverts with `UnknownPosition` otherwise.
    function _openAsset(bytes32 positionKey) internal view returns (address asset) {
        asset = address(uint160(uint256(positionKey)));
        if (uint256(positionKey) >> 160 != 0 || !_ledgers[asset].open) revert UnknownPosition(positionKey);
    }

    function _keyOf(address asset) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(asset)));
    }
}
