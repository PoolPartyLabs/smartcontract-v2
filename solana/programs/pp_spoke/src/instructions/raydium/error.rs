use anchor_lang::prelude::*;

#[error_code]
pub enum RaydiumError {
    #[msg("Invalid pinned Raydium account or relationship")]
    InvalidAccount,
    #[msg("Manager is not authorized for this Fund")]
    Unauthorized,
    #[msg("Missing creation-time Raydium Mandate admission")]
    InvalidPolicy,
    #[msg("Invalid tick range or liquidity guard")]
    InvalidRange,
    #[msg("Malformed instruction or external account data")]
    InvalidData,
    #[msg("Unsupported or changed Token-2022 extension")]
    UnsupportedExtension,
    #[msg("Arithmetic overflow")]
    Arithmetic,
    #[msg("Liquidity or token balance postcondition failed")]
    Slippage,
    #[msg("Farm reward claim is prohibited")]
    RewardClaim,
    #[msg("Position is not empty")]
    PositionNotEmpty,
}
