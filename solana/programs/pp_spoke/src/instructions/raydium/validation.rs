use super::{error::RaydiumError, math, wire::*};
use crate::state::{
    raydium::{RaydiumPolicy, RaydiumPosition},
    FundState,
};
use anchor_lang::prelude::*;

pub fn bytes<const SIZE: usize>(data: &[u8], offset: usize) -> Result<[u8; SIZE]> {
    data.get(offset..offset + SIZE)
        .ok_or_else(|| error!(RaydiumError::InvalidData))?
        .try_into()
        .map_err(|_| error!(RaydiumError::InvalidData))
}

/// DEC-198: raw quantities stay unscaled; the authenticated Hub price applies the effective factor once.
pub fn stock_multiplier(mint: Pubkey, current: u64, next: u64, effective_at: i64) -> Result<()> {
    let accepted = if mint == NVDA {
        current == 0x3ff003c2ac1bf43f && next == 0x3ff006f7d589fea9 && effective_at == 1_789_000_200
    } else {
        mint == TSLA && current == 0x3ff0000000000000 && next == 0x3ff0000000000000
    };
    require!(accepted, RaydiumError::InvalidAccount);
    Ok(())
}

#[cfg(test)]
mod admission_tests {
    use super::*;

    #[test]
    fn reject_changed_nvda_corporate_action_tuple() {
        assert!(stock_multiplier(NVDA, 0x3ff003c2ac1bf43f, 0x3ff006f7d589fea9, 1_789_000_200).is_ok());
        assert!(stock_multiplier(NVDA, 0x3ff003c2ac1bf43f, 0x3ff006f7d589feaa, 1_789_000_200).is_err());
        assert!(stock_multiplier(NVDA, 0x3ff003c2ac1bf43f, 0x3ff006f7d589fea9, 1_789_000_201).is_err());
        assert!(stock_multiplier(NVDA, 0x3ff0000000000000, 0x3ff0000000000000, 0).is_err());
        assert!(stock_multiplier(TSLA, 0x3ff0000000000000, 0x3ff0000000000000, 0).is_ok());
    }
}
pub fn key(data: &[u8], offset: usize) -> Result<Pubkey> {
    Ok(Pubkey::new_from_array(bytes(data, offset)?))
}
pub fn u64_at(data: &[u8], offset: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(bytes(data, offset)?))
}
pub fn u128_at(data: &[u8], offset: usize) -> Result<u128> {
    Ok(u128::from_le_bytes(bytes(data, offset)?))
}
pub fn i32_at(data: &[u8], offset: usize) -> Result<i32> {
    Ok(i32::from_le_bytes(bytes(data, offset)?))
}

fn layout(account: &AccountInfo, name: &str, length: usize) -> Result<()> {
    require_keys_eq!(*account.owner, CLMM, RaydiumError::InvalidAccount);
    let data = account.try_borrow_data()?;
    require!(
        data.len() == length && bytes::<8>(&data, 0)? == discriminator("account", name),
        RaydiumError::InvalidData
    );
    Ok(())
}

pub fn authority(
    fund: &Account<FundState>,
    manager: Pubkey,
    vault: Pubkey,
    program: &AccountInfo,
) -> Result<()> {
    require_keys_eq!(fund.manager_solana, manager, RaydiumError::Unauthorized);
    crate::instructions::core::guards::require_fund_address(fund, &fund.key())?;
    require!(!fund.closed, RaydiumError::Unauthorized);
    let expected_fund = Pubkey::find_program_address(
        &[b"fund", &fund.hub_chain_id.to_le_bytes(), &fund.hub_core, &fund.spoke_index.to_le_bytes(), &fund.policy_hash],
        &crate::ID,
    );
    require_keys_eq!(expected_fund.0, fund.key(), RaydiumError::InvalidAccount);
    require!(expected_fund.1 == fund.bump, RaydiumError::InvalidAccount);
    let expected_vault = Pubkey::find_program_address(&[b"vault", fund.key().as_ref()], &crate::ID);
    require_keys_eq!(expected_vault.0, vault, RaydiumError::InvalidAccount);
    require!(
        expected_vault.1 == fund.vault_bump,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(*program.key, CLMM, RaydiumError::InvalidAccount);
    require!(program.executable, RaydiumError::InvalidAccount);
    Ok(())
}

pub fn policy(
    fund: &Account<FundState>,
    policy: &Account<RaydiumPolicy>,
    pool: Pubkey,
    lower: i32,
    upper: i32,
) -> Result<()> {
    let expected = Pubkey::find_program_address(
        &[b"raydium_policy", fund.key().as_ref(), pool.as_ref()],
        &crate::ID,
    )
    .0;
    crate::instructions::core::admission::venue(fund, CLMM, pool, Pubkey::default())?;
    require_keys_eq!(expected, policy.key(), RaydiumError::InvalidPolicy);
    require_keys_eq!(policy.fund, fund.key(), RaydiumError::InvalidPolicy);
    require_keys_eq!(policy.pool, pool, RaydiumError::InvalidPolicy);
    require!(
        policy.enabled
            && policy.mandate_hash == fund.mandate_hash
            && lower >= policy.minimum_tick
            && upper <= policy.maximum_tick,
        RaydiumError::InvalidPolicy
    );
    Ok(())
}

pub struct Pool {
    pub mints: [Pubkey; 2],
    pub vaults: [Pubkey; 2],
    pub spacing: u16,
    pub sqrt: u128,
    pub tick: i32,
    pub fee_growth: [u128; 2],
    pub status: u8,
    pub rewards: [(Pubkey, Pubkey); 3],
}

pub fn pool(account: &AccountInfo) -> Result<Pool> {
    require!(
        [TSLA_POOL, SOL_POOL, NVDA_POOL].contains(account.key),
        RaydiumError::InvalidAccount
    );
    layout(account, "PoolState", 1544)?;
    let data = account.try_borrow_data()?;
    let mints = [key(&data, 73)?, key(&data, 105)?];
    let asset = if *account.key == TSLA_POOL {
        TSLA
    } else if *account.key == NVDA_POOL {
        NVDA
    } else {
        WSOL
    };
    require!(
        mints.contains(&asset) && mints.contains(&USDC),
        RaydiumError::InvalidAccount
    );
    let spacing = u16::from_le_bytes(bytes(&data, 235)?);
    require!(spacing > 0, RaydiumError::InvalidData);
    let mut rewards = [(Pubkey::default(), Pubkey::default()); 3];
    for (index, reward) in rewards.iter_mut().enumerate() {
        let offset = 397 + index * 169;
        *reward = (key(&data, offset + 57)?, key(&data, offset + 89)?);
    }
    Ok(Pool {
        mints,
        vaults: [key(&data, 137)?, key(&data, 169)?],
        spacing,
        sqrt: u128_at(&data, 253)?,
        tick: i32_at(&data, 269)?,
        fee_growth: [u128_at(&data, 277)?, u128_at(&data, 293)?],
        status: data[389],
        rewards,
    })
}

pub fn array_start(tick: i32, spacing: u16) -> Result<i32> {
    require!(spacing > 0, RaydiumError::InvalidRange);
    Ok(tick.div_euclid(i32::from(spacing) * 60) * i32::from(spacing) * 60)
}

pub fn ticks(lower: i32, upper: i32, spacing: u16) -> Result<()> {
    require!(
        spacing > 0
            && lower >= math::MIN_TICK
            && upper <= math::MAX_TICK
            && lower < upper
            && lower % i32::from(spacing) == 0
            && upper % i32::from(spacing) == 0,
        RaydiumError::InvalidRange
    );
    Ok(())
}

pub fn tick_array(
    account: &AccountInfo,
    pool: Pubkey,
    tick: i32,
    spacing: u16,
    allow_new: bool,
) -> Result<[u128; 2]> {
    let start = array_start(tick, spacing)?;
    let expected =
        Pubkey::find_program_address(&[b"tick_array", pool.as_ref(), &start.to_be_bytes()], &CLMM)
            .0;
    require_keys_eq!(*account.key, expected, RaydiumError::InvalidAccount);
    if allow_new && account.data_is_empty() {
        require_keys_eq!(
            *account.owner,
            anchor_lang::system_program::ID,
            RaydiumError::InvalidAccount
        );
        return Ok([0, 0]);
    }
    layout(account, "TickArrayState", 10240)?;
    let data = account.try_borrow_data()?;
    require_keys_eq!(key(&data, 8)?, pool, RaydiumError::InvalidAccount);
    require!(i32_at(&data, 40)? == start, RaydiumError::InvalidAccount);
    let offset = 44
        + usize::try_from((tick - start) / i32::from(spacing))
            .map_err(|_| RaydiumError::InvalidRange)?
            * 168;
    require!(
        i32_at(&data, offset)? == tick || (allow_new && u128_at(&data, offset + 20)? == 0),
        RaydiumError::InvalidAccount
    );
    Ok([u128_at(&data, offset + 36)?, u128_at(&data, offset + 52)?])
}

pub fn bitmap(account: &AccountInfo, pool: Pubkey, starts: [i32; 2], spacing: u16) -> Result<bool> {
    let needed = starts.iter().any(|start| {
        *start < -512 * i32::from(spacing) * 60 || *start >= 512 * i32::from(spacing) * 60
    });
    let expected =
        Pubkey::find_program_address(&[b"pool_tick_array_bitmap_extension", pool.as_ref()], &CLMM)
            .0;
    require_keys_eq!(*account.key, expected, RaydiumError::InvalidAccount);
    if !account.data_is_empty() {
        layout(account, "TickArrayBitmapExtension", 1832)?;
        require_keys_eq!(
            key(&account.try_borrow_data()?, 8)?,
            pool,
            RaydiumError::InvalidAccount
        );
    } else {
        require!(!needed, RaydiumError::InvalidAccount);
    }
    Ok(!account.data_is_empty())
}

pub fn token_program(mint: Pubkey) -> Pubkey {
    if [TSLA, NVDA].contains(&mint) {
        TOKEN_2022
    } else {
        TOKEN
    }
}

pub fn nft(account: &AccountInfo, mint: Pubkey, vault: Pubkey) -> Result<()> {
    require_keys_eq!(*account.owner, TOKEN_2022, RaydiumError::InvalidAccount);
    require_keys_eq!(
        *account.key,
        Pubkey::find_program_address(&[vault.as_ref(), TOKEN_2022.as_ref(), mint.as_ref()], &ATA).0,
        RaydiumError::InvalidAccount
    );
    let data = account.try_borrow_data()?;
    require!(
        data.len() >= 165
            && (data[108] == 1 || data[108] == 2)
            && u64_at(&data, 64)? == 1
            && u32::from_le_bytes(bytes(&data, 72)?) == 0
            && u32::from_le_bytes(bytes(&data, 129)?) == 0,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(key(&data, 0)?, mint, RaydiumError::InvalidAccount);
    require_keys_eq!(key(&data, 32)?, vault, RaydiumError::InvalidAccount);
    Ok(())
}

pub fn token(
    account: &AccountInfo,
    mint: Pubkey,
    owner: Pubkey,
    canonical: bool,
    frozen_ok: bool,
) -> Result<u64> {
    let program = token_program(mint);
    require_keys_eq!(*account.owner, program, RaydiumError::InvalidAccount);
    let data = account.try_borrow_data()?;
    require!(
        data.len() >= 165 && (data[108] == 1 || (frozen_ok && data[108] == 2)),
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(key(&data, 0)?, mint, RaydiumError::InvalidAccount);
    require_keys_eq!(key(&data, 32)?, owner, RaydiumError::InvalidAccount);
    require!(
        u32::from_le_bytes(bytes(&data, 72)?) == 0 && u32::from_le_bytes(bytes(&data, 129)?) == 0,
        RaydiumError::InvalidAccount
    );
    if canonical {
        require_keys_eq!(
            *account.key,
            Pubkey::find_program_address(&[owner.as_ref(), program.as_ref(), mint.as_ref()], &ATA)
                .0,
            RaydiumError::InvalidAccount
        );
    }
    Ok(u64_at(&data, 64)?)
}

pub fn mint(account: &AccountInfo, expected: Pubkey) -> Result<()> {
    require!(!account.is_writable, RaydiumError::InvalidAccount);
    require_keys_eq!(*account.key, expected, RaydiumError::InvalidAccount);
    require_keys_eq!(
        *account.owner,
        token_program(expected),
        RaydiumError::InvalidAccount
    );
    let data = account.try_borrow_data()?;
    require!(data.len() >= 82 && data[45] == 1, RaydiumError::InvalidData);
    let decimals = if [TSLA, NVDA].contains(&expected) {
        8
    } else if expected == WSOL {
        9
    } else {
        6
    };
    require!(data[44] == decimals, RaydiumError::InvalidData);
    if ![TSLA, NVDA].contains(&expected) {
        require!(data.len() == 82, RaydiumError::UnsupportedExtension);
        return Ok(());
    }
    require!(
        data.len() >= 166 && data[165] == 1,
        RaydiumError::InvalidData
    );
    let mut offset = 166;
    let mut seen = 0u16;
    let expected_types = [4u16, 6, 12, 14, 18, 19, 25, 26];
    while offset + 4 <= data.len() {
        let kind = u16::from_le_bytes(bytes(&data, offset)?);
        let length = u16::from_le_bytes(bytes(&data, offset + 2)?) as usize;
        if kind == 0 {
            require!(
                data[offset..].iter().all(|value| *value == 0),
                RaydiumError::InvalidData
            );
            break;
        }
        let index = expected_types
            .iter()
            .position(|value| *value == kind)
            .ok_or(RaydiumError::UnsupportedExtension)?;
        require!(seen & (1 << index) == 0, RaydiumError::InvalidData);
        seen |= 1 << index;
        let value = data
            .get(offset + 4..offset + 4 + length)
            .ok_or(RaydiumError::InvalidData)?;
        match kind {
            6 => require!(value == [1], RaydiumError::UnsupportedExtension),
            14 => require!(
                value.len() == 64 && value[32..64].iter().all(|value| *value == 0),
                RaydiumError::UnsupportedExtension
            ),
            25 => {
                require!(value.len() == 56, RaydiumError::UnsupportedExtension);
                stock_multiplier(expected, u64_at(value, 32)?, u64_at(value, 48)?,
                    i64::from_le_bytes(bytes(value, 40)?))?;
            }
            26 => require!(
                value.len() == 33 && value[32] == 0,
                RaydiumError::UnsupportedExtension
            ),
            4 => require!(value.len() == 65, RaydiumError::InvalidData),
            12 => require!(value.len() == 32, RaydiumError::InvalidData),
            18 => require!(value.len() == 64, RaydiumError::InvalidData),
            _ => {}
        }
        offset += 4 + length;
    }
    require!(
        seen == 255 && data[offset..].iter().all(|value| *value == 0),
        RaydiumError::UnsupportedExtension
    );
    Ok(())
}

pub struct Position {
    pub mint: Pubkey,
    pub pool: Pubkey,
    pub lower: i32,
    pub upper: i32,
    pub liquidity: u128,
    pub checkpoints: [u128; 2],
    pub fees: [u64; 2],
    pub rewards_owed: [u64; 3],
}

pub fn position(account: &AccountInfo) -> Result<Position> {
    layout(account, "PersonalPositionState", 281)?;
    let data = account.try_borrow_data()?;
    let mint = key(&data, 9)?;
    require_keys_eq!(
        *account.key,
        Pubkey::find_program_address(&[b"position", mint.as_ref()], &CLMM).0,
        RaydiumError::InvalidAccount
    );
    Ok(Position {
        mint,
        pool: key(&data, 41)?,
        lower: i32_at(&data, 73)?,
        upper: i32_at(&data, 77)?,
        liquidity: u128_at(&data, 81)?,
        checkpoints: [u128_at(&data, 97)?, u128_at(&data, 113)?],
        fees: [u64_at(&data, 129)?, u64_at(&data, 137)?],
        rewards_owed: [
            u64_at(&data, 161)?,
            u64_at(&data, 185)?,
            u64_at(&data, 209)?,
        ],
    })
}

pub fn record(
    record: &Account<RaydiumPosition>,
    fund: Pubkey,
    position_key: Pubkey,
    position: &Position,
) -> Result<()> {
    require_keys_eq!(record.fund, fund, RaydiumError::InvalidAccount);
    require_keys_eq!(
        record.personal_position,
        position_key,
        RaydiumError::InvalidAccount
    );
    require_keys_eq!(record.pool, position.pool, RaydiumError::InvalidAccount);
    require_keys_eq!(record.nft_mint, position.mint, RaydiumError::InvalidAccount);
    require!(
        !record.closed
            && record.tick_lower == position.lower
            && record.tick_upper == position.upper
            && record.liquidity == position.liquidity,
        RaydiumError::InvalidAccount
    );
    Ok(())
}

/// DEC-193, DEC-194: raw principal and trading fees only; USD pricing stays on Hub.
pub fn valuation(
    pool_account: &AccountInfo,
    position_account: &AccountInfo,
    lower_array: &AccountInfo,
    upper_array: &AccountInfo,
) -> Result<([u64; 2], [u64; 2])> {
    let pool = pool(pool_account)?;
    let position = position(position_account)?;
    require_keys_eq!(
        position.pool,
        *pool_account.key,
        RaydiumError::InvalidAccount
    );
    ticks(position.lower, position.upper, pool.spacing)?;
    let lower = tick_array(
        lower_array,
        position.pool,
        position.lower,
        pool.spacing,
        false,
    )?;
    let upper = tick_array(
        upper_array,
        position.pool,
        position.upper,
        pool.spacing,
        false,
    )?;
    let principal = math::amounts(
        position.liquidity,
        pool.sqrt,
        math::sqrt_price_at_tick(position.lower)?,
        math::sqrt_price_at_tick(position.upper)?,
        false,
    )?;
    let mut fees = [0; 2];
    for index in 0..2 {
        let below = if pool.tick >= position.lower {
            lower[index]
        } else {
            pool.fee_growth[index].wrapping_sub(lower[index])
        };
        let above = if pool.tick < position.upper {
            upper[index]
        } else {
            pool.fee_growth[index].wrapping_sub(upper[index])
        };
        let inside = pool.fee_growth[index]
            .wrapping_sub(below)
            .wrapping_sub(above);
        fees[index] = math::accrued_fee(
            position.liquidity,
            inside,
            position.checkpoints[index],
            position.fees[index],
        )?;
    }
    Ok((principal, fees))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn negative_tick_arrays_and_alignment_fail_closed() {
        assert_eq!(array_start(-1, 10).unwrap(), -600);
        assert_eq!(array_start(-600, 10).unwrap(), -600);
        assert_eq!(array_start(-601, 10).unwrap(), -1200);
        assert!(ticks(-1, 10, 10).is_err());
        assert!(ticks(10, 10, 10).is_err());
        assert!(ticks(-10, 10, 0).is_err());
    }
}
