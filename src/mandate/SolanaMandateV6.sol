pragma solidity 0.8.28;

import {ReportCodecV6} from "../libraries/ReportCodecV6.sol";

/// @notice Immutable native identity commitment accompanying the EVM Mandate (DEC-188, DEC-190).
library SolanaMandateV6 {
    struct Asset {
        bytes32 mint;
        address accountingId;
        bool stock;
    }

    struct Venue {
        bytes32 program;
        bytes32 pool;
        bytes32 reserve;
        bytes32 token0;
        bytes32 token1;
    }

    struct Config {
        bytes32 program;
        bytes32 spoke;
        bytes32 usdcMint;
        bytes32 managerKey;
        /// @dev TODO(decision): canonical accounting chain namespace; distinct from Circle/Wormhole IDs.
        uint256 chainId;
        Asset[] assets;
        Venue[] venues;
    }

    /// @dev Namespaced accounting aliases, not truncated public keys; collisions are refused by the registry.
    function accountingId(bytes32 mint) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("PoolParty/SolanaAsset/v6", uint16(1), mint)))));
    }

    function hash(Config memory config) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(6), config));
    }
}

/// @notice Per-Fund closed Solana mint and venue registry (DEC-053, DEC-188, DEC-193).
contract SolanaSpokeRegistryV6 {
    bytes32 public immutable nativeMandateHash;
    bytes32 public immutable managerKey;
    bytes32 public immutable spoke;
    bytes32 public immutable program;
    uint256 public immutable chainId;
    mapping(bytes32 mint => address) public accountingId;
    mapping(bytes32 mint => bool) public stock;
    mapping(bytes32 venueKey => bool) private _venues;
    SolanaMandateV6.Config private _config;

    error InvalidNativeConfig();
    error UnknownMint(bytes32 mint);
    error UnknownVenue();
    error UnsafeStockState(bytes32 mint);

    constructor(SolanaMandateV6.Config memory config) {
        if (
            config.program == 0 || config.spoke == 0 || config.managerKey == 0 || config.usdcMint == 0
                || config.chainId == 0 || config.assets.length == 0 || config.venues.length == 0
                || config.usdcMint != 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61
        ) revert InvalidNativeConfig();
        nativeMandateHash = SolanaMandateV6.hash(config);
        managerKey = config.managerKey;
        spoke = config.spoke;
        program = config.program;
        chainId = config.chainId;
        _config.program = config.program;
        _config.spoke = config.spoke;
        _config.usdcMint = config.usdcMint;
        _config.managerKey = config.managerKey;
        _config.chainId = config.chainId;
        for (uint256 index; index < config.assets.length; ++index) {
            SolanaMandateV6.Asset memory asset = config.assets[index];
            if (
                asset.mint == 0 || asset.accountingId == address(0) || accountingId[asset.mint] != address(0)
                    || asset.accountingId != SolanaMandateV6.accountingId(asset.mint)
            ) revert InvalidNativeConfig();
            bool isStock = asset.mint == 0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a;
            bool isUsdc = asset.mint == 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
            bool isWrappedSol = asset.mint == 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001;
            if ((!isStock && !isUsdc && !isWrappedSol) || asset.stock != isStock) revert InvalidNativeConfig();
            for (uint256 prior; prior < index; ++prior) {
                if (config.assets[prior].accountingId == asset.accountingId) revert InvalidNativeConfig();
            }
            accountingId[asset.mint] = asset.accountingId;
            stock[asset.mint] = asset.stock;
            _config.assets.push(asset);
        }
        token(config.usdcMint);
        if (stock[config.usdcMint]) revert InvalidNativeConfig();
        for (uint256 index; index < config.venues.length; ++index) {
            SolanaMandateV6.Venue memory venue = config.venues[index];
            if (venue.program == 0 || (venue.pool == 0) == (venue.reserve == 0)) revert InvalidNativeConfig();
            token(venue.token0);
            if (venue.token1 != 0) token(venue.token1);
            bytes32 key = keccak256(abi.encode(venue));
            if (_venues[key]) revert InvalidNativeConfig();
            _venues[key] = true;
            _config.venues.push(venue);
        }
    }

    function nativeConfig() external view returns (SolanaMandateV6.Config memory) {
        return _config;
    }

    function token(bytes32 mint) public view returns (address identity) {
        identity = accountingId[mint];
        if (identity == address(0)) revert UnknownMint(mint);
    }

    function validatePosition(ReportCodecV6.Position memory position) external view {
        SolanaMandateV6.Venue memory venue =
            SolanaMandateV6.Venue(position.program, position.pool, position.reserve, position.token0, position.token1);
        if (!_venues[keccak256(abi.encode(venue))] || position.position == 0) revert UnknownVenue();
        if (position.reserve != 0) {
            if (
                position.token1 != 0 || position.liquidity != 0 || position.tickLower != 0 || position.tickUpper != 0
                    || position.principal1 != 0 || position.income1 != 0
            ) {
                revert UnknownVenue();
            }
        } else if (
            position.token1 == 0 || position.tickLower >= position.tickUpper || position.tickLower < -443_636
                || position.tickUpper > 443_636 || position.liquidity == 0
        ) {
            revert UnknownVenue();
        }
    }

    /// @dev DEC-194: unit-multiplier demo guard; no unauthenticated scalar and no mixed corporate-action pricing.
    function validateMintStates(ReportCodecV6.MintState[] memory states) external view {
        for (uint256 index; index < _config.assets.length; ++index) {
            bytes32 mint = _config.assets[index].mint;
            if (!stock[mint]) continue;
            uint256 matches;
            for (uint256 stateIndex; stateIndex < states.length; ++stateIndex) {
                ReportCodecV6.MintState memory state = states[stateIndex];
                if (state.mint != mint) continue;
                ++matches;
                if (
                    state.multiplierBits != 0x3ff0000000000000 || state.newMultiplierBits != 0x3ff0000000000000
                        || state.paused || state.frozen || state.transferHook != 0
                ) revert UnsafeStockState(mint);
            }
            if (matches != 1) revert UnsafeStockState(mint);
        }
    }
}
