use super::snapshot::{encoded_snapshot, ReportError};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct BuildReport<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T1 must constrain the canonical bridge and authenticated posted VAA accounts.
    pub wormhole_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<BuildReport>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty(), ReportError::InvalidAccounts);
    let encoded = encoded_snapshot(
        &ctx.accounts.fund,
        ctx.accounts.fund.key(),
        ctx.remaining_accounts,
        &Clock::get()?,
    )?;
    require!(encoded.len() <= 1024, ReportError::ReportTooLarge);
    anchor_lang::solana_program::program::set_return_data(&encoded);
    Ok(())
}
