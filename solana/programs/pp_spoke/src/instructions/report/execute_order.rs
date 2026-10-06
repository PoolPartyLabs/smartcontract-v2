use super::orders::{dispatch_unavailable, verify_order};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct ExecuteOrder<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T1 must constrain the canonical bridge and authenticated posted VAA accounts.
    pub wormhole_program: UncheckedAccount<'info>,
    /// CHECK: exact canonical, guardian-verified PostedVAA validated by verify_order.
    pub posted_vaa: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<ExecuteOrder>, _payload: Vec<u8>) -> Result<()> {
    verify_order(
        &ctx.accounts.fund,
        ctx.accounts.fund.key(),
        &ctx.accounts.posted_vaa.to_account_info(),
        None,
        Clock::get()?.unix_timestamp,
    )?;
    dispatch_unavailable()
}
