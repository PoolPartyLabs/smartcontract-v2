use super::guards::{require_fund_address, require_manager, CoreError};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-188, DEC-190, DEC-195: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct RefreshIncomeResults<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<RefreshIncomeResults>, payload: Vec<u8>) -> Result<()> {
    require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    require_manager(
        &ctx.accounts.fund,
        &ctx.accounts.authority.to_account_info(),
    )?;
    require!(payload.is_empty(), CoreError::InvalidConfiguration);
    // TODO(interface): DEC-122 requires authenticated adapter collection result accounts.
    err!(CoreError::AdapterNotIntegrated)
}
