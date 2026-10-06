use crate::errors::SpokeError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-193, DEC-194: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct RaydiumOpenPosition<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: T4 must constrain CLMM, pinned pool, ticks, vaults and position NFT custody.
    pub raydium_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<RaydiumOpenPosition>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
