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
///      `scaledBalance * indexNow / 1e27 - principal`, in asset units. Every verb that moves value realizes the whole
///      income measured at that block and pays it out as income before touching principal, so income is never
///      compounded into principal (DEC-064).
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
    /// @param params `abi.encode(uint256 amount)` to supply, or empty to supply the whole amount transferred in. Any
    ///        asset above `amount` is returned to the vault.
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
    /// @param params `abi.encode(uint256 amount)` to supply, or empty to supply the whole amount transferred in.
    /// @dev DEC-068: the income measured at this block is paid to the vault as income first, then the principal is
    ///      re-based to `principal + amount` at the current index. The supply runs before the income withdrawal so the
    ///      new liquidity helps serve it.
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
        (, income0) = _split(l, index);

        l.lastIndex = index;
        l.realizedIncome += income0;
        used0 = _supply(asset, l, params);
        l.principal += used0;
        if (income0 != 0) _withdraw(asset, l, income0);

        emit PositionIncreased(positionKey, used0, 0, income0, 0);
        return (used0, 0, income0, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Exit verbs (never gated, DEC-056)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @param params `abi.encode(uint256 principalAmount)`: principal to withdraw, in asset units, or
    ///        `type(uint256).max` for all of it. The position stays open (possibly empty) until `closePosition`.
    /// @dev DEC-068, DEC-079: withdraws `principalAmount` plus the whole income measured at this block; returns
    ///      `principal0 = principalAmount` and `income0 = income`. Reverts above the current principal. A reserve without
    ///      enough liquidity makes Aave revert; the adapter never pays less than asked (a Partial Payout is the vault's
    ///      decision, DEC-068).
    function decreasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        address asset = _openAsset(positionKey);
        uint256 principalAmount = abi.decode(params, (uint256));
        if (principalAmount == 0) revert ZeroAmount();
        amounts = _exit(asset, _ledgers[asset], principalAmount);
        emit PositionDecreased(positionKey, amounts);
    }

    /// @inheritdoc IAdapter
    /// @dev Takes no parameters; any `params` are ignored.
    /// @dev DEC-068, DEC-079: withdraws everything and splits it into the principal and the income measured at this
    ///      block; the key leaves `positionKeys()`. `realizedIncome` keeps counting (Q60).
    /// @dev Checks-effects-interactions: `open` is cleared before Aave is called. The ledger writes that follow the
    ///      Aave calls in `_supply`, `_withdraw` and `_exit` are inherent (they record the scaled delta Aave produced)
    ///      and accepted (Slither reentrancy-no-eth): every entry is `onlyVault` and `nonReentrant` against the fixed
    ///      Aave Pool (Aave verifier finding).
    function closePosition(bytes32 positionKey, bytes calldata)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        l.open = false;
        amounts = _exit(asset, l, type(uint256).max);
        emit PositionClosed(positionKey, amounts);
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-068: withdraws only the income measured at this block; principal is untouched. No Aave call when there
    ///      is no income (Aave rejects a zero withdrawal).
    function collectIncome(bytes32 positionKey) external onlyVault nonReentrant returns (Amounts memory amounts) {
        address asset = _openAsset(positionKey);
        Ledger storage l = _ledgers[asset];
        uint256 index = pool.getReserveNormalizedIncome(asset);
        (, uint256 income) = _split(l, index);

        l.lastIndex = index;
        l.realizedIncome += income;
        if (income != 0) _withdraw(asset, l, income);

        amounts.income0 = income;
        emit IncomeCollected(positionKey, income, 0);
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

    /// @dev Full or partial exit. `principalAmount == type(uint256).max` or equal to the current principal is a full
    ///      exit: Aave's `type(uint256).max` withdrawal empties the adapter's aToken balance, so no scaled dust stays
    ///      behind. DEC-080: only the ledger's share of what Aave paid is reported; foreign aTokens are paid out
    ///      unreported.
    function _exit(address asset, Ledger storage l, uint256 principalAmount) internal returns (Amounts memory amounts) {
        uint256 index = pool.getReserveNormalizedIncome(asset);
        (uint256 principalNow, uint256 income) = _split(l, index);
        l.lastIndex = index;

        if (principalAmount != type(uint256).max && principalAmount < principalNow) {
            // Partial: the whole income plus `principalAmount`, which is below the ledger value, so Aave burns at most
            // the ledger's scaled balance.
            l.principal -= principalAmount;
            l.realizedIncome += income;
            _withdraw(asset, l, principalAmount + income);
            amounts.principal0 = principalAmount;
            amounts.income0 = income;
            return amounts;
        }
        if (principalAmount != type(uint256).max && principalAmount > principalNow) {
            revert AmountAbovePrincipal(principalAmount, principalNow);
        }

        uint256 ledgerScaled = l.scaledBalance;
        l.scaledBalance = 0;
        l.principal = 0;
        uint256 heldScaled = IAToken(l.aToken).scaledBalanceOf(address(this));
        uint256 withdrawn = heldScaled == 0 ? 0 : pool.withdraw(asset, type(uint256).max, vault);
        uint256 attributable = heldScaled <= ledgerScaled ? withdrawn : Math.mulDiv(withdrawn, ledgerScaled, heldScaled);

        // Rounding: Aave may pay one unit more than the rounded-down ledger value (that unit is income) or, when
        // foreign units share the balance, one unit less (taken from principal so the income counter never regresses).
        if (attributable >= principalNow + income) {
            amounts.income0 = attributable - principalNow;
        } else {
            amounts.income0 = Math.min(income, attributable);
        }
        amounts.principal0 = attributable - amounts.income0;
        l.realizedIncome += amounts.income0;
    }

    /// @dev Supplies `params` amount (or everything transferred in) on the adapter's behalf and returns any excess to
    ///      the vault. DEC-080: the ledger is credited with the scaled delta Aave minted for this call only.
    function _supply(address asset, Ledger storage l, bytes calldata params) internal returns (uint256 amount) {
        // The adapter holds no underlying between calls, so its balance is what the vault just transferred in.
        uint256 transferred = IERC20(asset).balanceOf(address(this));
        amount = params.length == 0 ? transferred : abi.decode(params, (uint256));
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
    ///      amount reverts.
    function _withdraw(address asset, Ledger storage l, uint256 amount) internal {
        IAToken aToken = IAToken(l.aToken);
        uint256 scaledBefore = aToken.scaledBalanceOf(address(this));
        uint256 withdrawn = pool.withdraw(asset, amount, vault);
        if (withdrawn != amount) revert UnexpectedWithdrawnAmount(amount, withdrawn);
        uint256 burned = scaledBefore - aToken.scaledBalanceOf(address(this));
        uint256 scaledBalance = l.scaledBalance;
        if (burned > scaledBalance) revert LedgerUnderflow(burned, scaledBalance);
        l.scaledBalance = scaledBalance - burned;
    }

    /// @dev DEC-068: `value = scaledBalance * index / 1e27` rounded down; principal now is `min(principal, value)` and
    ///      income is the rest. A rounding shortfall of Aave's scaled arithmetic is borne by principal, never by income.
    function _split(Ledger storage l, uint256 index) internal view returns (uint256 principalNow, uint256 income) {
        uint256 value = Math.mulDiv(l.scaledBalance, index, RAY);
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
