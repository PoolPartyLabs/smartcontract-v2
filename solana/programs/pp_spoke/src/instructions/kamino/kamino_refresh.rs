use super::{
    protocol::*,
    valuation::{refresh_and_value, KaminoValue},
    KaminoError,
};
use crate::state::{fund::FundState, kamino::KaminoPosition};
use anchor_lang::prelude::*;

/// DEC-059, DEC-068: anyone may pay to refresh; no transfer, principal credit or authority change.
#[derive(Accounts)]
pub struct KaminoRefresh<'info> {
    pub authority: Signer<'info>,
    #[account(seeds = [b"fund", fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.mandate_hash.as_ref()], bump = fund.bump)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical per-Fund vault authority.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"position", fund.key().as_ref(), RESERVE.as_ref()], bump,
        has_one = fund, constraint = position.reserve == RESERVE @ KaminoError::WrongReserve)]
    pub position: Account<'info, KaminoPosition>,
    /// CHECK: canonical vault cToken ATA checked by refresh_and_value.
    pub vault_collateral: UncheckedAccount<'info>,
    /// CHECK: pinned identity, executable and owner checks are performed by refresh.
    pub kamino_program: UncheckedAccount<'info>,
    /// CHECK: pinned market identity and owner checks are performed by refresh.
    pub market: UncheckedAccount<'info>,
    /// CHECK: pinned reserve and layout checked by refresh.
    #[account(mut)]
    pub reserve: UncheckedAccount<'info>,
}

pub fn handler(ctx: Context<KaminoRefresh>, payload: Vec<u8>) -> Result<()> {
    crate::instructions::core::admission::venue(&ctx.accounts.fund, PROGRAM, Pubkey::default(), RESERVE)?;
    require!(payload.is_empty(), KaminoError::InvalidAmount);
    let value = refresh_and_value(
        &mut ctx.accounts.position,
        &ctx.accounts.vault.key(),
        &ctx.accounts.vault_collateral.to_account_info(),
        &ctx.accounts.kamino_program.to_account_info(),
        &ctx.accounts.market.to_account_info(),
        &ctx.accounts.reserve.to_account_info(),
    )?;
    anchor_lang::solana_program::program::set_return_data(&value.try_to_vec()?);
    emit!(KaminoValued {
        fund: ctx.accounts.fund.key(),
        value
    });
    Ok(())
}

#[event]
pub struct KaminoValued {
    pub fund: Pubkey,
    pub value: KaminoValue,
}
