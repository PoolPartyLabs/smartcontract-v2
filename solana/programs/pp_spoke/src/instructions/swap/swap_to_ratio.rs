use super::guard::{SwapError, JUPITER};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-190, DEC-193; RULINGS R5.1: fixed Manager and pinned Jupiter target.
#[derive(Accounts)]
pub struct SwapToRatio<'info> {
    #[account(address = fund.manager_solana @ SwapError::Unauthorized)]
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"fund", fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.mandate_hash.as_ref()], bump = fund.bump,
        constraint = !fund.closed @ SwapError::Closed)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: DEC-190, DEC-195: PDA signs token transfers, never holds Fund SOL.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump,
        constraint = vault.lamports() == 0 @ SwapError::Custody)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: RULINGS R5.1: the executable Jupiter program is pinned, not caller-selected.
    #[account(address = JUPITER @ SwapError::Program, executable)]
    pub swap_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<SwapToRatio>, _payload: Vec<u8>) -> Result<()> {
    // TODO(decision): T1 must supply canonical sealed-Mandate/config decoding and atomic ledger conversion.
    // DEC-079, DEC-080, DEC-190: never trust a Manager-supplied token allowlist or book a swap as income.
    err!(SwapError::IntegrationPending)
}
