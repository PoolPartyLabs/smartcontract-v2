use super::guards::{require_fund_address, require_manager, CoreError};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-055, DEC-190: fixed Manager guard; no sweep without sealed recipient policy.
#[derive(Accounts)]
pub struct SweepExcess<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: no vault CPI is enabled until the excess recipient is committed.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<SweepExcess>, payload: Vec<u8>) -> Result<()> {
    require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    require_manager(
        &ctx.accounts.fund,
        &ctx.accounts.authority.to_account_info(),
    )?;
    require!(payload.is_empty(), CoreError::InvalidConfiguration);
    // TODO(decision): DEC-055 requires sealed garbage-collector recipient wiring, never Manager custody.
    err!(CoreError::ExcessRecipientNotConfigured)
}
