use super::guards::{require_fund_address, require_manager, CoreError};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-190, DEC-193: fixed Manager guard precedes pending adapter dispatch.
#[derive(Accounts)]
pub struct CollectIncomeAll<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: no vault CPI is enabled until bounded adapter dispatch is integrated.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<CollectIncomeAll>, payload: Vec<u8>) -> Result<()> {
    require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    require_manager(
        &ctx.accounts.fund,
        &ctx.accounts.authority.to_account_info(),
    )?;
    require!(payload.is_empty(), CoreError::InvalidConfiguration);
    // TODO(interface): DEC-122, DEC-193 require bounded T3/T4 collection and result dispatch.
    err!(CoreError::AdapterNotIntegrated)
}
