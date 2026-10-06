use super::{accounts::*, protocol::*, valuation::checkpoint, KaminoError};
use crate::state::{fund::FundState, kamino::KaminoPosition};
use anchor_lang::prelude::*;

/// DEC-190, DEC-193, DEC-195: Manager signs; only the vault PDA controls Fund tokens.
#[derive(Accounts)]
pub struct KaminoSupply<'info> {
    pub authority: Signer<'info>,
    #[account(seeds = [b"fund", fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes()], bump = fund.bump,
        constraint = fund.manager_solana == authority.key() @ KaminoError::Unauthorized,
        constraint = !fund.closed @ KaminoError::EntryDisabled)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical per-Fund vault signer, never the Manager wallet.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"position", fund.key().as_ref(), RESERVE.as_ref()], bump,
        has_one = fund, constraint = position.reserve == RESERVE @ KaminoError::WrongReserve,
        constraint = position.enabled @ KaminoError::EntryDisabled)]
    pub position: Account<'info, KaminoPosition>,
    pub venue: KaminoVenue<'info>,
}

/// Payload: exact u64 little-endian USDC units. No amount is inferred from wallet balances (DEC-080).
pub fn handler(ctx: Context<KaminoSupply>, payload: Vec<u8>) -> Result<()> {
    require!(payload.len() == 8, KaminoError::InvalidAmount);
    let amount = read_u64(&payload, 0)?;
    require!(amount > 0, KaminoError::InvalidAmount);
    let position = &mut ctx.accounts.position;
    require!(position.pending_units == 0, KaminoError::PendingWithdrawal);
    require!(
        amount <= position.idle_principal,
        KaminoError::InsufficientPrincipal
    );
    let (usdc_before, units_before) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units)?;
    require!(
        usdc_before >= checked_add(position.idle_principal, position.idle_income)?,
        KaminoError::InsufficientPrincipal
    );
    ctx.accounts.venue.refresh()?;
    ctx.accounts.venue.invoke(
        ctx.accounts.vault.to_account_info(),
        &ctx.accounts.fund.key(),
        ctx.accounts.fund.vault_bump,
        amount,
        true,
    )?;
    let (usdc_after, units_after) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units)?;
    let received = units_after
        .checked_sub(units_before)
        .ok_or(KaminoError::UnexpectedDelta)?;
    require!(
        received > 0 && usdc_before.checked_sub(usdc_after) == Some(amount),
        KaminoError::UnexpectedDelta
    );
    position.units = checked_add(position.units, received)?;
    position.principal = checked_add(position.principal, amount)?;
    position.idle_principal -= amount;
    checkpoint(position, ctx.accounts.venue.refresh()?)?;
    emit!(KaminoSupplied {
        fund: position.fund,
        liquidity: amount,
        collateral: received
    });
    Ok(())
}

#[event]
pub struct KaminoSupplied {
    pub fund: Pubkey,
    pub liquidity: u64,
    pub collateral: u64,
}
