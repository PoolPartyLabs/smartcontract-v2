use super::{error::RaydiumError, validation as check, wire::*};
use crate::state::{
    raydium::{RaydiumLedger, RaydiumPolicy, RaydiumPosition},
    FundState,
};
use anchor_lang::prelude::*;

/// DEC-190, DEC-193, DEC-194, DEC-195: Manager pays rent; Fund owns assets/NFT.
#[derive(Accounts)]
pub struct RaydiumOpenPosition<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical Fund vault checked in handler and signs only bounded CPIs.
    pub vault: UncheckedAccount<'info>,
    /// CHECK: pinned executable CLMM checked in handler.
    pub raydium_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
    pub policy: Account<'info, RaydiumPolicy>,
    #[account(mut, seeds = [b"raydium_ledger", fund.key().as_ref(), pool.key().as_ref()], bump,
        has_one = fund, has_one = pool)]
    pub ledger: Account<'info, RaydiumLedger>,
    #[account(init, payer = authority, space = 8 + RaydiumPosition::INIT_SPACE,
        seeds = [b"position", fund.key().as_ref(), personal_position.key().as_ref()], bump)]
    pub position_record: Account<'info, RaydiumPosition>,
    #[account(mut)]
    pub nft_mint: Signer<'info>,
    /// CHECK: Token-2022 ATA for the vault; CLMM initializes it.
    #[account(mut)]
    pub nft_account: UncheckedAccount<'info>,
    /// CHECK: pinned existing pool decoded in handler.
    #[account(mut)]
    pub pool: UncheckedAccount<'info>,
    /// CHECK: deprecated compatibility placeholder is required to equal CLMM.
    pub protocol_position: UncheckedAccount<'info>,
    /// CHECK: canonical boundary array; CLMM may initialize it with Manager rent.
    #[account(mut)]
    pub tick_array_lower: UncheckedAccount<'info>,
    /// CHECK: canonical boundary array; CLMM may initialize it with Manager rent.
    #[account(mut)]
    pub tick_array_upper: UncheckedAccount<'info>,
    /// CHECK: canonical CLMM position PDA initialized by CLMM.
    #[account(mut)]
    pub personal_position: UncheckedAccount<'info>,
    /// CHECK: canonical Fund token ATA checked in handler.
    #[account(mut)]
    pub token_account_0: UncheckedAccount<'info>,
    /// CHECK: canonical Fund token ATA checked in handler.
    #[account(mut)]
    pub token_account_1: UncheckedAccount<'info>,
    /// CHECK: pool vault relation checked in handler.
    #[account(mut)]
    pub token_vault_0: UncheckedAccount<'info>,
    /// CHECK: pool vault relation checked in handler.
    #[account(mut)]
    pub token_vault_1: UncheckedAccount<'info>,
    pub rent: Sysvar<'info, Rent>,
    /// CHECK: pinned SPL Token executable.
    #[account(address = TOKEN, executable)]
    pub token_program: UncheckedAccount<'info>,
    /// CHECK: pinned ATA executable.
    #[account(address = ATA, executable)]
    pub associated_token_program: UncheckedAccount<'info>,
    /// CHECK: pinned Token-2022 executable.
    #[account(address = TOKEN_2022, executable)]
    pub token_program_2022: UncheckedAccount<'info>,
    /// CHECK: pool mint and supported extensions checked in handler.
    pub mint_0: UncheckedAccount<'info>,
    /// CHECK: pool mint and supported extensions checked in handler.
    pub mint_1: UncheckedAccount<'info>,
    /// CHECK: canonical optional bitmap; forwarded only when initialized.
    #[account(mut)]
    pub bitmap: UncheckedAccount<'info>,
}

pub fn handler(ctx: Context<RaydiumOpenPosition>, payload: Vec<u8>) -> Result<()> {
    require!(
        ctx.remaining_accounts.is_empty(),
        RaydiumError::InvalidAccount
    );
    let args = OpenArgs::try_from_slice(&payload).map_err(|_| RaydiumError::InvalidData)?;
    let accounts = ctx.accounts;
    check::authority(
        &accounts.fund,
        accounts.authority.key(),
        accounts.vault.key(),
        &accounts.raydium_program,
    )?;
    let pool = check::pool(&accounts.pool)?;
    check::ticks(args.tick_lower, args.tick_upper, pool.spacing)?;
    check::policy(
        &accounts.fund,
        &accounts.policy,
        accounts.pool.key(),
        args.tick_lower,
        args.tick_upper,
    )?;
    require!(pool.status & 1 == 0, RaydiumError::InvalidAccount);
    let starts = [
        check::array_start(args.tick_lower, pool.spacing)?,
        check::array_start(args.tick_upper, pool.spacing)?,
    ];
    check::tick_array(
        &accounts.tick_array_lower,
        accounts.pool.key(),
        args.tick_lower,
        pool.spacing,
        true,
    )?;
    check::tick_array(
        &accounts.tick_array_upper,
        accounts.pool.key(),
        args.tick_upper,
        pool.spacing,
        true,
    )?;
    let use_bitmap = check::bitmap(&accounts.bitmap, accounts.pool.key(), starts, pool.spacing)?;
    require_keys_eq!(
        accounts.protocol_position.key(),
        CLMM,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        accounts.personal_position.key(),
        Pubkey::find_program_address(&[b"position", accounts.nft_mint.key().as_ref()], &CLMM).0,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        accounts.nft_account.key(),
        Pubkey::find_program_address(
            &[
                accounts.vault.key().as_ref(),
                TOKEN_2022.as_ref(),
                accounts.nft_mint.key().as_ref()
            ],
            &ATA
        )
        .0,
        RaydiumError::InvalidAccount
    );
    require!(
        accounts.personal_position.data_is_empty()
            && accounts.nft_account.data_is_empty()
            && accounts.nft_mint.data_is_empty(),
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        accounts.token_vault_0.key(),
        pool.vaults[0],
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        accounts.token_vault_1.key(),
        pool.vaults[1],
        RaydiumError::InvalidAccount
    );
    check::mint(&accounts.mint_0, pool.mints[0])?;
    check::mint(&accounts.mint_1, pool.mints[1])?;
    check::token(
        &accounts.token_vault_0,
        pool.mints[0],
        accounts.pool.key(),
        false,
        false,
    )?;
    check::token(
        &accounts.token_vault_1,
        pool.mints[1],
        accounts.pool.key(),
        false,
        false,
    )?;
    let before = [
        check::token(
            &accounts.token_account_0,
            pool.mints[0],
            accounts.vault.key(),
            true,
            false,
        )?,
        check::token(
            &accounts.token_account_1,
            pool.mints[1],
            accounts.vault.key(),
            true,
            false,
        )?,
    ];
    require!(
        args.amount_0_max <= accounts.ledger.idle_principal_0
            && args.amount_1_max <= accounts.ledger.idle_principal_1,
        RaydiumError::Slippage
    );
    require!(
        before[0]
            >= accounts
                .ledger
                .idle_principal_0
                .checked_add(accounts.ledger.idle_income_0)
                .ok_or(RaydiumError::Arithmetic)?
            && before[1]
                >= accounts
                    .ledger
                    .idle_principal_1
                    .checked_add(accounts.ledger.idle_income_1)
                    .ok_or(RaydiumError::Arithmetic)?,
        RaydiumError::Slippage
    );
    let data = open_data(&args, starts[0], starts[1])?;
    let fund_key = accounts.fund.key();
    let bump = [accounts.fund.vault_bump];
    let seeds: &[&[u8]] = &[b"vault", fund_key.as_ref(), &bump];
    let programs = [&accounts.token_program, &accounts.token_program_2022];
    let sources = [&accounts.token_account_0, &accounts.token_account_1];
    for index in 0..2 {
        let program = if check::token_program(pool.mints[index]) == TOKEN {
            programs[0]
        } else {
            programs[1]
        };
        token_delegate(
            program,
            sources[index],
            &accounts.authority,
            &accounts.vault,
            Some(if index == 0 {
                args.amount_0_max
            } else {
                args.amount_1_max
            }),
            &[seeds],
        )?;
    }
    let mut forwarded = vec![
        (accounts.authority.to_account_info(), true, true),
        (accounts.vault.to_account_info(), false, false),
        (accounts.nft_mint.to_account_info(), true, true),
        (accounts.nft_account.to_account_info(), true, false),
        (accounts.pool.to_account_info(), true, false),
        (accounts.protocol_position.to_account_info(), false, false),
        (accounts.tick_array_lower.to_account_info(), true, false),
        (accounts.tick_array_upper.to_account_info(), true, false),
        (accounts.personal_position.to_account_info(), true, false),
        (accounts.token_account_0.to_account_info(), true, false),
        (accounts.token_account_1.to_account_info(), true, false),
        (accounts.token_vault_0.to_account_info(), true, false),
        (accounts.token_vault_1.to_account_info(), true, false),
        (accounts.rent.to_account_info(), false, false),
        (accounts.system_program.to_account_info(), false, false),
        (accounts.token_program.to_account_info(), false, false),
        (
            accounts.associated_token_program.to_account_info(),
            false,
            false,
        ),
        (accounts.token_program_2022.to_account_info(), false, false),
        (accounts.mint_0.to_account_info(), false, false),
        (accounts.mint_1.to_account_info(), false, false),
    ];
    if use_bitmap {
        forwarded.push((accounts.bitmap.to_account_info(), true, false));
    }
    cpi(&accounts.raydium_program, &forwarded, data, &[])?;
    for index in 0..2 {
        let program = if check::token_program(pool.mints[index]) == TOKEN {
            programs[0]
        } else {
            programs[1]
        };
        token_delegate(
            program,
            sources[index],
            &accounts.authority,
            &accounts.vault,
            None,
            &[seeds],
        )?;
    }
    let position = check::position(&accounts.personal_position)?;
    require_keys_eq!(
        position.mint,
        accounts.nft_mint.key(),
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(
        position.pool,
        accounts.pool.key(),
        RaydiumError::InvalidAccount
    );
    require!(
        position.liquidity == args.liquidity
            && position.liquidity >= args.minimum_liquidity
            && position.lower == args.tick_lower
            && position.upper == args.tick_upper,
        RaydiumError::Slippage
    );
    check::nft(
        &accounts.nft_account,
        accounts.nft_mint.key(),
        accounts.vault.key(),
    )?;
    let after = [
        check::token(
            &accounts.token_account_0,
            pool.mints[0],
            accounts.vault.key(),
            true,
            false,
        )?,
        check::token(
            &accounts.token_account_1,
            pool.mints[1],
            accounts.vault.key(),
            true,
            false,
        )?,
    ];
    require!(
        before[0]
            .checked_sub(after[0])
            .ok_or(RaydiumError::Slippage)?
            <= args.amount_0_max
            && before[1]
                .checked_sub(after[1])
                .ok_or(RaydiumError::Slippage)?
                <= args.amount_1_max,
        RaydiumError::Slippage
    );
    accounts.ledger.idle_principal_0 = accounts
        .ledger
        .idle_principal_0
        .checked_sub(before[0] - after[0])
        .ok_or(RaydiumError::Slippage)?;
    accounts.ledger.idle_principal_1 = accounts
        .ledger
        .idle_principal_1
        .checked_sub(before[1] - after[1])
        .ok_or(RaydiumError::Slippage)?;
    let record = &mut accounts.position_record;
    record.fund = fund_key;
    record.pool = position.pool;
    record.personal_position = accounts.personal_position.key();
    record.nft_mint = position.mint;
    record.rent_payer = accounts.authority.key();
    record.tick_lower = position.lower;
    record.tick_upper = position.upper;
    record.liquidity = position.liquidity;
    record.collected_fees_0 = 0;
    record.collected_fees_1 = 0;
    record.closed = false;
    record.bump = ctx.bumps.position_record;
    latch_open_position(&mut accounts.fund.active_positions)?;
    Ok(())
}

fn latch_open_position(active_positions: &mut u16) -> Result<()> {
    *active_positions = active_positions
        .checked_add(1)
        .ok_or(RaydiumError::Arithmetic)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_opens_latch_each_unretired_position() {
        let mut active_positions = 0;
        latch_open_position(&mut active_positions).unwrap();
        assert_eq!(active_positions, 1);
        latch_open_position(&mut active_positions).unwrap();
        assert_eq!(active_positions, 2);
    }

    #[test]
    fn position_latch_blocks_idle_only_core_report() {
        let (mut fund, fund_key) = crate::instructions::core::guards::fixture();
        let clock = Clock {
            slot: 100,
            unix_timestamp: 1000,
            ..Clock::default()
        };
        assert!(crate::instructions::report::snapshot::encoded_snapshot(
            &fund,
            fund_key,
            &[],
            &clock
        )
        .is_ok());
        latch_open_position(&mut fund.active_positions).unwrap();
        let error =
            crate::instructions::report::snapshot::encoded_snapshot(&fund, fund_key, &[], &clock)
                .unwrap_err();
        assert_eq!(
            error,
            error!(crate::instructions::report::snapshot::ReportError::AdapterNotIntegrated)
        );
        assert_eq!(fund.active_positions, 1);
    }

    #[test]
    fn position_latch_overflow_fails_without_clearing_count() {
        let mut active_positions = u16::MAX - 1;
        latch_open_position(&mut active_positions).unwrap();
        assert_eq!(active_positions, u16::MAX);
        let error = latch_open_position(&mut active_positions).unwrap_err();
        assert_eq!(error, error!(RaydiumError::Arithmetic));
        assert_eq!(active_positions, u16::MAX);
    }
}
