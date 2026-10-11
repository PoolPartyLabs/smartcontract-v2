use super::{error::RaydiumError, validation as check, wire::*};
use crate::state::{
    raydium::{RaydiumLedger, RaydiumPosition},
    FundState,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::{get_return_data, invoke},
};

/// DEC-193: zero-liquidity decrease collects trading fees, never farm income.
/// DEC-195, DEC-206: the bound Manager pays rent for any missing reward quarantine.
#[derive(Accounts)]
pub struct RaydiumCollectFees<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: canonical Fund vault signs bounded venue CPIs.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: pinned executable CLMM.
    pub raydium_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
    #[account(mut, seeds = [b"position", fund.key().as_ref(), personal_position.key().as_ref()], bump = position_record.bump)]
    pub position_record: Account<'info, RaydiumPosition>,
    #[account(mut, seeds = [b"raydium_ledger", fund.key().as_ref(), pool.key().as_ref()], bump,
        has_one = fund, has_one = pool)]
    pub ledger: Account<'info, RaydiumLedger>,
    #[account(mut)]
    pub token_ledger_0: Box<Account<'info, crate::state::TokenLedger>>,
    #[account(mut)]
    pub token_ledger_1: Box<Account<'info, crate::state::TokenLedger>>,
    /// CHECK: canonical vault-owned Token-2022 position NFT.
    #[account(mut)]
    pub nft_account: UncheckedAccount<'info>,
    /// CHECK: canonical CLMM personal position.
    #[account(mut)]
    pub personal_position: UncheckedAccount<'info>,
    /// CHECK: pinned pool decoded and matched to the record.
    #[account(mut)]
    pub pool: UncheckedAccount<'info>,
    /// CHECK: deprecated placeholder constrained to CLMM.
    pub protocol_position: UncheckedAccount<'info>,
    /// CHECK: validated pool vault.
    #[account(mut)]
    pub token_vault_0: UncheckedAccount<'info>,
    /// CHECK: validated pool vault.
    #[account(mut)]
    pub token_vault_1: UncheckedAccount<'info>,
    /// CHECK: canonical initialized boundary array.
    #[account(mut)]
    pub tick_array_lower: UncheckedAccount<'info>,
    /// CHECK: canonical initialized boundary array.
    #[account(mut)]
    pub tick_array_upper: UncheckedAccount<'info>,
    /// CHECK: canonical Fund ATA; actual deltas determine realized trading fees.
    #[account(mut)]
    pub token_account_0: UncheckedAccount<'info>,
    /// CHECK: canonical Fund ATA; actual deltas determine realized trading fees.
    #[account(mut)]
    pub token_account_1: UncheckedAccount<'info>,
    /// CHECK: pinned SPL Token.
    #[account(address = TOKEN, executable)]
    pub token_program: UncheckedAccount<'info>,
    /// CHECK: pinned Token-2022.
    #[account(address = TOKEN_2022, executable)]
    pub token_program_2022: UncheckedAccount<'info>,
    /// CHECK: pinned memo program.
    #[account(address = MEMO, executable)]
    pub memo_program: UncheckedAccount<'info>,
    /// CHECK: validated mint/extensions.
    pub mint_0: UncheckedAccount<'info>,
    /// CHECK: validated mint/extensions.
    pub mint_1: UncheckedAccount<'info>,
    /// CHECK: canonical bitmap extension.
    #[account(mut)]
    pub bitmap: UncheckedAccount<'info>,
    /// CHECK: optional slot 0 vault validated against pool state.
    #[account(mut)]
    pub reward_vault_0: Option<UncheckedAccount<'info>>,
    /// CHECK: optional segregated slot 0 quarantine; transfers prohibited.
    #[account(mut)]
    pub reward_quarantine_0: Option<UncheckedAccount<'info>>,
    /// CHECK: optional slot 0 mint validated against pool state.
    pub reward_mint_0: Option<UncheckedAccount<'info>>,
    /// CHECK: optional slot 1 vault validated against pool state.
    #[account(mut)]
    pub reward_vault_1: Option<UncheckedAccount<'info>>,
    /// CHECK: optional segregated slot 1 quarantine; transfers prohibited.
    #[account(mut)]
    pub reward_quarantine_1: Option<UncheckedAccount<'info>>,
    /// CHECK: optional slot 1 mint validated against pool state.
    pub reward_mint_1: Option<UncheckedAccount<'info>>,
    /// CHECK: optional slot 2 vault validated against pool state.
    #[account(mut)]
    pub reward_vault_2: Option<UncheckedAccount<'info>>,
    /// CHECK: optional segregated slot 2 quarantine; transfers prohibited.
    #[account(mut)]
    pub reward_quarantine_2: Option<UncheckedAccount<'info>>,
    /// CHECK: optional slot 2 mint validated against pool state.
    pub reward_mint_2: Option<UncheckedAccount<'info>>,
}

pub fn handler(ctx: Context<RaydiumCollectFees>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty(), RaydiumError::InvalidData);
    require!(
        ctx.remaining_accounts.is_empty(),
        RaydiumError::InvalidAccount
    );
    decrease(ctx.accounts, false, [0, 0])
}

pub fn decrease<'info>(
    accounts: &mut RaydiumCollectFees<'info>,
    all: bool,
    minimum: [u64; 2],
) -> Result<()> {
    let mut reward_accounts = Vec::new();
    for triple in [
        [
            &accounts.reward_vault_0,
            &accounts.reward_quarantine_0,
            &accounts.reward_mint_0,
        ],
        [
            &accounts.reward_vault_1,
            &accounts.reward_quarantine_1,
            &accounts.reward_mint_1,
        ],
        [
            &accounts.reward_vault_2,
            &accounts.reward_quarantine_2,
            &accounts.reward_mint_2,
        ],
    ] {
        require!(
            triple.iter().all(|account| account.is_some())
                || triple.iter().all(|account| account.is_none()),
            RaydiumError::InvalidAccount
        );
        for account in triple.into_iter().flatten() {
            reward_accounts.push(account.to_account_info());
        }
    }
    check::authority(
        &accounts.fund,
        accounts.authority.key(),
        accounts.vault.key(),
        &accounts.raydium_program,
    )?;
    ensure_quarantines(accounts)?;
    let pool = check::pool(&accounts.pool)?;
    crate::instructions::core::admission::venue(&accounts.fund, CLMM, accounts.pool.key(), Pubkey::default())?;
    crate::instructions::core::admission::read_ledger(&accounts.token_ledger_0.to_account_info(), accounts.fund.key(), pool.mints[0])?;
    crate::instructions::core::admission::read_ledger(&accounts.token_ledger_1.to_account_info(), accounts.fund.key(), pool.mints[1])?;
    let position = check::position(&accounts.personal_position)?;
    check::record(
        &accounts.position_record,
        accounts.fund.key(),
        accounts.personal_position.key(),
        &position,
    )?;
    require_keys_eq!(
        position.pool,
        accounts.pool.key(),
        RaydiumError::InvalidAccount
    );
    check::nft(&accounts.nft_account, position.mint, accounts.vault.key())?;
    check::ticks(position.lower, position.upper, pool.spacing)?;
    check::tick_array(
        &accounts.tick_array_lower,
        position.pool,
        position.lower,
        pool.spacing,
        false,
    )?;
    check::tick_array(
        &accounts.tick_array_upper,
        position.pool,
        position.upper,
        pool.spacing,
        false,
    )?;
    let use_bitmap = check::bitmap(
        &accounts.bitmap,
        position.pool,
        [
            check::array_start(position.lower, pool.spacing)?,
            check::array_start(position.upper, pool.spacing)?,
        ],
        pool.spacing,
    )?;
    require_keys_eq!(
        accounts.protocol_position.key(),
        CLMM,
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
        position.pool,
        false,
        false,
    )?;
    check::token(
        &accounts.token_vault_1,
        pool.mints[1],
        position.pool,
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
    let (_, pending_fees) = check::valuation(
        &accounts.pool,
        &accounts.personal_position,
        &accounts.tick_array_lower,
        &accounts.tick_array_upper,
    )?;
    require!(
        pool.status & 4 == 0 && (!all || pool.status & 2 == 0),
        RaydiumError::InvalidAccount
    );
    let initialized: Vec<_> = pool
        .rewards
        .iter()
        .filter(|(mint, _)| *mint != Pubkey::default())
        .collect();
    let count = if pool.status & 8 == 0 {
        initialized.len()
    } else {
        0
    };
    require!(
        reward_accounts.len() == count * 3,
        RaydiumError::InvalidAccount
    );
    let mut reward_balances = Vec::new();
    for (index, (mint, vault)) in initialized.iter().take(count).enumerate() {
        let triple = &reward_accounts[index * 3..index * 3 + 3];
        require_keys_eq!(*triple[0].key, *vault, RaydiumError::InvalidAccount);
        require_keys_eq!(*triple[2].key, *mint, RaydiumError::InvalidAccount);
        let quarantine = Pubkey::find_program_address(
            &[
                b"raydium_reward",
                accounts.fund.key().as_ref(),
                mint.as_ref(),
            ],
            &crate::ID,
        )
        .0;
        require_keys_eq!(*triple[1].key, quarantine, RaydiumError::InvalidAccount);
        require!(
            triple[0].is_writable
                && triple[1].is_writable
                && !triple[0].is_signer
                && !triple[1].is_signer
                && !triple[2].is_signer,
            RaydiumError::InvalidAccount
        );
        let data = triple[1].try_borrow_data()?;
        require!(
            data.len() >= 165 && data[108] == 1,
            RaydiumError::InvalidAccount
        );
        require_keys_eq!(check::key(&data, 0)?, *mint, RaydiumError::InvalidAccount);
        require_keys_eq!(
            check::key(&data, 32)?,
            accounts.vault.key(),
            RaydiumError::InvalidAccount
        );
        require!(
            *triple[1].owner == TOKEN || *triple[1].owner == TOKEN_2022,
            RaydiumError::InvalidAccount
        );
        require_keys_eq!(
            *triple[1].owner,
            *triple[2].owner,
            RaydiumError::InvalidAccount
        );
        reward_balances.push(check::u64_at(&data, 64)?);
    }
    let fund_key = accounts.fund.key();
    let bump = [accounts.fund.vault_bump];
    let seeds: &[&[u8]] = &[b"vault", fund_key.as_ref(), &bump];
    let mut forwarded = vec![
        (accounts.vault.to_account_info(), false, true),
        (accounts.nft_account.to_account_info(), false, false),
        (accounts.personal_position.to_account_info(), true, false),
        (accounts.pool.to_account_info(), true, false),
        (accounts.protocol_position.to_account_info(), false, false),
        (accounts.token_vault_0.to_account_info(), true, false),
        (accounts.token_vault_1.to_account_info(), true, false),
        (accounts.tick_array_lower.to_account_info(), true, false),
        (accounts.tick_array_upper.to_account_info(), true, false),
        (accounts.token_account_0.to_account_info(), true, false),
        (accounts.token_account_1.to_account_info(), true, false),
        (accounts.token_program.to_account_info(), false, false),
        (accounts.token_program_2022.to_account_info(), false, false),
        (accounts.memo_program.to_account_info(), false, false),
        (accounts.mint_0.to_account_info(), false, false),
        (accounts.mint_1.to_account_info(), false, false),
    ];
    if use_bitmap {
        forwarded.push((accounts.bitmap.to_account_info(), true, false));
    }
    for (index, account) in reward_accounts.iter().enumerate() {
        forwarded.push((account.clone(), index % 3 != 2, false));
    }
    cpi(
        &accounts.raydium_program,
        &forwarded,
        decrease_data(if all { position.liquidity } else { 0 }, minimum),
        &[seeds],
    )?;
    let updated = check::position(&accounts.personal_position)?;
    require!(
        updated.liquidity == if all { 0 } else { position.liquidity },
        RaydiumError::Slippage
    );
    for (index, before) in reward_balances.iter().enumerate() {
        let after = check::u64_at(&reward_accounts[index * 3 + 1].try_borrow_data()?, 64)?;
        require!(after >= *before, RaydiumError::RewardClaim);
        if after > *before {
            emit!(RaydiumRewardQuarantined { fund: fund_key,
                mint: *reward_accounts[index * 3 + 2].key, amount: after - *before });
        }
    }
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
    let delta = [
        after[0]
            .checked_sub(before[0])
            .ok_or(RaydiumError::Slippage)?,
        after[1]
            .checked_sub(before[1])
            .ok_or(RaydiumError::Slippage)?,
    ];
    let realized = [
        pending_fees[0]
            .checked_sub(updated.fees[0])
            .ok_or(RaydiumError::Slippage)?,
        pending_fees[1]
            .checked_sub(updated.fees[1])
            .ok_or(RaydiumError::Slippage)?,
    ];
    require!(
        delta[0] >= realized[0] && delta[1] >= realized[1] && (all || delta == realized),
        RaydiumError::Slippage
    );
    if all {
        require!(
            delta[0] - realized[0] >= minimum[0] && delta[1] - realized[1] >= minimum[1],
            RaydiumError::Slippage
        );
    }
    accounts.position_record.liquidity = updated.liquidity;
    accounts.position_record.collected_fees_0 = accounts
        .position_record
        .collected_fees_0
        .checked_add(realized[0])
        .ok_or(RaydiumError::Arithmetic)?;
    accounts.position_record.collected_fees_1 = accounts
        .position_record
        .collected_fees_1
        .checked_add(realized[1])
        .ok_or(RaydiumError::Arithmetic)?;
    accounts.token_ledger_0.credit_income(realized[0])?;
    accounts.token_ledger_1.credit_income(realized[1])?;
    accounts.token_ledger_0.credit_principal(delta[0] - realized[0])?;
    accounts.token_ledger_1.credit_principal(delta[1] - realized[1])?;
    emit!(RaydiumFeesCollected {
        fund: fund_key,
        position: accounts.personal_position.key(),
        fees_0: realized[0],
        fees_1: realized[1]
    });
    Ok(())
}

/// CR-03: a reward slot can be initialized on the pool after admission or open, so the quarantine
/// is created on the first decrease that needs it; the PDA-owned address cannot be pre-created by anyone else.
/// Out of line so decrease() keeps its SBF stack frame; the slot loop in decrease() still validates every
/// triple against the pool's initialized rewards, so a wrong mint here only reverts the transaction.
#[inline(never)]
fn ensure_quarantines<'info>(accounts: &RaydiumCollectFees<'info>) -> Result<()> {
    let fund = accounts.fund.key();
    for (quarantine, mint) in [
        (&accounts.reward_quarantine_0, &accounts.reward_mint_0),
        (&accounts.reward_quarantine_1, &accounts.reward_mint_1),
        (&accounts.reward_quarantine_2, &accounts.reward_mint_2),
    ] {
        let (Some(quarantine), Some(mint)) = (quarantine, mint) else { continue };
        if *quarantine.owner != anchor_lang::system_program::ID {
            continue;
        }
        let (expected, bump) = Pubkey::find_program_address(
            &[b"raydium_reward", fund.as_ref(), mint.key.as_ref()],
            &crate::ID,
        );
        require_keys_eq!(quarantine.key(), expected, RaydiumError::InvalidAccount);
        require!(quarantine.is_writable, RaydiumError::InvalidAccount);
        create_quarantine(
            accounts,
            &quarantine.to_account_info(),
            &mint.to_account_info(),
            &[b"raydium_reward", fund.as_ref(), mint.key.as_ref(), &[bump]],
        )?;
    }
    Ok(())
}

#[inline(never)]
fn create_quarantine<'info>(
    accounts: &RaydiumCollectFees<'info>,
    quarantine: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    seeds: &[&[u8]],
) -> Result<()> {
    let token = if *mint.owner == TOKEN {
        accounts.token_program.to_account_info()
    } else {
        require_keys_eq!(*mint.owner, TOKEN_2022, RaydiumError::InvalidAccount);
        accounts.token_program_2022.to_account_info()
    };
    invoke(
        &Instruction { program_id: *token.key, accounts: vec![AccountMeta::new_readonly(*mint.key, false)], data: vec![21] },
        &[mint.clone(), token.clone()],
    )?;
    let (program, size) = get_return_data().ok_or(RaydiumError::InvalidData)?;
    require_keys_eq!(program, *token.key, RaydiumError::InvalidData);
    let space = u64::from_le_bytes(size.as_slice().try_into().map_err(|_| RaydiumError::InvalidData)?);
    crate::instructions::core::initialize_fund::allocate_owned(
        &accounts.authority.to_account_info(),
        quarantine,
        &accounts.system_program.to_account_info(),
        usize::try_from(space).map_err(|_| RaydiumError::InvalidData)?,
        token.key,
        seeds,
    )?;
    let mut data = vec![18];
    data.extend_from_slice(accounts.vault.key().as_ref());
    invoke(
        &Instruction {
            program_id: *token.key,
            accounts: vec![AccountMeta::new(*quarantine.key, false), AccountMeta::new_readonly(*mint.key, false)],
            data,
        },
        &[quarantine.clone(), mint.clone(), token],
    )?;
    emit!(RaydiumRewardQuarantineCreated { fund: accounts.fund.key(), mint: *mint.key,
        quarantine: *quarantine.key, payer: accounts.authority.key() });
    Ok(())
}

#[event]
pub struct RaydiumRewardQuarantineCreated {
    pub fund: Pubkey,
    pub mint: Pubkey,
    pub quarantine: Pubkey,
    pub payer: Pubkey,
}

#[event]
pub struct RaydiumFeesCollected {
    pub fund: Pubkey,
    pub position: Pubkey,
    pub fees_0: u64,
    pub fees_1: u64,
}

/// DEC-206: incidental exit rewards stay outside principal, income and NAV.
#[event]
pub struct RaydiumRewardQuarantined {
    pub fund: Pubkey,
    pub mint: Pubkey,
    pub amount: u64,
}
