use super::snapshot::{encoded_snapshot, ReportError};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-093, DEC-192: permissionless complete snapshot, never caller-supplied value.
#[derive(Accounts)]
pub struct BuildReport<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: compatibility account only; snapshot independently derives the custody PDA.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: compatibility account only; snapshot performs no bridge CPI.
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
