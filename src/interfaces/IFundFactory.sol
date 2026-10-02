// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Mandate} from "../mandate/Mandate.sol";

/// @title IFundFactory
/// @notice Creates a fund's contracts from its Mandate: the hub set with `createFund` on the Hub Chain, and one Spoke
///         Vault with its adapters with `createSpoke` on each Spoke Chain.
/// @dev DEC-001: creation is permissionless; whoever creates a fund is its Manager (`msg.sender` must equal
///      `Mandate.manager`). DEC-053, DEC-054: every contract address is known at creation, on every chain, before any
///      of them exists: each one sits at a CREATE3 address that depends only on the factory address and the salt
///      `keccak256(abi.encode(fundId, role, chainId))`, never on creation code, so the Mandate (which the creation
///      code contains) can list the addresses without a cycle. The same factory address on every chain is what makes
///      the hub's predictions valid on the spokes (see Create3Deployer).
/// @dev Q59 (OPEN, research reading D): the fund number is `NUMBER_OFFSET + creation count` (first fund
///      `NUMBER_OFFSET + 1`), the Share is named `Pool Party Fund {n}` with symbol `PP-{n}`, no manager text;
///      `fundId = keccak256(abi.encode(hubChainId, factory, n, manager))`. The Manager is bound into the fund id
///      (DEC-001, FF-OQ-1), so every fund address, on every chain, can only be created by the Manager's key: nobody
///      else can squat a real fund's Spoke Vault on a spoke.
interface IFundFactory {
    /// @notice Protocol-level wiring of one chain, fixed at the factory's construction.
    /// @param numberOffset `NUMBER_OFFSET` (Q59): fund numbers of this factory start after it, so future Hub Chains
    ///        get disjoint ranges.
    /// @param baseToken USDC on the Hub Chain; the token the Transport Route delivers on a Spoke Chain (Robinhood
    ///        Chain: USDG) (DEC-011, DEC-031, DEC-055).
    /// @param acrossSpokePool Across SpokePool of this chain (DEC-031, DEC-087).
    /// @param wormholeCore Wormhole Core Bridge of this chain: the report publisher on a spoke, the verifier on the hub
    ///        (DEC-086, DEC-093), and on the hub the Core Vault's order publisher, whose `chainId()` must equal the
    ///        Mandate's `hubWormholeChainId` (DEC-120, DEC-139; D-15).
    /// @param uniswapV4PoolManager Uniswap V4 PoolManager; zero where the fund may not use Uniswap V4.
    /// @param uniswapV4PositionManager Uniswap V4 PositionManager.
    /// @param uniswapV4StateView Uniswap V4 StateView.
    /// @param permit2 Permit2 used by the PositionManager.
    /// @param aaveV3Pool Aave V3 Pool; zero where Aave is not deployed (Robinhood Chain) (DEC-018, DEC-028).
    /// @param uniswapV3Factory Uniswap V3 factory, the pools of every swap (DEC-136, DEC-153); zero where the fund may
    ///        not swap, which no fund chain allows (every Mandate lists a swap adapter on each of its chains).
    /// @param uniswapV3SwapRouter02 SwapRouter02 wired to `uniswapV3Factory`.
    /// @param uniswapV3QuoterV2 QuoterV2 wired to `uniswapV3Factory`.
    /// @param apiSigner The Pool Party API key of this chain (reading D-01): the swap adapters' route signer and the
    ///        Across adapters' quoter (WP-11); zero for a chain without API (every contract works without it, DEC-052).
    ///        Rotation needs a new factory (LC-16).
    /// @param managerRegistry Per-manager protocol slice registry; hub only (DEC-106, DEC-110).
    /// @param priceSource Prices non-USDC quantities into USDC; hub only (docs/ARCHITECTURE.md §5, OPEN).
    /// @param protocolRecipient Recipient of the flow fee and the protocol slice (DEC-106) and of swept excess
    ///        (DEC-096, DEC-101): the fee wallet (DEC-116).
    /// @param guardian Immutable guardian of every adapter's pause and deprecation flags (ruling 2026-09-29, Q17-2b).
    /// @param flowFeeBps Protocol flow fee handed to every Core Vault (DEC-106: 25 bps default; DEC-110: at most 100).
    /// @param coreVaultLogic The CoreVaultLogic library linked into the Core Vault creation code; hub only. The only
    ///        Core Vault library whose code the constructor checks.
    /// @param coreVaultCreationCodeHash keccak256 of the Core Vault creation code linked to the Core Vault libraries
    ///        (`CoreVaultLogic`, `CoreVaultTransitLogic`, `CoreVaultIncomeLogic`, `CoreVaultPayoutLogic`), without
    ///        constructor arguments; hub only. `createFund` refuses any other code.
    /// @param spokeCrossChainLib The SpokeCrossChainLib library linked into the stored Spoke Vault creation code.
    struct ProtocolWiring {
        uint256 numberOffset;
        address baseToken;
        address acrossSpokePool;
        address wormholeCore;
        address uniswapV4PoolManager;
        address uniswapV4PositionManager;
        address uniswapV4StateView;
        address permit2;
        address aaveV3Pool;
        address uniswapV3Factory;
        address uniswapV3SwapRouter02;
        address uniswapV3QuoterV2;
        address apiSigner;
        address managerRegistry;
        address priceSource;
        address protocolRecipient;
        address guardian;
        uint16 flowFeeBps;
        address coreVaultLogic;
        bytes32 coreVaultCreationCodeHash;
        address spokeCrossChainLib;
    }

    /// @notice Creation code of each fund contract the factory reads from chain (see CodeStore), without constructor
    ///         arguments. An empty list leaves that role unavailable on this chain.
    struct CreationCodeStores {
        address[] spokeVault;
        address[] uniswapV4Adapter;
        address[] aaveV3Adapter;
        address[] acrossBridgeAdapter;
        address[] valueReportReceiver;
        address[] uniswapV3SwapAdapter;
    }

    /// @notice A fund's contracts on one chain. A role the Mandate does not use on that chain is address(0) in
    ///         creation events and its CREATE3 address in predictions.
    struct ChainAddresses {
        uint256 chainId;
        address spokeVault;
        address uniswapV4Adapter;
        address aaveV3Adapter;
        address acrossBridgeAdapter;
        address uniswapV3SwapAdapter;
    }

    /// @notice A fund's contracts: the hub set plus the per-chain sets.
    /// @param shareToken Created by the Core Vault's constructor (CREATE, nonce 1).
    /// @param managerFeeVault Created by the Core Vault's constructor (CREATE, nonce 2; ruling 2026-09-29).
    struct FundAddresses {
        uint256 creationNumber;
        bytes32 fundId;
        address coreVault;
        address shareToken;
        address managerFeeVault;
        address valueReportReceiver;
        ChainAddresses[] chains;
    }

    /// @notice Hub inputs of `createFund` that the Mandate cannot carry.
    /// @param creationNumber The fund number the Mandate's addresses were predicted for; must be the next one.
    /// @param uniswapV4Pools The Mandate's Uniswap V4 pools on the Hub Chain, in Mandate order, as full `PoolKey`s
    ///        (the Mandate keeps only their ids, DEC-030).
    /// @param coreVaultCreationCode Core Vault creation code (about 34 KB, too large for the factory to hold), without
    ///        constructor arguments; must hash to `coreVaultCreationCodeHash`.
    /// @param seedAmount The manager's seed in USDC base units, at least the Mandate's `minFirstDeposit` (DEC-127,
    ///        DEC-061); the manager approves this factory for it before `createFund`.
    struct HubParams {
        uint256 creationNumber;
        PoolKey[] uniswapV4Pools;
        bytes coreVaultCreationCode;
        uint256 seedAmount;
    }

    /// @notice Spoke inputs of `createSpoke`.
    /// @param mandateHash The `mandateHash` the hub emitted in `FundCreated`; must equal the hash of the Mandate given.
    /// @param uniswapV4Pools The Mandate's Uniswap V4 pools on this chain, in Mandate order.
    struct SpokeParams {
        bytes32 mandateHash;
        PoolKey[] uniswapV4Pools;
    }

    /// @notice A fund was created on its Hub Chain, with every address.
    event FundCreated(
        uint256 indexed creationNumber,
        bytes32 indexed fundId,
        address indexed manager,
        bytes32 mandateHash,
        FundAddresses addresses
    );

    /// @notice A fund's Spoke Vault and adapters were created on a Spoke Chain.
    event SpokeCreated(
        bytes32 indexed fundId,
        uint256 indexed chainId,
        address indexed manager,
        bytes32 mandateHash,
        ChainAddresses addresses
    );

    /// @notice A required constructor address is zero.
    error ZeroAddress();

    /// @notice The flow fee is above the DEC-110 cap.
    error FlowFeeAboveCap(uint16 bps);

    /// @notice The Mandate's performance fee is below the registry's minimum manager fee (DEC-115, DEC-125 item 3).
    error ManagerFeeBelowMinimum(uint16 bps, uint16 minBps);

    /// @notice A linked library address has no code.
    error LibraryHasNoCode(address library_);

    /// @notice The caller is not the Mandate's manager (DEC-001, DEC-002).
    error NotManager(address caller, address manager);

    /// @notice `createFund` was called on a chain other than the Mandate's Hub Chain (DEC-011).
    error NotHubChain(uint256 chainId, uint256 hubChainId);

    /// @notice This factory has no hub wiring (Core Vault code hash, library, registry, price source).
    error HubNotConfigured();

    /// @notice The fund number the Mandate was built for is no longer the next one; predict again.
    error CreationNumberTaken(uint256 requested, uint256 next);

    /// @notice Creation code other than the pinned one was offered for `role`.
    error ForeignCreationCode(bytes32 role, bytes32 codeHash, bytes32 expected);

    /// @notice This factory holds no creation code for `role`.
    error RoleNotConfigured(bytes32 role);

    /// @notice The protocol behind `role` is not wired on this chain.
    error ProtocolNotOnChain(bytes32 role);

    /// @notice The Mandate's token for this chain is not the chain's base token.
    error BaseTokenMismatch(address token, address baseToken);

    /// @notice A Mandate position adapter is not the fund's predicted adapter on its chain (DEC-053, DEC-058).
    error UnexpectedAdapter(uint256 chainId, address adapter);

    /// @notice A Mandate bridge adapter is not the fund's predicted Across adapter on its chain (DEC-087, DEC-088).
    error UnexpectedBridgeAdapter(uint256 chainId, address adapter);

    /// @notice A Mandate swap adapter is not the fund's predicted Uniswap V3 swap adapter on its chain (DEC-136).
    error UnexpectedSwapAdapter(uint256 chainId, address adapter);

    /// @notice A Mandate spoke lists a Spoke Vault other than the fund's predicted one on that chain (DEC-054,
    ///         DEC-086).
    error SpokeVaultMismatch(uint256 chainId, bytes32 predicted, bytes32 listed);

    /// @notice The number of `PoolKey`s differs from the Mandate's Uniswap V4 pools on this chain (DEC-030).
    error PoolKeyCountMismatch(uint256 mandatePools, uint256 poolKeys);

    /// @notice A `PoolKey` does not hash to the Mandate pool at the same position (DEC-030).
    error PoolKeyMismatch(uint256 index, bytes32 mandatePoolKey, bytes32 poolId);

    /// @notice An Aave V3 Mandate pool key is not an asset address (`bytes32(uint256(uint160(asset)))`).
    error InvalidAavePoolKey(bytes32 poolKey);

    /// @notice The Mandate given does not hash to the `mandateHash` the hub emitted.
    error MandateHashMismatch(bytes32 mandateHash, bytes32 expected);

    /// @notice The fund's Spoke Vault on this chain already exists.
    error SpokeAlreadyCreated(bytes32 fundId, address spokeVault);

    /// @notice `createSpoke` was called on the Mandate's Hub Chain, whose Spoke Vault only `createFund` deploys
    ///         (DEC-011, DEC-054).
    error SpokeOnHubChain(uint256 chainId);

    /// @notice Creates a fund on its Hub Chain: the hub adapters the Mandate lists (Uniswap V4, Aave V3 and the Uniswap
    ///         V3 swap adapter with the hub Spoke Vault as vault, Across with the Core Vault as vault), the hub Spoke
    ///         Vault, the ValueReportReceiver and the Core Vault (which creates its ShareToken and ManagerFeeVault), in
    ///         that order, each at its predicted address; then seeds the fund with the manager's own capital.
    /// @dev DEC-127, DEC-061, DEC-113: in the same transaction the factory pulls the seed's cost (`p.seedAmount` less
    ///      the sub-share remainder) from the manager, approves the Core Vault for exactly that amount and calls
    ///      `ICoreVaultLifecycle.seed`, which pays the flow fee and mints the first shares to the manager at 1.00. A
    ///      seed below `m.minFirstDeposit` reverts (`BelowMinFirstDeposit`), so no fund exists without its seed.
    /// @dev Reverts unless `msg.sender == m.manager` (DEC-001), `m.hubChainId == block.chainid`, `m.usdc` is this
    ///      chain's base token, `m.performanceFeeBps` is at least the ManagerRegistry's `minManagerFeeBps` (DEC-115,
    ///      DEC-125 item 3; the Core Vault keeps that minimum as the floor of `decreaseManagerFee`), `p.creationNumber`
    ///      is the next fund number, the Core Vault code hashes to the pinned hash, and every address in the Mandate
    ///      (adapters, swap adapters, bridge adapters and Spoke Vaults on every chain) is the fund's predicted one.
    function createFund(Mandate memory m, HubParams memory p) external returns (FundAddresses memory addresses);

    /// @notice Creates the Spoke Vault and adapters of fund number `creationNumber` of the Mandate's Hub Chain on this
    ///         Spoke Chain, at the predicted addresses.
    /// @dev The fund id is derived here from `m.hubChainId` and `creationNumber`, never taken from the caller, and
    ///      `m.hubChainId` must not be this chain (`SpokeOnHubChain`): a fund id this factory derives for its own
    ///      `createFund` is therefore unreachable through `createSpoke`, so nobody can consume the hub salts of a
    ///      future fund (DEC-001, DEC-054). Reverts unless `msg.sender == m.manager`, the Mandate hashes to
    ///      `p.mandateHash`, this chain is a Mandate spoke whose token is this chain's base token, and every Mandate
    ///      address is the fund's predicted one (the spoke entry for this chain included). The fund id binds
    ///      `m.manager`, which must be the caller, so only the fund's Manager reaches its predicted addresses (DEC-001,
    ///      FF-OQ-1). The spoke cannot see the hub, so `p.mandateHash` binds the Mandate to the hub's `FundCreated`
    ///      event only as far as the Manager copies it faithfully (see docs/DEPLOYMENT.md).
    function createSpoke(uint256 creationNumber, Mandate memory m, SpokeParams memory p)
        external
        returns (ChainAddresses memory addresses);

    /// @notice The fund number `createFund` assigns next.
    function nextCreationNumber() external view returns (uint256);

    /// @notice `NUMBER_OFFSET` of the Q59 stance.
    function NUMBER_OFFSET() external view returns (uint256);

    /// @notice Whether `coreVault` is a Core Vault this factory created.
    function isFund(address coreVault) external view returns (bool);

    /// @notice The Core Vault of fund number `creationNumber`, or address(0).
    function fundByNumber(uint256 creationNumber) external view returns (address);

    /// @notice `keccak256(abi.encode(hubChainId, address(this), creationNumber, manager))` (Q59 stance; the Manager
    ///         bound in, DEC-001, FF-OQ-1).
    function fundIdOf(uint256 hubChainId, uint256 creationNumber, address manager) external view returns (bytes32);

    /// @notice `keccak256(abi.encode(fundId, role, chainId))`.
    function saltOf(bytes32 fundId, bytes32 role, uint256 chainId) external pure returns (bytes32);

    /// @notice The CREATE3 address of `role` for `fundId` on `chainId`, on every chain where this factory address
    ///         lives.
    function addressOf(bytes32 fundId, bytes32 role, uint256 chainId) external view returns (address);

    /// @notice Every address of fund number `creationNumber` created on this chain as its Hub Chain by `manager`, with
    ///         the per-chain sets of `chainIds`. Build the Mandate from it, then call `createFund` from `manager`.
    function predictAddresses(uint256 creationNumber, address manager, uint256[] calldata chainIds)
        external
        view
        returns (FundAddresses memory addresses);

    /// @notice keccak256 of the creation code this factory deploys for `role` (zero when not configured).
    function creationCodeHash(bytes32 role) external view returns (bytes32);

    /// @notice This chain's protocol wiring.
    function wiring() external view returns (ProtocolWiring memory);

    /// @notice The TransitEscrow implementation this factory created and hands to every vault (DEC-066, QA6).
    function transitEscrowImplementation() external view returns (address);
}
