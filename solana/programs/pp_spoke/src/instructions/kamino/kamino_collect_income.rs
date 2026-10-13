use crate::errors::SpokeError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-068, DEC-193: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct KaminoCollectIncome<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T3 must constrain klend, market, reserve and token CPI relationships.
    pub kamino_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<KaminoCollectIncome>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
