use super::orders::verify_order;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-191, DEC-192: authenticated arrival ACKs reconcile transit state; other commands fail closed.
#[derive(Accounts)]
pub struct ExecuteOrder<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: compatibility account only; ACK reconciliation does not use this account.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: compatibility account only; verify_order pins the PostedVAA owner and PDA directly.
    pub wormhole_program: UncheckedAccount<'info>,
    /// CHECK: exact canonical, guardian-verified PostedVAA validated by verify_order.
    pub posted_vaa: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<ExecuteOrder>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty(), super::snapshot::ReportError::InvalidOrder);
    verify_order(
        &ctx.accounts.fund,
        ctx.accounts.fund.key(),
        &ctx.accounts.posted_vaa.to_account_info(),
        None,
        Clock::get()?.unix_timestamp,
    )?;
    super::orders::execute_acknowledgement(&mut ctx.accounts.fund, &ctx.accounts.posted_vaa, ctx.remaining_accounts)
}
