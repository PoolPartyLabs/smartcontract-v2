// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {Mandate, MandateLib, SpokeConfig, PoolConfig} from "../mandate/Mandate.sol";
import {CoreVaultConfig} from "../core/CoreVaultTypes.sol";
import {TransitEscrow} from "../core/TransitEscrow.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {Create3} from "./Create3.sol";
import {CodeStore} from "./CodeStore.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";

/// @title FundFactoryV6
/// @dev DEC-188, DEC-190: isolated new-Fund version; existing factories and deployed Funds remain unchanged.
/// @notice Creates every contract of a fund from its Mandate, at addresses known on every chain before any of them
///         exists. See IFundFactory.
/// @dev Deployment model (docs/DEPLOYMENT.md): the protocol operator deploys one factory per chain through
///      Create3Deployer with the same salt, so the factory sits at the same address on the Hub Chain and on every
///      Spoke Chain while its protocol wiring (constructor arguments) differs per chain. Every fund address is a
///      CREATE3 address of this factory (Create3), so the hub computes the spoke addresses and the spoke computes the
///      hub's (DEC-053, DEC-054).
/// @dev Linked libraries (docs/ARCHITECTURE.md §1.1): the Core Vault creation code arrives in calldata and must hash to
///      `coreVaultCreationCodeHash`, the code linked to the Core Vault libraries (`CoreVaultLogic`,
///      `CoreVaultTransitLogic`, `CoreVaultIncomeLogic`, `CoreVaultPayoutLogic`), so nobody deploys foreign code under
///      a fund id; the Spoke Vault creation code is stored on chain (CodeStore) linked to the Spoke Vault libraries
///      (`SpokeCrossChainLib`, `SpokeUnwindLib`). The adapters and the receiver are stored the same way. Every stored
///      code hash is fixed at construction. The constructor checks code only at `coreVaultLogic` and
///      `spokeCrossChainLib`: the other libraries are pinned by the hashes alone, so a code hash linked to a library
///      that was never deployed lets funds be created whose verbs that reach that library revert until the operator
///      deploys it at its deterministic address.
/// @dev DEC-022, DEC-058: no owner, no setter, no proxy, no selfdestruct; the only state is the creation counter and
///      the fund registry. DEC-001: creation is permissionless.
contract FundFactoryV6 is IFundFactory, ReentrancyGuardTransient, EIP712 {
    using MandateLib for Mandate;
    using SafeERC20 for IERC20;

    /// @notice DEC-190: binds one fixed Solana key to one Fund and its full native Mandate.
    bytes32 public constant BINDING_TYPEHASH = keccak256(
        "ManagerSolanaBinding(bytes32 solanaKey,address fund,bytes32 spoke,uint256 spokeChainId,bytes32 nativeMandateHash,uint256 nonce,uint256 expiry)"
    );
    bytes32 public constant ROLE_NATIVE_REGISTRY = "SolanaRegistryV6";
    mapping(address manager => uint256) public bindingNonce;
    mapping(address fund => bytes32) public bindingCommitment;
    SolanaMandateV6.Config private _pendingNative;

    struct Binding {
        uint256 nonce;
        uint256 expiry;
        bytes signature;
    }

    error InvalidSolanaBinding();
    error NativeCreationRequired();

    /// @notice Salt roles (the fund contract each salt deploys).
    bytes32 public constant ROLE_CORE_VAULT = "CoreVault";
    bytes32 public constant ROLE_SPOKE_VAULT = "SpokeVault";
    bytes32 public constant ROLE_UNISWAP_V4_ADAPTER = "UniswapV4Adapter";
    bytes32 public constant ROLE_AAVE_V3_ADAPTER = "AaveV3Adapter";
    bytes32 public constant ROLE_ACROSS_BRIDGE_ADAPTER = "AcrossBridgeAdapter";
    bytes32 public constant ROLE_VALUE_REPORT_RECEIVER = "ValueReportReceiver";
    bytes32 public constant ROLE_UNISWAP_V3_SWAP_ADAPTER = "UniswapV3SwapAdapter";

    /// @notice Variation band handed to every receiver: 0, disabled (Q57 (d) OPEN, stance: slot reserved, not
    ///         enforced).
    uint16 public constant VARIATION_BAND_BPS = 0;

    /// @inheritdoc IFundFactory
    uint256 public immutable NUMBER_OFFSET;

    address internal immutable _baseToken;
    address internal immutable _acrossSpokePool;
    address internal immutable _wormholeCore;
    address internal immutable _uniswapV4PoolManager;
    address internal immutable _uniswapV4PositionManager;
    address internal immutable _uniswapV4StateView;
    address internal immutable _permit2;
    address internal immutable _aaveV3Pool;
    address internal immutable _uniswapV3Factory;
    address internal immutable _uniswapV3SwapRouter02;
    address internal immutable _uniswapV3QuoterV2;
    address internal immutable _apiSigner;
    address internal immutable _managerRegistry;
    address internal immutable _priceSource;
    address internal immutable _protocolRecipient;
    address internal immutable _guardian;
    uint16 internal immutable _flowFeeBps;
    address internal immutable _coreVaultLogic;
    bytes32 internal immutable _coreVaultCreationCodeHash;
    address internal immutable _spokeCrossChainLib;

    /// @inheritdoc IFundFactory
    address public immutable transitEscrowImplementation;

    /// @dev Funds created on this chain as their Hub Chain.
    uint256 internal _fundCount;

    /// @inheritdoc IFundFactory
    mapping(address coreVault => bool) public isFund;

    /// @inheritdoc IFundFactory
    mapping(uint256 creationNumber => address coreVault) public fundByNumber;

    /// @inheritdoc IFundFactory
    mapping(bytes32 role => bytes32) public creationCodeHash;

    /// @dev Data contracts holding each role's creation code, written once in the constructor.
    mapping(bytes32 role => address[]) internal _codeStores;

    /// @param w This chain's protocol wiring. A spoke-only factory leaves the hub fields zero.
    /// @param stores This chain's creation code stores (CodeStore); their hashes are recorded here, never changed.
    constructor(ProtocolWiring memory w, CreationCodeStores memory stores, address[] memory registryCode)
        EIP712("PoolParty Solana Fund", "6")
    {
        if (
            w.baseToken == address(0) || w.acrossSpokePool == address(0) || w.wormholeCore == address(0)
                || w.protocolRecipient == address(0) || w.guardian == address(0) || w.spokeCrossChainLib == address(0)
        ) revert ZeroAddress();
        // DEC-106, DEC-110: the flow fee is capped at 1% as a core constant.
        if (w.flowFeeBps > ShareMath.MAX_FLOW_FEE_BPS) revert FlowFeeAboveCap(w.flowFeeBps);
        if (w.spokeCrossChainLib.code.length == 0) revert LibraryHasNoCode(w.spokeCrossChainLib);
        if (w.coreVaultLogic != address(0) && w.coreVaultLogic.code.length == 0) {
            revert LibraryHasNoCode(w.coreVaultLogic);
        }

        NUMBER_OFFSET = w.numberOffset;
        _baseToken = w.baseToken;
        _acrossSpokePool = w.acrossSpokePool;
        _wormholeCore = w.wormholeCore;
        _uniswapV4PoolManager = w.uniswapV4PoolManager;
        _uniswapV4PositionManager = w.uniswapV4PositionManager;
        _uniswapV4StateView = w.uniswapV4StateView;
        _permit2 = w.permit2;
        _aaveV3Pool = w.aaveV3Pool;
        _uniswapV3Factory = w.uniswapV3Factory;
        _uniswapV3SwapRouter02 = w.uniswapV3SwapRouter02;
        _uniswapV3QuoterV2 = w.uniswapV3QuoterV2;
        _apiSigner = w.apiSigner;
        _managerRegistry = w.managerRegistry;
        _priceSource = w.priceSource;
        _protocolRecipient = w.protocolRecipient;
        _guardian = w.guardian;
        _flowFeeBps = w.flowFeeBps;
        _coreVaultLogic = w.coreVaultLogic;
        _coreVaultCreationCodeHash = w.coreVaultCreationCodeHash;
        _spokeCrossChainLib = w.spokeCrossChainLib;
        creationCodeHash[ROLE_CORE_VAULT] = w.coreVaultCreationCodeHash;

        // DEC-066, QA6 (approved 2026-09-29): one TransitEscrow implementation per chain, cloned once per send.
        transitEscrowImplementation = address(new TransitEscrow());

        _storeCode(ROLE_SPOKE_VAULT, stores.spokeVault);
        _storeCode(ROLE_UNISWAP_V4_ADAPTER, stores.uniswapV4Adapter);
        _storeCode(ROLE_AAVE_V3_ADAPTER, stores.aaveV3Adapter);
        _storeCode(ROLE_ACROSS_BRIDGE_ADAPTER, stores.acrossBridgeAdapter);
        _storeCode(ROLE_VALUE_REPORT_RECEIVER, stores.valueReportReceiver);
        _storeCode(ROLE_UNISWAP_V3_SWAP_ADAPTER, stores.uniswapV3SwapAdapter);
        if (keccak256(CodeStore.read(registryCode)) != keccak256(type(SolanaSpokeRegistryV6).creationCode)) {
            revert InvalidSolanaBinding();
        }
        _storeCode(ROLE_NATIVE_REGISTRY, registryCode);
    }

    function _storeCode(bytes32 role, address[] memory chunks) private {
        if (chunks.length == 0) return;
        creationCodeHash[role] = keccak256(CodeStore.read(chunks));
        _codeStores[role] = chunks;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Creation
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFundFactory
    function createFund(Mandate memory, HubParams memory) external pure returns (FundAddresses memory) {
        revert NativeCreationRequired();
    }

    /// @notice Creates only new Funds with an EOA Manager's signed native commitment (DEC-188, DEC-190).
    /// @dev Solana acceptance is enforced by the Solana init instruction, not inferred from an EVM signature.
    function createFundV6(
        Mandate memory m,
        HubParams memory p,
        SolanaMandateV6.Config memory native,
        Binding memory binding
    ) external nonReentrant returns (FundAddresses memory addresses) {
        if (msg.sender != m.manager || m.manager.code.length != 0 || native.managerKey == 0) {
            revert InvalidSolanaBinding();
        }
        address predictedCore =
            _addressOf(_fundIdOf(m.hubChainId, p.creationNumber, m.manager), ROLE_CORE_VAULT, m.hubChainId);
        bytes32 digest = bindingDigest(native, predictedCore, binding.nonce, binding.expiry);
        uint256 nowTimestamp = block.timestamp;
        if (
            binding.nonce != bindingNonce[m.manager] || nowTimestamp > binding.expiry
                || ECDSA.recover(digest, binding.signature) != m.manager
        ) revert InvalidSolanaBinding();
        _validateNativeMandate(m, native);
        ++bindingNonce[m.manager];
        bindingCommitment[predictedCore] = digest;
        _pendingNative.program = native.program;
        _pendingNative.spoke = native.spoke;
        _pendingNative.usdcMint = native.usdcMint;
        _pendingNative.managerKey = native.managerKey;
        _pendingNative.chainId = native.chainId;
        for (uint256 index; index < native.assets.length; ++index) {
            _pendingNative.assets.push(native.assets[index]);
        }
        for (uint256 index; index < native.venues.length; ++index) {
            _pendingNative.venues.push(native.venues[index]);
        }
        addresses = _createFund(m, p);
        delete _pendingNative;
    }

    function bindingDigest(SolanaMandateV6.Config memory native, address fund, uint256 nonce, uint256 expiry)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    BINDING_TYPEHASH,
                    native.managerKey,
                    fund,
                    native.spoke,
                    native.chainId,
                    SolanaMandateV6.hash(native),
                    nonce,
                    expiry
                )
            )
        );
    }

    function _createFund(Mandate memory m, HubParams memory p) private returns (FundAddresses memory addresses) {
        uint256 chainId = block.chainid;
        // DEC-011: the Core Vault lives on the Mandate's Hub Chain only.
        if (m.hubChainId != chainId) revert NotHubChain(chainId, m.hubChainId);
        if (_coreVaultCreationCodeHash == bytes32(0) || _managerRegistry == address(0) || _priceSource == address(0)) {
            revert HubNotConfigured();
        }
        // DEC-001, DEC-002: permissionless; whoever creates the fund is its Manager.
        if (msg.sender != m.manager) revert NotManager(msg.sender, m.manager);
        if (m.usdc != _baseToken) revert BaseTokenMismatch(m.usdc, _baseToken);
        uint256 creationNumber = _nextCreationNumber();
        if (p.creationNumber != creationNumber) revert CreationNumberTaken(p.creationNumber, creationNumber);
        bytes32 codeHash = keccak256(p.coreVaultCreationCode);
        if (codeHash != _coreVaultCreationCodeHash) {
            revert ForeignCreationCode(ROLE_CORE_VAULT, codeHash, _coreVaultCreationCodeHash);
        }
        bytes32 fundId = _fundIdOf(chainId, creationNumber, m.manager);
        _requirePredictedAddresses(m, fundId);

        addresses = _hubAddresses(creationNumber, fundId, chainId);
        // Effects before the deployments (checks-effects-interactions).
        ++_fundCount;
        isFund[addresses.coreVault] = true;
        fundByNumber[creationNumber] = addresses.coreVault;

        // Adapters first: the Spoke Vault and the Core Vault read them in their constructors.
        addresses.chains = new ChainAddresses[](1);
        addresses.chains[0] = _deployChainAdapters(m, fundId, chainId, addresses.coreVault, p.uniswapV4Pools);
        // The hub Spoke Vault publishes no report, so it takes no Wormhole Core (DEC-054).
        _deploySpokeVault(m, fundId, chainId, addresses.coreVault, address(0));
        _deploy(fundId, ROLE_NATIVE_REGISTRY, chainId, abi.encode(_pendingNative));
        address registry = _addressOf(fundId, ROLE_NATIVE_REGISTRY, chainId);
        _deploy(
            fundId,
            ROLE_VALUE_REPORT_RECEIVER,
            chainId,
            abi.encode(_wormholeCore, addresses.coreVault, fundId, m.spokes, registry)
        );
        _deployCoreVault(m, addresses, p.coreVaultCreationCode);
        _seed(addresses.coreVault, p.seedAmount);

        emit FundCreated(creationNumber, fundId, m.manager, m.hash(), addresses);
    }

    /// @inheritdoc IFundFactory
    function createSpoke(uint256 creationNumber, Mandate memory m, SpokeParams memory p)
        external
        nonReentrant
        returns (ChainAddresses memory addresses)
    {
        // DEC-001, DEC-002: only the fund's Manager creates its spokes.
        if (msg.sender != m.manager) revert NotManager(msg.sender, m.manager);
        bytes32 mandateHash = m.hash();
        if (mandateHash != p.mandateHash) revert MandateHashMismatch(mandateHash, p.mandateHash);
        uint256 chainId = block.chainid;
        // DEC-011, DEC-054: the fund id is derived, never given, and never one this factory derives for its own
        // `createFund`, so a spoke can never consume the hub salts of a future fund here. DEC-001, FF-OQ-1: it binds
        // the Manager, so only the fund's own Manager reaches the addresses the hub's Mandate names.
        if (m.hubChainId == chainId) revert SpokeOnHubChain(chainId);
        bytes32 fundId = _fundIdOf(m.hubChainId, creationNumber, m.manager);
        // Reverts UnknownSpokeChain when this chain is not a Mandate spoke (the Hub Chain included).
        (, SpokeConfig memory spoke) = m.spokeByChainId(chainId);
        if (spoke.wormholeChainId == 1) revert NativeCreationRequired();
        if (spoke.spokeToken != _baseToken) revert BaseTokenMismatch(spoke.spokeToken, _baseToken);
        _requirePredictedAddresses(m, fundId);
        address spokeVault = _addressOf(fundId, ROLE_SPOKE_VAULT, chainId);
        if (spokeVault.code.length != 0) revert SpokeAlreadyCreated(fundId, spokeVault);

        addresses = _deployChainAdapters(m, fundId, chainId, spokeVault, p.uniswapV4Pools);
        _deploySpokeVault(m, fundId, chainId, _addressOf(fundId, ROLE_CORE_VAULT, m.hubChainId), _wormholeCore);

        emit SpokeCreated(fundId, chainId, m.manager, mandateHash, addresses);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFundFactory
    function nextCreationNumber() external view returns (uint256) {
        return _nextCreationNumber();
    }

    /// @inheritdoc IFundFactory
    function fundIdOf(uint256 hubChainId, uint256 creationNumber, address manager) external view returns (bytes32) {
        return _fundIdOf(hubChainId, creationNumber, manager);
    }

    /// @inheritdoc IFundFactory
    function saltOf(bytes32 fundId, bytes32 role, uint256 chainId) public pure returns (bytes32) {
        return keccak256(abi.encode(fundId, role, chainId));
    }

    /// @inheritdoc IFundFactory
    function addressOf(bytes32 fundId, bytes32 role, uint256 chainId) external view returns (address) {
        return _addressOf(fundId, role, chainId);
    }

    /// @inheritdoc IFundFactory
    function predictAddresses(uint256 creationNumber, address manager, uint256[] calldata chainIds)
        external
        view
        returns (FundAddresses memory addresses)
    {
        addresses = _hubAddresses(creationNumber, _fundIdOf(block.chainid, creationNumber, manager), block.chainid);
        addresses.chains = new ChainAddresses[](chainIds.length);
        for (uint256 i; i < chainIds.length; ++i) {
            addresses.chains[i] = _chainAddresses(addresses.fundId, chainIds[i]);
        }
    }

    /// @inheritdoc IFundFactory
    function wiring() external view returns (ProtocolWiring memory w) {
        w.numberOffset = NUMBER_OFFSET;
        w.baseToken = _baseToken;
        w.acrossSpokePool = _acrossSpokePool;
        w.wormholeCore = _wormholeCore;
        w.uniswapV4PoolManager = _uniswapV4PoolManager;
        w.uniswapV4PositionManager = _uniswapV4PositionManager;
        w.uniswapV4StateView = _uniswapV4StateView;
        w.permit2 = _permit2;
        w.aaveV3Pool = _aaveV3Pool;
        w.uniswapV3Factory = _uniswapV3Factory;
        w.uniswapV3SwapRouter02 = _uniswapV3SwapRouter02;
        w.uniswapV3QuoterV2 = _uniswapV3QuoterV2;
        w.apiSigner = _apiSigner;
        w.managerRegistry = _managerRegistry;
        w.priceSource = _priceSource;
        w.protocolRecipient = _protocolRecipient;
        w.guardian = _guardian;
        w.flowFeeBps = _flowFeeBps;
        w.coreVaultLogic = _coreVaultLogic;
        w.coreVaultCreationCodeHash = _coreVaultCreationCodeHash;
        w.spokeCrossChainLib = _spokeCrossChainLib;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Addresses
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Q59 stance: numbers start after NUMBER_OFFSET.
    function _nextCreationNumber() private view returns (uint256) {
        return NUMBER_OFFSET + _fundCount + 1;
    }

    /// @dev Q59 stance with the Manager bound in (DEC-001, FF-OQ-1): every fund address is a function of the fund id,
    ///      so binding the Manager means only the Manager's key can create a contract at any of them, on any chain.
    function _fundIdOf(uint256 hubChainId, uint256 creationNumber, address manager) private view returns (bytes32) {
        return keccak256(abi.encode(hubChainId, address(this), creationNumber, manager));
    }

    function _addressOf(bytes32 fundId, bytes32 role, uint256 chainId) private view returns (address) {
        return Create3.addressOf(address(this), saltOf(fundId, role, chainId));
    }

    function _hubAddresses(uint256 creationNumber, bytes32 fundId, uint256 hubChainId)
        private
        view
        returns (FundAddresses memory a)
    {
        a.creationNumber = creationNumber;
        a.fundId = fundId;
        a.coreVault = _addressOf(fundId, ROLE_CORE_VAULT, hubChainId);
        // The Core Vault's constructor creates the ShareToken, then the ManagerFeeVault (CoreVaultBase).
        a.shareToken = Create3.createAddress(a.coreVault, 1);
        a.managerFeeVault = Create3.createAddress(a.coreVault, 2);
        a.valueReportReceiver = _addressOf(fundId, ROLE_VALUE_REPORT_RECEIVER, hubChainId);
    }

    function _chainAddresses(bytes32 fundId, uint256 chainId) private view returns (ChainAddresses memory c) {
        c.chainId = chainId;
        c.spokeVault = _addressOf(fundId, ROLE_SPOKE_VAULT, chainId);
        c.uniswapV4Adapter = _addressOf(fundId, ROLE_UNISWAP_V4_ADAPTER, chainId);
        c.aaveV3Adapter = _addressOf(fundId, ROLE_AAVE_V3_ADAPTER, chainId);
        c.acrossBridgeAdapter = _addressOf(fundId, ROLE_ACROSS_BRIDGE_ADAPTER, chainId);
        c.uniswapV3SwapAdapter = _addressOf(fundId, ROLE_UNISWAP_V3_SWAP_ADAPTER, chainId);
    }

    /// @dev DEC-053, DEC-054, DEC-086, DEC-087: every address the Mandate lists, on every chain, must be the fund's own
    ///      predicted contract, so a Mandate can only name contracts this factory deploys under this fund id (the
    ///      Spoke Vault is the report emitter and the bridge recipient the hub trusts).
    function _requirePredictedAddresses(Mandate memory m, bytes32 fundId) private view {
        for (uint256 i; i < m.adapters.length; ++i) {
            uint256 chainId = m.adapters[i].chainId;
            if (chainId == _nativeChain(m)) continue;
            address adapter = m.adapters[i].adapter;
            if (
                adapter != _addressOf(fundId, ROLE_UNISWAP_V4_ADAPTER, chainId)
                    && adapter != _addressOf(fundId, ROLE_AAVE_V3_ADAPTER, chainId)
            ) revert UnexpectedAdapter(chainId, adapter);
        }
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            uint256 chainId = m.bridgeAdapters[i].chainId;
            if (m.bridgeAdapters[i].spokeChainId == _nativeChain(m)) continue;
            address adapter = m.bridgeAdapters[i].adapter;
            if (adapter != _addressOf(fundId, ROLE_ACROSS_BRIDGE_ADAPTER, chainId)) {
                revert UnexpectedBridgeAdapter(chainId, adapter);
            }
        }
        // DEC-136: the alpha's only swap adapter is the fund's own Uniswap V3 swap adapter of each chain.
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            uint256 chainId = m.swapAdapters[i].chainId;
            if (chainId == _nativeChain(m)) continue;
            address adapter = m.swapAdapters[i].adapter;
            if (adapter != _addressOf(fundId, ROLE_UNISWAP_V3_SWAP_ADAPTER, chainId)) {
                revert UnexpectedSwapAdapter(chainId, adapter);
            }
        }
        for (uint256 i; i < m.spokes.length; ++i) {
            SpokeConfig memory s = m.spokes[i];
            if (s.wormholeChainId == 1) continue;
            bytes32 predicted = bytes32(uint256(uint160(_addressOf(fundId, ROLE_SPOKE_VAULT, s.chainId))));
            if (s.spokeVault != predicted) revert SpokeVaultMismatch(s.chainId, predicted, s.spokeVault);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Deploys the adapters the Mandate lists on `chainId`: Uniswap V4, Aave V3 and the Uniswap V3 swap adapter
    ///      owned by this chain's Spoke Vault (DEC-054, DEC-136), Across owned by `bridgeVault` (the Core Vault on the
    ///      hub, which sends to spokes; the Spoke Vault on a spoke, which sends home; DEC-087). A role the Mandate does
    ///      not list here is not deployed and is address(0) in the result.
    function _deployChainAdapters(
        Mandate memory m,
        bytes32 fundId,
        uint256 chainId,
        address bridgeVault,
        PoolKey[] memory uniswapV4Pools
    ) private returns (ChainAddresses memory c) {
        c = _chainAddresses(fundId, chainId);
        if (m.isAdapter(chainId, c.uniswapV4Adapter)) {
            _deployUniswapV4Adapter(m, fundId, chainId, c, uniswapV4Pools);
        } else {
            if (uniswapV4Pools.length != 0) revert PoolKeyCountMismatch(0, uniswapV4Pools.length);
            c.uniswapV4Adapter = address(0);
        }
        if (m.isAdapter(chainId, c.aaveV3Adapter)) {
            _deployAaveV3Adapter(m, fundId, chainId, c);
        } else {
            c.aaveV3Adapter = address(0);
        }
        if (m.isSwapAdapter(chainId, c.uniswapV3SwapAdapter)) {
            _deployUniswapV3SwapAdapter(m, fundId, chainId, c);
        } else {
            c.uniswapV3SwapAdapter = address(0);
        }
        if (m.isBridgeAdapter(chainId, c.acrossBridgeAdapter)) {
            // DEC-066: the adapter constructor reverts FillDeadlineBufferTooShort on a SpokePool below 6 h; Create3
            // bubbles it as this call's revert reason.
            _deploy(fundId, ROLE_ACROSS_BRIDGE_ADAPTER, chainId, abi.encode(bridgeVault, _guardian, _acrossSpokePool));
        } else {
            c.acrossBridgeAdapter = address(0);
        }
    }

    /// @dev DEC-030: the adapter's closed pool list is exactly the Mandate's pools for it, in Mandate order, each
    ///      `PoolKey` hashing to the listed id. OQ-12: hooked pools are registered but inoperable; the Spoke Vault's
    ///      constructor rejects them through `poolTokens`.
    function _deployUniswapV4Adapter(
        Mandate memory m,
        bytes32 fundId,
        uint256 chainId,
        ChainAddresses memory c,
        PoolKey[] memory pools
    ) private {
        if (_uniswapV4PoolManager == address(0)) {
            revert ProtocolNotOnChain(ROLE_UNISWAP_V4_ADAPTER);
        }
        uint256 matched;
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory pc = m.pools[i];
            if (pc.chainId != chainId || pc.adapter != c.uniswapV4Adapter) continue;
            if (matched == pools.length) revert PoolKeyCountMismatch(matched + 1, pools.length);
            bytes32 poolId = PoolId.unwrap(pools[matched].toId());
            if (poolId != pc.poolKey) revert PoolKeyMismatch(matched, pc.poolKey, poolId);
            ++matched;
        }
        if (matched != pools.length) revert PoolKeyCountMismatch(matched, pools.length);
        _deploy(
            fundId,
            ROLE_UNISWAP_V4_ADAPTER,
            chainId,
            abi.encode(
                c.spokeVault,
                _guardian,
                _uniswapV4PoolManager,
                _uniswapV4PositionManager,
                _uniswapV4StateView,
                _permit2,
                pools
            )
        );
    }

    /// @dev DEC-018, DEC-028: supply-only Aave V3; the reserve assets are the Mandate's pool keys for the adapter
    ///      (`bytes32(uint256(uint160(asset)))`, the adapter's pool key encoding), in Mandate order.
    function _deployAaveV3Adapter(Mandate memory m, bytes32 fundId, uint256 chainId, ChainAddresses memory c) private {
        if (_aaveV3Pool == address(0)) revert ProtocolNotOnChain(ROLE_AAVE_V3_ADAPTER);
        address[] memory assets = new address[](m.pools.length);
        uint256 count;
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory pc = m.pools[i];
            if (pc.chainId != chainId || pc.adapter != c.aaveV3Adapter) continue;
            if (uint256(pc.poolKey) > type(uint160).max) revert InvalidAavePoolKey(pc.poolKey);
            assets[count++] = address(uint160(uint256(pc.poolKey)));
        }
        assembly ("memory-safe") {
            mstore(assets, count)
        }
        _deploy(fundId, ROLE_AAVE_V3_ADAPTER, chainId, abi.encode(c.spokeVault, _guardian, _aaveV3Pool, assets));
    }

    /// @dev DEC-136 (closing note: only the Uniswap swap adapter in the alpha), DEC-153: the adapter swaps only this
    ///      chain's Mandate tokens (item 2), pays every output to this chain's Spoke Vault and accepts routes signed by
    ///      the API key of this chain's wiring (reading D-01; zero: no API routes, DEC-052). Its constructor checks
    ///      that the router and the quoter answer for the factory given (`WiringMismatch`) and that the chain's base
    ///      token is a Mandate token.
    function _deployUniswapV3SwapAdapter(Mandate memory m, bytes32 fundId, uint256 chainId, ChainAddresses memory c)
        private
    {
        if (_uniswapV3Factory == address(0)) revert ProtocolNotOnChain(ROLE_UNISWAP_V3_SWAP_ADAPTER);
        _deploy(
            fundId,
            ROLE_UNISWAP_V3_SWAP_ADAPTER,
            chainId,
            abi.encode(
                c.spokeVault,
                _guardian,
                _baseToken,
                m.tokensOf(chainId),
                _uniswapV3Factory,
                _uniswapV3SwapRouter02,
                _uniswapV3QuoterV2,
                _apiSigner
            )
        );
    }

    /// @dev DEC-054: one Spoke Vault per fund chain, the Hub Chain included. `wormholeCore` is zero on the hub.
    ///      DEC-096, DEC-101, DEC-116: swept excess goes to the Protocol Recipient, the fee wallet.
    function _deploySpokeVault(
        Mandate memory m,
        bytes32 fundId,
        uint256 chainId,
        address coreVault,
        address wormholeCore
    ) private {
        _deploy(
            fundId,
            ROLE_SPOKE_VAULT,
            chainId,
            abi.encode(
                m,
                fundId,
                chainId,
                coreVault,
                _baseToken,
                _acrossSpokePool,
                wormholeCore,
                transitEscrowImplementation,
                _protocolRecipient
            )
        );
    }

    /// @dev Q59 stance: name `Pool Party Fund {n}`, symbol `PP-{n}`, never manager text. The hub income tokens are the
    ///      Mandate's hub tokens, read by the Core Vault itself (WP-07 B2; was CV-OQ-3's `poolTokens` read here).
    ///      DEC-106: flow fee and Protocol Recipient are protocol wiring. DEC-127: this factory is the Core Vault's
    ///      only seeder. The fee bounds are the Mandate's own (DEC-182, DEC-184), checked by the Core Vault.
    function _deployCoreVault(Mandate memory m, FundAddresses memory a, bytes memory creationCode) private {
        uint256 chainId = block.chainid;
        CoreVaultConfig memory c;
        c.fundId = a.fundId;
        c.usdc = _baseToken;
        c.hubSpokeVault = a.chains[0].spokeVault;
        c.reportReceiver = a.valueReportReceiver;
        c.managerRegistry = _managerRegistry;
        c.priceSource = _priceSource;
        c.acrossSpokePool = _acrossSpokePool;
        c.wormholeCore = _wormholeCore;
        c.protocolRecipient = _protocolRecipient;
        c.excessRecipient = _protocolRecipient;
        c.escrowImplementation = transitEscrowImplementation;
        c.flowFeeBps = _flowFeeBps;
        c.factory = address(this);
        string memory number = Strings.toString(a.creationNumber);
        c.shareName = string.concat("Pool Party Fund ", number);
        c.shareSymbol = string.concat("PP-", number);
        address registry = _addressOf(a.fundId, ROLE_NATIVE_REGISTRY, chainId);
        Create3.deploy(
            saltOf(a.fundId, ROLE_CORE_VAULT, chainId), abi.encodePacked(creationCode, abi.encode(m, c, registry))
        );
    }

    /// @dev DEC-127, DEC-061, DEC-113: the manager's seed. The factory pulls exactly what the seed costs at the initial
    ///      Share Price (the flow fee plus the whole shares it buys; the sub-share remainder never leaves the manager,
    ///      DEC-035), approves the Core Vault for exactly that and calls `seed`, which pulls it back to zero allowance.
    ///      The Core Vault enforces `minFirstDeposit` and the one-share floor.
    function _seed(address coreVault, uint256 seedAmount) private {
        (, uint256 usdcForShares, uint256 fee) =
            ShareMath.previewDeposit(seedAmount, _flowFeeBps, ShareMath.INITIAL_SHARE_PRICE);
        uint256 cost = usdcForShares + fee;
        IERC20(_baseToken).safeTransferFrom(msg.sender, address(this), cost);
        IERC20(_baseToken).forceApprove(coreVault, cost);
        ICoreVaultLifecycle(coreVault).seed(seedAmount);
    }

    /// @dev CREATE3 at the fund's predicted address for `role` on `chainId`, from the stored creation code.
    function _deploy(bytes32 fundId, bytes32 role, uint256 chainId, bytes memory args) private {
        if (creationCodeHash[role] == bytes32(0)) revert RoleNotConfigured(role);
        Create3.deploy(saltOf(fundId, role, chainId), abi.encodePacked(CodeStore.read(_codeStores[role]), args));
    }

    function _nativeChain(Mandate memory m) private pure returns (uint256) {
        for (uint256 index; index < m.spokes.length; ++index) {
            if (m.spokes[index].wormholeChainId == 1) return m.spokes[index].chainId;
        }
        revert NativeCreationRequired();
    }

    /// @dev DEC-188, DEC-192: native identity remains bytes32; aliases serve legacy accounting only.
    function _validateNativeMandate(Mandate memory m, SolanaMandateV6.Config memory native) private pure {
        if (m.hubChainId != 42_161 || _nativeChain(m) != native.chainId || native.chainId == m.hubChainId) {
            revert InvalidSolanaBinding();
        }
        uint256 nativeCount;
        for (uint256 index; index < m.spokes.length; ++index) {
            SpokeConfig memory spoke = m.spokes[index];
            if (spoke.maxReportAge != m.spokes[0].maxReportAge) revert InvalidSolanaBinding();
            if (spoke.wormholeChainId != 1) continue;
            ++nativeCount;
            if (spoke.spokeVault != native.spoke || spoke.spokeToken != SolanaMandateV6.accountingId(native.usdcMint)) {
                revert InvalidSolanaBinding();
            }
        }
        if (nativeCount != 1) revert InvalidSolanaBinding();
        uint256 tokenCount;
        for (uint256 index; index < m.tokens.length; ++index) {
            if (m.tokens[index].chainId != native.chainId) {
                for (uint256 assetIndex; assetIndex < native.assets.length; ++assetIndex) {
                    if (m.tokens[index].token == native.assets[assetIndex].accountingId) revert InvalidSolanaBinding();
                }
                continue;
            }
            ++tokenCount;
            bool found;
            for (uint256 assetIndex; assetIndex < native.assets.length; ++assetIndex) {
                if (m.tokens[index].token == native.assets[assetIndex].accountingId) found = true;
            }
            if (!found) revert InvalidSolanaBinding();
        }
        if (tokenCount != native.assets.length) revert InvalidSolanaBinding();
    }
}
