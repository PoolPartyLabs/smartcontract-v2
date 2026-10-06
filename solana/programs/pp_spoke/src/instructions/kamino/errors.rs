use anchor_lang::prelude::*;

#[error_code(offset = 7300)]
pub enum KaminoError {
    #[msg("Only the fixed per-Fund Manager Solana Key may operate")]
    Unauthorized,
    #[msg("Fund is closed or Kamino entry is not authorized by its immutable Mandate")]
    EntryDisabled,
    #[msg("Invalid Kamino program")]
    WrongProgram,
    #[msg("Only the pinned main-market USDC reserve is supported")]
    WrongReserve,
    #[msg("Unsupported protocol account layout")]
    InvalidLayout,
    #[msg("Vault token account, mint, authority or delegate is invalid")]
    InvalidTokenAccount,
    #[msg("Reserve must be refreshed atomically in this slot")]
    StaleReserve,
    #[msg("Arithmetic overflow or inconsistent accounting")]
    MathOverflow,
    #[msg("Malformed payload or zero amount")]
    InvalidAmount,
    #[msg("Insufficient authenticated principal credits; donations cannot be supplied")]
    InsufficientPrincipal,
    #[msg("Recorded collateral exceeds the vault balance")]
    MissingCollateral,
    #[msg("Unexpected token delta or minimum liquidity not met")]
    UnexpectedDelta,
    #[msg("A pending redemption must be retried unchanged before supplying")]
    PendingWithdrawal,
}
