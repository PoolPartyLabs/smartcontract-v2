use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-120/151: accept a verified order; execution resumes through the command account.
#[derive(Accounts)]
pub struct ExecuteUnwindOrder<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T1 must constrain the canonical bridge and authenticated posted VAA accounts.
    pub wormhole_program: UncheckedAccount<'info>,
    /// CHECK: exact canonical, guardian-verified PostedVAA validated by verify_order.
    pub posted_vaa: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, ExecuteUnwindOrder<'info>>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty(), super::snapshot::ReportError::InvalidOrder);
    super::commands::accept(&mut ctx.accounts.fund, &ctx.accounts.authority, &ctx.accounts.posted_vaa,
        &ctx.accounts.system_program.to_account_info(), ctx.remaining_accounts, 1)
}
