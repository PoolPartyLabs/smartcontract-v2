use crate::errors::SpokeError;
use anchor_lang::prelude::*;

/// DEC-188, DEC-190, DEC-195: provisional accounts; no CPI or state mutation is authorized by this stub.
#[derive(Accounts)]
pub struct InitializeFund<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    /// CHECK: TODO(decision): T1 must verify the Mandate and both key authorizations before creation.
    #[account(mut)]
    pub fund: UncheckedAccount<'info>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<InitializeFund>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
