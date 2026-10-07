use super::raydium_collect_fees::{
    RaydiumCollectFeesBumps, __client_accounts_raydium_collect_fees,
    __cpi_client_accounts_raydium_collect_fees,
};
use super::{
    error::RaydiumError,
    raydium_collect_fees::{decrease, RaydiumCollectFees},
    validation as check,
    wire::*,
};
use anchor_lang::prelude::*;

/// DEC-193, DEC-195: unwind all principal/fees, burn NFT and refund original payer.
#[derive(Accounts)]
pub struct RaydiumClosePosition<'info> {
    pub operation: RaydiumCollectFees<'info>,
    /// CHECK: validated against the recorded position mint and Token-2022 owner.
    #[account(mut)]
    pub nft_mint: UncheckedAccount<'info>,
    /// CHECK: exact original payer; receives only measured rent delta.
    #[account(mut)]
    pub rent_payer: UncheckedAccount<'info>,
}

pub fn handler(ctx: Context<RaydiumClosePosition>, payload: Vec<u8>) -> Result<()> {
    require!(
        ctx.remaining_accounts.is_empty(),
        RaydiumError::InvalidAccount
    );
    let args = CloseArgs::try_from_slice(&payload).map_err(|_| RaydiumError::InvalidData)?;
    let accounts = ctx.accounts;
    require_keys_eq!(
        accounts.rent_payer.key(),
        accounts.operation.position_record.rent_payer,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        accounts.nft_mint.key(),
        accounts.operation.position_record.nft_mint,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        *accounts.nft_mint.owner,
        TOKEN_2022,
        RaydiumError::InvalidAccount
    );
    decrease(
        &mut accounts.operation,
        true,
        [args.amount_0_min, args.amount_1_min],
    )?;
    let operation = &mut accounts.operation;
    let empty = check::position(&operation.personal_position)?;
    require!(
        empty.liquidity == 0 && empty.fees == [0; 2] && empty.rewards_owed == [0; 3],
        RaydiumError::PositionNotEmpty
    );
    require_keys_eq!(
        *operation.vault.owner,
        anchor_lang::system_program::ID,
        RaydiumError::InvalidAccount
    );
    require!(
        operation.vault.data_is_empty(),
        RaydiumError::InvalidAccount
    );
    let before = operation.vault.lamports();
    let fund_key = operation.fund.key();
    let bump = [operation.fund.vault_bump];
    let seeds: &[&[u8]] = &[b"vault", fund_key.as_ref(), &bump];
    cpi(
        &operation.raydium_program,
        &[
            (operation.vault.to_account_info(), true, true),
            (accounts.nft_mint.to_account_info(), true, false),
            (operation.nft_account.to_account_info(), true, false),
            (operation.personal_position.to_account_info(), true, false),
            (operation.system_program.to_account_info(), false, false),
            (operation.token_program_2022.to_account_info(), false, false),
            (operation.pool.to_account_info(), false, false),
        ],
        discriminator("global", "close_position").to_vec(),
        &[seeds],
    )?;
    require!(
        operation.personal_position.data_is_empty()
            && operation.nft_account.data_is_empty()
            && accounts.nft_mint.data_is_empty(),
        RaydiumError::PositionNotEmpty
    );
    let rent = operation
        .vault
        .lamports()
        .checked_sub(before)
        .ok_or(RaydiumError::Arithmetic)?;
    anchor_lang::system_program::transfer(
        CpiContext::new_with_signer(
            operation.system_program.to_account_info(),
            anchor_lang::system_program::Transfer {
                from: operation.vault.to_account_info(),
                to: accounts.rent_payer.to_account_info(),
            },
            &[seeds],
        ),
        rent,
    )?;
    operation.position_record.closed = true;
    operation.fund.active_positions = operation.fund.active_positions.checked_sub(1).ok_or(RaydiumError::Arithmetic)?;
    emit!(RaydiumPositionClosed {
        fund: fund_key,
        position: operation.personal_position.key(),
        rent_payer: accounts.rent_payer.key(),
        rent
    });
    Ok(())
}

#[event]
pub struct RaydiumPositionClosed {
    pub fund: Pubkey,
    pub position: Pubkey,
    pub rent_payer: Pubkey,
    pub rent: u64,
}
