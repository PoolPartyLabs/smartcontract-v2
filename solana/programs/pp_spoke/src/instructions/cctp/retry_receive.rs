use crate::errors::SpokeError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-191: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct RetryReceive<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T1b must constrain the approved Circle V2 executable and all remaining CPI accounts.
    pub cctp_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<RetryReceive>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
