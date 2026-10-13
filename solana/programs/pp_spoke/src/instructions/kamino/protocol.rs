use super::KaminoError;
use anchor_lang::{
    prelude::*,
    solana_program::{
        instruction::{AccountMeta, Instruction},
        program::invoke_signed,
    },
};

/// ABI pin: Kamino-Finance/klend a08760976f51a3a58c4a0c6ea27b4a0e565bca79.
/// DEC-193: direct main-market USDC collateral; no obligation, borrowing or farms.
pub const PROGRAM: Pubkey = pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD");
pub const MARKET: Pubkey = pubkey!("7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF");
pub const RESERVE: Pubkey = pubkey!("D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59");
pub const USDC: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const COLLATERAL: Pubkey = pubkey!("B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D");
pub const LIQUIDITY_VAULT: Pubkey = pubkey!("Bgq7trRgVMeq33yt235zM2onQ4bRDBsY5EWiTetF4qw6");
pub const TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const ATA: Pubkey = pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const DEPOSIT: [u8; 8] = [169, 201, 30, 126, 6, 205, 102, 68];
pub const REDEEM: [u8; 8] = [234, 117, 181, 125, 185, 142, 220, 29];
pub const REFRESH: [u8; 8] = [144, 110, 26, 103, 162, 204, 252, 147];
pub const RESERVE_DISC: [u8; 8] = [43, 242, 204, 202, 26, 247, 59, 127];
pub const SCALE: u128 = 1 << 60;

pub fn read_u64(data: &[u8], offset: usize) -> Result<u64> {
    let bytes = data
        .get(offset..offset + 8)
        .ok_or(KaminoError::InvalidLayout)?;
    Ok(u64::from_le_bytes(
        bytes.try_into().map_err(|_| KaminoError::InvalidLayout)?,
    ))
}

pub fn read_u128(data: &[u8], offset: usize) -> Result<u128> {
    let bytes = data
        .get(offset..offset + 16)
        .ok_or(KaminoError::InvalidLayout)?;
    Ok(u128::from_le_bytes(
        bytes.try_into().map_err(|_| KaminoError::InvalidLayout)?,
    ))
}

pub fn read_key(data: &[u8], offset: usize) -> Result<Pubkey> {
    let bytes = data
        .get(offset..offset + 32)
        .ok_or(KaminoError::InvalidLayout)?;
    Ok(Pubkey::new_from_array(
        bytes.try_into().map_err(|_| KaminoError::InvalidLayout)?,
    ))
}

pub fn checked_add(left: u64, right: u64) -> Result<u64> {
    left.checked_add(right)
        .ok_or_else(|| error!(KaminoError::MathOverflow))
}

/// Exact floor(units * U68F60 liquidity / supply / 2^60), without a lossy rate or U256 dependency.
pub fn value_from_ratio(units: u64, liquidity_sf: u128, supply: u64) -> Result<u64> {
    if supply == 0 || liquidity_sf == 0 {
        return Ok(units);
    }
    let divisor = u128::from(supply);
    let quotient = liquidity_sf / divisor;
    let remainder = liquidity_sf % divisor;
    let product_low = (quotient & u128::from(u64::MAX))
        .checked_mul(u128::from(units))
        .ok_or(KaminoError::MathOverflow)?;
    let product_high = (quotient >> 64)
        .checked_mul(u128::from(units))
        .ok_or(KaminoError::MathOverflow)?;
    let residual = remainder
        .checked_mul(u128::from(units))
        .ok_or(KaminoError::MathOverflow)?
        / divisor;
    let low_sum = (product_low & (SCALE - 1)) + (residual & (SCALE - 1));
    let result = (product_low >> 60)
        .checked_add(
            product_high
                .checked_mul(16)
                .ok_or(KaminoError::MathOverflow)?,
        )
        .and_then(|value| value.checked_add(residual >> 60))
        .and_then(|value| value.checked_add(low_sum >> 60))
        .ok_or(KaminoError::MathOverflow)?;
    u64::try_from(result).map_err(|_| error!(KaminoError::MathOverflow))
}

#[derive(Debug, Clone, Copy)]
pub struct ReserveSnapshot {
    pub slot: u64,
    pub stale: bool,
    pub available: u64,
    pub liquidity_sf: u128,
    pub collateral_supply: u64,
    pub queued_units: u64,
}

impl ReserveSnapshot {
    pub fn decode(data: &[u8]) -> Result<Self> {
        require!(
            data.len() == 8624 && data[..8] == RESERVE_DISC,
            KaminoError::InvalidLayout
        );
        require!(read_u64(data, 8)? == 1, KaminoError::InvalidLayout);
        require_keys_eq!(read_key(data, 32)?, MARKET, KaminoError::WrongReserve);
        require_keys_eq!(read_key(data, 128)?, USDC, KaminoError::WrongReserve);
        require_keys_eq!(
            read_key(data, 160)?,
            LIQUIDITY_VAULT,
            KaminoError::WrongReserve
        );
        require_keys_eq!(read_key(data, 2560)?, COLLATERAL, KaminoError::WrongReserve);
        require_keys_eq!(read_key(data, 408)?, TOKEN, KaminoError::WrongReserve);
        require!(read_u64(data, 272)? == 6, KaminoError::InvalidLayout);
        let available = read_u64(data, 224)?;
        let liquidity_sf = (u128::from(available) * SCALE)
            .checked_add(read_u128(data, 232)?)
            .ok_or(KaminoError::MathOverflow)?
            .checked_sub(read_u128(data, 344)?)
            .ok_or(KaminoError::MathOverflow)?
            .checked_sub(read_u128(data, 360)?)
            .ok_or(KaminoError::MathOverflow)?
            .checked_sub(read_u128(data, 376)?)
            .ok_or(KaminoError::MathOverflow)?;
        Ok(Self {
            slot: read_u64(data, 16)?,
            stale: data[24] != 0,
            available,
            liquidity_sf,
            collateral_supply: read_u64(data, 2592)?,
            queued_units: read_u64(data, 6968)?,
        })
    }

    pub fn value(&self, units: u64) -> Result<u64> {
        value_from_ratio(units, self.liquidity_sf, self.collateral_supply)
    }

    pub fn freely_available(&self) -> Result<u64> {
        Ok(self
            .available
            .saturating_sub(self.value(self.queued_units)?))
    }
}

pub fn associated(mint: &Pubkey, owner: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[owner.as_ref(), TOKEN.as_ref(), mint.as_ref()], &ATA).0
}

pub fn token_balance(
    account: &AccountInfo,
    mint: &Pubkey,
    owner: &Pubkey,
    canonical: bool,
) -> Result<u64> {
    require_keys_eq!(*account.owner, TOKEN, KaminoError::InvalidTokenAccount);
    if canonical {
        require_keys_eq!(
            *account.key,
            associated(mint, owner),
            KaminoError::InvalidTokenAccount
        );
    }
    let data = account.try_borrow_data()?;
    require!(
        data.len() == 165 && data[108] == 1,
        KaminoError::InvalidTokenAccount
    );
    require_keys_eq!(read_key(&data, 0)?, *mint, KaminoError::InvalidTokenAccount);
    require_keys_eq!(
        read_key(&data, 32)?,
        *owner,
        KaminoError::InvalidTokenAccount
    );
    require!(
        data[72..76] == [0; 4] && data[109..113] == [0; 4] && data[129..133] == [0; 4],
        KaminoError::InvalidTokenAccount
    );
    read_u64(&data, 64)
}

pub fn refresh<'info>(
    program: &AccountInfo<'info>,
    market: &AccountInfo<'info>,
    reserve: &AccountInfo<'info>,
) -> Result<ReserveSnapshot> {
    require_keys_eq!(*program.key, PROGRAM, KaminoError::WrongProgram);
    require!(program.executable, KaminoError::WrongProgram);
    require_keys_eq!(*market.key, MARKET, KaminoError::WrongReserve);
    require_keys_eq!(*reserve.key, RESERVE, KaminoError::WrongReserve);
    require_keys_eq!(*market.owner, PROGRAM, KaminoError::WrongReserve);
    require_keys_eq!(*reserve.owner, PROGRAM, KaminoError::WrongReserve);
    ReserveSnapshot::decode(&reserve.try_borrow_data()?)?;
    let mut data = REFRESH.to_vec();
    data.push(1);
    invoke_signed(
        &Instruction {
            program_id: PROGRAM,
            accounts: vec![
                AccountMeta::new(RESERVE, false),
                AccountMeta::new_readonly(MARKET, false),
            ],
            data,
        },
        &[reserve.clone(), market.clone(), program.clone()],
        &[],
    )?;
    let snapshot = ReserveSnapshot::decode(&reserve.try_borrow_data()?)?;
    require!(
        !snapshot.stale && snapshot.slot == Clock::get()?.slot,
        KaminoError::StaleReserve
    );
    Ok(snapshot)
}

pub fn operation(discriminator: [u8; 8], amount: u64, keys: &[Pubkey; 10]) -> Instruction {
    let mut data = discriminator.to_vec();
    data.extend_from_slice(&amount.to_le_bytes());
    let mut accounts = vec![AccountMeta::new_readonly(keys[0], true)];
    let writable = if discriminator == DEPOSIT {
        [true, false, false, false, true, true, true, true, false]
    } else {
        [false, true, false, false, true, true, true, true, false]
    };
    for (key, is_writable) in keys[1..].iter().zip(writable) {
        accounts.push(if is_writable {
            AccountMeta::new(*key, false)
        } else {
            AccountMeta::new_readonly(*key, false)
        });
    }
    accounts.push(AccountMeta::new_readonly(TOKEN, false));
    accounts.push(AccountMeta::new_readonly(
        anchor_lang::solana_program::sysvar::instructions::ID,
        false,
    ));
    Instruction {
        program_id: PROGRAM,
        accounts,
        data,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anchor_lang::solana_program::hash::hash;

    #[test]
    fn discriminators_match_pinned_anchor_names() {
        for (name, expected) in [
            ("deposit_reserve_liquidity", DEPOSIT),
            ("redeem_reserve_collateral", REDEEM),
            ("refresh_reserves_batch", REFRESH),
        ] {
            assert_eq!(
                hash(format!("global:{name}").as_bytes()).to_bytes()[..8],
                expected
            );
        }
    }

    #[test]
    fn value_math_matches_exact_large_products_and_fractional_carry() {
        assert_eq!(value_from_ratio(7, 13 * SCALE + SCALE / 3, 11).unwrap(), 8);
        assert_eq!(
            value_from_ratio(u64::MAX, u128::from(u64::MAX) * SCALE, u64::MAX).unwrap(),
            u64::MAX
        );
        assert_eq!(value_from_ratio(u64::MAX, SCALE, 1).unwrap(), u64::MAX);
        assert!(value_from_ratio(u64::MAX, 2 * SCALE, 1).is_err());
        assert_eq!(value_from_ratio(9, 0, 55).unwrap(), 9);
        assert_eq!(value_from_ratio(9, SCALE, 0).unwrap(), 9);
        for units in 0..130 {
            for supply in 1..45 {
                let liquidity = 937 * SCALE + SCALE / 7;
                let exact = (u128::from(units) * liquidity / u128::from(supply)) >> 60;
                assert_eq!(
                    value_from_ratio(units, liquidity, supply).unwrap(),
                    exact as u64
                );
            }
        }
    }

    #[test]
    fn cpi_account_order_signers_and_writes_match_pinned_interface() {
        let keys = std::array::from_fn(|_| Pubkey::new_unique());
        for kind in [DEPOSIT, REDEEM] {
            let instruction = operation(kind, 123, &keys);
            assert_eq!(instruction.accounts.len(), 12);
            assert!(instruction.accounts[0].is_signer);
            assert!(!instruction.accounts[0].is_writable);
            assert!(instruction.accounts[1].is_writable == (kind == DEPOSIT));
            assert!(instruction.accounts[2].is_writable == (kind == REDEEM));
            assert_eq!(instruction.accounts[9].pubkey, keys[9]);
            assert_eq!(instruction.accounts[10].pubkey, TOKEN);
            assert_eq!(instruction.data[..8], kind);
            assert_eq!(read_u64(&instruction.data, 8).unwrap(), 123);
        }
    }
}
