use super::guard::{SwapError, JUPITER};
#[cfg(feature = "rehearsal-v1-swap")]
use super::rehearsal_guard::{SwapRequest, SealedPolicy, execute_guarded};
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

#[cfg(feature = "rehearsal-v1-swap")]

}

#[cfg(not(feature = "rehearsal-v1-swap"))]
pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, SwapToRatio<'info>>, payload: Vec<u8>) -> Result<()> {
    crate::instructions::core::admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    require!(payload.len() <= 4096, SwapError::Route);
    super::authorized::AuthorizedSwap::try_from_slice(&payload).map_err(|_| error!(SwapError::Route))?;
    // TODO(decision): DEC-202 requires sealed signer/oracle policy and nonce persistence before enabling execution.
    err!(SwapError::IntegrationPending)
}
