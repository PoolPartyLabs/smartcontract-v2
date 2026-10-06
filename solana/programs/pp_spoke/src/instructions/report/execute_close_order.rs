use crate::errors::SpokeError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct ExecuteCloseOrder<'info> {
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

pub fn handler(_ctx: Context<ExecuteCloseOrder>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
