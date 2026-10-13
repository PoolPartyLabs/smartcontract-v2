use super::{custody, guards::{require_fund_address, require_manager, CoreError}};
use crate::state::{FundState, TokenLedger};
use anchor_lang::prelude::*;

/// DEC-053, DEC-190, DEC-193: every adapter consumes the same sealed admission.
pub fn manager(fund: &Account<FundState>, signer: &AccountInfo) -> Result<()> {
    require_fund_address(fund, &fund.key())?;
    require!(fund.active_command == Pubkey::default() && !fund.close_requested,
        CoreError::InvalidConfiguration);
    require_manager(fund, signer)
}

pub fn venue(fund: &FundState, program: Pubkey, pool: Pubkey, reserve: Pubkey) -> Result<()> {
    require!(fund.venues.iter().any(|venue| venue.program == program && venue.pool == pool && venue.reserve == reserve), CoreError::InvalidConfiguration);
    Ok(())
}

pub fn read_ledger(account: &AccountInfo, fund: Pubkey, mint: Pubkey) -> Result<TokenLedger> {
    require!(account.is_writable, CoreError::InvalidCustody);
    require_keys_eq!(*account.owner, crate::ID, CoreError::InvalidCustody);
    let expected = Pubkey::find_program_address(&[b"ledger", fund.as_ref(), mint.as_ref()], &crate::ID).0;
    require_keys_eq!(*account.key, expected, CoreError::InvalidCustody);
    let ledger = TokenLedger::try_deserialize(&mut &account.try_borrow_data()?[..])?;
    require!(ledger.fund == fund && ledger.mint == mint, CoreError::InvalidCustody);
    Ok(ledger)
}

pub fn write_ledger(account: &AccountInfo, ledger: &TokenLedger) -> Result<()> {
    ledger.try_serialize(&mut &mut account.try_borrow_mut_data()?[..])
}

pub fn balance(ledger: &TokenLedger, token: &AccountInfo, vault: Pubkey) -> Result<()> {
    ledger.excess(custody::recorded_custody_balance(token, &vault, &ledger.mint)?)?;
    Ok(())
}
