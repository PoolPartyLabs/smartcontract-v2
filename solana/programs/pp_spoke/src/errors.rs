use anchor_lang::prelude::*;

#[error_code]
pub enum SpokeError {
    #[msg("Scaffold instruction is not implemented; no state was changed")]
    NotImplemented,
}
