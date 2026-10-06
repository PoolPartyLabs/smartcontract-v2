use crate::state::FundState;
use anchor_lang::prelude::*;

#[error_code]
pub enum CoreError {
    InvalidBinding,
    BindingExpired,
    InvalidConfiguration,
    UnauthorizedManager,
    FundClosed,
    ArithmeticOverflow,
    InsufficientRecordedBalance,
    InvalidCustody,
    BootstrapNotAuthenticated,
    AdapterNotIntegrated,
    ExcessRecipientNotConfigured,
}

/// DEC-190: direct signer authority is fixed per Fund, never a keeper or CPI caller.
pub fn require_manager(fund: &FundState, signer: &AccountInfo) -> Result<()> {
    require!(
        signer.is_signer && *signer.key == fund.manager_solana,
        CoreError::UnauthorizedManager
    );
    require!(!fund.closed, CoreError::FundClosed);
    Ok(())
}

pub fn require_fund_address(fund: &FundState, address: &Pubkey) -> Result<()> {
    let expected = Pubkey::create_program_address(
        &[
            b"fund",
            &fund.hub_core,
            &fund.spoke_index.to_le_bytes(),
            &[fund.bump],
        ],
        &crate::ID,
    )
    .map_err(|_| error!(CoreError::InvalidConfiguration))?;
    require_keys_eq!(*address, expected, CoreError::InvalidConfiguration);
    Ok(())
}
