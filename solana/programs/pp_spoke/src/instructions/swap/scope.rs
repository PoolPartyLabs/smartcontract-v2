use super::{guard::TOKEN_2022, oracle::{self, OracleError, OraclePolicy, Price}};
use anchor_lang::prelude::*;

pub const PROGRAM: Pubkey = pubkey!("HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ");
pub const PRICES: Pubkey = pubkey!("3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH");
pub const MAPPINGS: Pubkey = pubkey!("4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg");
pub const TSLAX: Pubkey = pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB");
pub const NVDAX: Pubkey = pubkey!("Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh");
const TSLA_FEED: [u8; 32] = [0,8,0x4e,0xdc,0x84,0x4a,0x6f,0x88,0x44,0x9c,0x59,0xc8,0xcf,0xcd,0xb2,0x22,0x57,0x99,0xa2,0x33,0x05,0x03,0x47,0x2c,0xb0,0xbc,0x4f,0x93,0x69,0xa7,0x17,0xfa];
const NVDA_FEED: [u8; 32] = [0,8,0xad,0xc1,0x84,0x84,0x7b,0xa8,0xd1,0x7f,0,0x30,0xc1,0x5e,0x78,0xf6,0x1b,0x83,0xed,0xa2,0xe1,0x90,0xf3,0x03,0x46,0xc4,0xea,0x3b,0xab,0xed,0x64,0x7d];

fn integer(bytes: &[u8], offset: usize) -> Result<u64> {
    let value = bytes.get(offset..offset + 8).ok_or(OracleError::InvalidAccount)?;
    Ok(u64::from_le_bytes(value.try_into().map_err(|_| OracleError::InvalidAccount)?))
}

/// DEC-203, DEC-204: read the pinned Open v8 underlying, never an AllUpdates/xStock slot.
/// R9.1 (2026-10-11): no market-session gate; the tokenized stock trades 24/7 and price staleness
/// (`min(max_age, 60)` seconds, non-future) is the only freshness guard.
/// Layout pin: Kamino-Finance/scope 8d01cb8cfb9cfb3f75aec8ee39bcf9f6b40b16c5.
pub fn reference(prices: &AccountInfo, mappings: &AccountInfo, mint: &AccountInfo,
    enabled: bool, policy: &OraclePolicy, clock: &Clock) -> Result<Price> {
    require!(enabled && policy.stock_enabled, OracleError::StockDisabled);
    require!(*prices.key == PRICES && *mappings.key == MAPPINGS
        && *prices.owner == PROGRAM && *mappings.owner == PROGRAM
        && !prices.is_writable && !mappings.is_writable && !prices.executable && !mappings.executable,
        OracleError::InvalidAccount);
    let (index, feed) = match *mint.key {
        TSLAX => (60usize, TSLA_FEED),
        NVDAX => (46usize, NVDA_FEED),
        _ => return err!(OracleError::InvalidAccount),
    };
    require!(*mint.owner == TOKEN_2022 && oracle::mint_decimals(mint, mint.key)? == 8,
        OracleError::InvalidAccount);
    let data = prices.try_borrow_data()?;
    let mapping = mappings.try_borrow_data()?;
    require!(data.len() == 28_712 && mapping.len() == 29_704
        && data[..8] == [0x59,0x80,0x76,0xdd,0x06,0x48,0xb4,0x92]
        && mapping[..8] == [0x28,0xf4,0x6e,0x50,0xff,0xd6,0xf3,0xbc]
        && data[8..40] == MAPPINGS.to_bytes(), OracleError::InvalidAccount);
    let generic = 19_464 + 20 * index;
    require!(mapping[8 + index * 32..40 + index * 32] == feed
        && mapping[16_392 + index] == 34
        && mapping[generic] == 1 && mapping[generic + 1..generic + 20].iter().all(|byte| *byte == 0),
        OracleError::InvalidAccount);
    let start = 40 + 56 * index;
    let value = integer(&data, start)?;
    let exponent = integer(&data, start + 8)?;
    let slot = integer(&data, start + 16)?;
    let timestamp = i64::try_from(integer(&data, start + 24)?).map_err(|_| OracleError::Stale)?;
    require!(value > 0 && exponent == 15, OracleError::InvalidPrice);
    require!(policy.max_age_seconds > 0 && policy.max_age_seconds <= 300
        && timestamp > 0 && timestamp <= clock.unix_timestamp
        && (clock.unix_timestamp - timestamp) as u64 <= policy.max_age_seconds.min(60)
        && slot > 0 && slot <= clock.slot
        && integer(&data, start + 32)? == timestamp as u64
        && data[start + 40..start + 56].iter().all(|byte| *byte == 0), OracleError::Stale);
    oracle::stock_price(Price { value: u128::from(value), exponent: -15 }, mint, clock.unix_timestamp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn off_session_fresh_price_is_accepted_and_only_staleness_rejects() {
        let policy = OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
            cross_check_deviation_bps: 50, block_cross_check: false,
            require_manager_bound: false, stock_enabled: true };
        // Saturday 2026-10-10 12:00 UTC and Sunday 2026-10-11 17:25 UTC: no session, fresh source.
        for now in [1_791_633_600i64, 1_791_739_500] {
            let start = 40 + 56 * 60;
            let mut prices_data = vec![0; 28_712];
            prices_data[..8].copy_from_slice(&[0x59,0x80,0x76,0xdd,0x06,0x48,0xb4,0x92]);
            prices_data[8..40].copy_from_slice(&MAPPINGS.to_bytes());
            for (offset, value) in [(0, 237_060_000_000_000_000u64), (8, 15), (16, 100),
                (24, (now - 30) as u64), (32, (now - 30) as u64)] {
                prices_data[start + offset..start + offset + 8].copy_from_slice(&value.to_le_bytes());
            }
            let mut mapping_data = vec![0; 29_704];
            mapping_data[..8].copy_from_slice(&[0x28,0xf4,0x6e,0x50,0xff,0xd6,0xf3,0xbc]);
            mapping_data[8 + 60 * 32..40 + 60 * 32].copy_from_slice(&TSLA_FEED);
            mapping_data[16_392 + 60] = 34;
            mapping_data[19_464 + 20 * 60] = 1;
            let mut mint_data = vec![0; 226];
            mint_data[44] = 8; mint_data[45] = 1; mint_data[165] = 1;
            mint_data[166..168].copy_from_slice(&25u16.to_le_bytes());
            mint_data[168..170].copy_from_slice(&56u16.to_le_bytes());
            mint_data[202..210].copy_from_slice(&1f64.to_le_bytes());
            mint_data[218..226].copy_from_slice(&1f64.to_le_bytes());
            let (mut a, mut b, mut c) = (1, 1, 1);
            let prices = AccountInfo::new(&PRICES, false, false, &mut a, &mut prices_data, &PROGRAM, false, 0);
            let mapping = AccountInfo::new(&MAPPINGS, false, false, &mut b, &mut mapping_data, &PROGRAM, false, 0);
            let mint = AccountInfo::new(&TSLAX, false, false, &mut c, &mut mint_data, &TOKEN_2022, false, 0);
            let fresh = Clock { unix_timestamp: now, slot: 100, ..Clock::default() };
            assert!(reference(&prices, &mapping, &mint, true, &policy, &fresh).is_ok(), "{now}");
            let stale = Clock { unix_timestamp: now + 31, slot: 100, ..Clock::default() };
            assert_eq!(reference(&prices, &mapping, &mint, true, &policy, &stale).unwrap_err(),
                error!(OracleError::Stale));
        }
    }

    #[test]
    fn pinned_reader_rejects_mutated_accounts_feeds_prices_and_clock() {
        let now = 1_791_380_000;
        let policy = OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
            cross_check_deviation_bps: 50, block_cross_check: false,
            require_manager_bound: false, stock_enabled: true };
        let clock = Clock { unix_timestamp: now, slot: 100, ..Clock::default() };
        for stock in [TSLAX, NVDAX] {
            let (index, feed) = if stock == TSLAX { (60, TSLA_FEED) } else { (46, NVDA_FEED) };
            let start = 40 + 56 * index;
            let mut original_prices = vec![0; 28_712];
            original_prices[..8].copy_from_slice(&[0x59,0x80,0x76,0xdd,0x06,0x48,0xb4,0x92]);
            original_prices[8..40].copy_from_slice(&MAPPINGS.to_bytes());
            for (offset, value) in [(0, 237_060_000_000_000_000u64), (8, 15), (16, 100),
                (24, now as u64), (32, now as u64)] {
                original_prices[start + offset..start + offset + 8].copy_from_slice(&value.to_le_bytes());
            }
            let mut original_mapping = vec![0; 29_704];
            original_mapping[..8].copy_from_slice(&[0x28,0xf4,0x6e,0x50,0xff,0xd6,0xf3,0xbc]);
            original_mapping[8 + index * 32..40 + index * 32].copy_from_slice(&feed);
            original_mapping[16_392 + index] = 34;
            original_mapping[19_464 + 20 * index] = 1;
            let mut original_mint = vec![0; 226];
            original_mint[44] = 8; original_mint[45] = 1; original_mint[165] = 1;
            original_mint[166..168].copy_from_slice(&25u16.to_le_bytes());
            original_mint[168..170].copy_from_slice(&56u16.to_le_bytes());
            original_mint[202..210].copy_from_slice(&1f64.to_le_bytes());
            original_mint[218..226].copy_from_slice(&1.001701196801074f64.to_le_bytes());
            for variant in 0..30 {
                let mut prices_data = original_prices.clone();
                let mut mapping_data = original_mapping.clone();
                let mut mint_data = original_mint.clone();
                let mut price_key = PRICES; let mut owner = PROGRAM;
                let mut mapping_key = MAPPINGS; let mut mapping_owner = PROGRAM;
                let mut mint_owner = TOKEN_2022;
                let mut prices_writable = false; let mut mapping_writable = false;
                let mut prices_executable = false; let mut mapping_executable = false;
                let mut altered_clock = clock.clone(); let mut altered_policy = policy.clone();
                match variant {
                    1 => price_key = Pubkey::new_unique(),
                    2 => owner = Pubkey::new_unique(),
                    3 => prices_data[0] ^= 1,
                    4 => mapping_data[0] ^= 1,
                    5 => prices_data[8] ^= 1,
                    6 => mapping_data[8 + index * 32] ^= 1,
                    7 => mapping_data[16_392 + index] |= 0x80,
                    8 => mapping_data[19_464 + 20 * index] = 0,
                    9 => prices_data[start..start + 8].fill(0),
                    10 => prices_data[start + 8..start + 16].copy_from_slice(&18u64.to_le_bytes()),
                    11 => altered_clock.unix_timestamp += 61,
                    12 => altered_clock.unix_timestamp -= 1,
                    13 => altered_clock.slot -= 1,
                    14 => prices_data[start + 32] ^= 1,
                    15 => altered_policy.stock_enabled = false,
                    16 => mint_data[218..226].copy_from_slice(&f64::NAN.to_le_bytes()),
                    17 => { prices_data.pop(); },
                    18 => altered_clock.unix_timestamp = 1_791_403_200,
                    19 => mapping_key = Pubkey::new_unique(),
                    20 => mapping_owner = Pubkey::new_unique(),
                    21 => mint_owner = Pubkey::new_unique(),
                    22 => prices_writable = true,
                    23 => mapping_writable = true,
                    24 => prices_executable = true,
                    25 => mapping_executable = true,
                    26 => { mapping_data.pop(); },
                    27 => mapping_data[19_464 + 20 * index + 1] = 1,
                    28 => prices_data[start + 40] = 1,
                    29 => prices_data[start + 16..start + 24].fill(0),
                    _ => {},
                }
                let mut prices_lamports = 1; let mut mapping_lamports = 1; let mut mint_lamports = 1;
                let prices = AccountInfo::new(&price_key, false, prices_writable, &mut prices_lamports,
                    &mut prices_data, &owner, prices_executable, 0);
                let mapping = AccountInfo::new(&mapping_key, false, mapping_writable, &mut mapping_lamports,
                    &mut mapping_data, &mapping_owner, mapping_executable, 0);
                let mint = AccountInfo::new(&stock, false, false, &mut mint_lamports,
                    &mut mint_data, &mint_owner, false, 0);
                let result = reference(&prices, &mapping, &mint, true, &altered_policy, &altered_clock);
                assert_eq!(result.is_ok(), variant == 0, "variant {variant}");
                if let Ok(price) = result {
                    assert_eq!(price.exponent, -15);
                    assert!(price.value > 237_463_200_000_000_000);
                    assert!(reference(&prices, &mapping, &mint, false, &policy, &clock).is_err());
                }
            }
        }
    }
}
