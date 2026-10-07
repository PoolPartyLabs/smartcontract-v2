use super::{guard::TOKEN_2022, oracle::{self, OracleError, OraclePolicy, Price}};
use anchor_lang::prelude::*;

pub const PROGRAM: Pubkey = pubkey!("HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ");
pub const PRICES: Pubkey = pubkey!("3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH");
pub const MAPPINGS: Pubkey = pubkey!("4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg");
pub const TSLAX: Pubkey = pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB");
pub const NVDAX: Pubkey = pubkey!("Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh");
const TSLA_FEED: [u8; 32] = [0,8,0x4e,0xdc,0x84,0x4a,0x6f,0x88,0x44,0x9c,0x59,0xc8,0xcf,0xcd,0xb2,0x22,0x57,0x99,0xa2,0x33,0x05,0x03,0x47,0x2c,0xb0,0xbc,0x4f,0x93,0x69,0xa7,0x17,0xfa];
const NVDA_FEED: [u8; 32] = [0,8,0xad,0xc1,0x84,0x84,0x7b,0xa8,0xd1,0x7f,0,0x30,0xc1,0x5e,0x78,0xf6,0x1b,0x83,0xed,0xa2,0xe1,0x90,0xf3,0x03,0x46,0xc4,0xea,0x3b,0xab,0xed,0x64,0x7d];

/// DEC-198, DEC-204: admit only the regular session; unknown calendars are unavailable.
/// TODO(decision): approve Scope option A and the calendar horizon before enabling Funds.
pub fn regular_session(now: i64) -> Result<(i64, i64)> {
    const YEAR_START: i64 = 1_767_225_600;
    const YEAR_END: i64 = 1_798_761_600;
    require!((YEAR_START..YEAR_END).contains(&now), OracleError::MarketClosed);
    let offset = if (1_772_953_200..1_793_512_800).contains(&now) { 4 * 3600 } else { 5 * 3600 };
    let eastern = now - offset;
    let day = eastern.div_euclid(86_400);
    let ordinal = day - YEAR_START / 86_400;
    let weekday = (day + 4).rem_euclid(7);
    require!(weekday != 0 && weekday != 6
        && ![0,18,46,92,144,169,183,249,329,358].contains(&ordinal), OracleError::MarketClosed);
    let open = day * 86_400 + offset + 9 * 3600 + 30 * 60;
    let close = day * 86_400 + offset + if [330,357].contains(&ordinal) { 13 * 3600 } else { 16 * 3600 };
    require!(now >= open && now < close, OracleError::MarketClosed);
    Ok((open, close))
}

fn integer(bytes: &[u8], offset: usize) -> Result<u64> {
    let value = bytes.get(offset..offset + 8).ok_or(OracleError::InvalidAccount)?;
    Ok(u64::from_le_bytes(value.try_into().map_err(|_| OracleError::InvalidAccount)?))
}

/// DEC-203, DEC-204: read the pinned Open v8 underlying, never an AllUpdates/xStock slot.
/// Layout pin: Kamino-Finance/scope 8d01cb8cfb9cfb3f75aec8ee39bcf9f6b40b16c5.
pub fn reference(prices: &AccountInfo, mappings: &AccountInfo, mint: &AccountInfo,
    enabled: bool, policy: &OraclePolicy, clock: &Clock) -> Result<Price> {
    require!(enabled && policy.stock_enabled, OracleError::StockDisabled);
    let (open, _) = regular_session(clock.unix_timestamp)?;
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
        && timestamp >= open && timestamp <= clock.unix_timestamp
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
    fn calendar_handles_dst_holidays_early_closes_and_unknown_years() {
        for open in [1_791_379_800, 1_791_466_200, 1_791_552_600] {
            assert!(regular_session(open - 1).is_err());
            assert!(regular_session(open).is_ok());
            assert!(regular_session(open + 23_399).is_ok());
            assert!(regular_session(open + 23_400).is_err());
        }
        for closed in [1_767_277_800, 1_768_834_800, 1_791_640_800,
            1_795_705_200, 1_798_210_800, 1_799_074_800] {
            assert!(regular_session(closed).is_err(), "{closed}");
        }
        for day in [1_795_737_600, 1_798_070_400] {
            assert!(regular_session(day + 14 * 3600 + 30 * 60).is_ok());
            assert!(regular_session(day + 18 * 3600 - 1).is_ok());
            assert!(regular_session(day + 18 * 3600).is_err());
        }
        assert!(regular_session(1_767_312_000 + 14 * 3600 + 30 * 60).is_ok());
        assert!(regular_session(1_767_312_000 + 14 * 3600 + 30 * 60 - 1).is_err());
    }
}
