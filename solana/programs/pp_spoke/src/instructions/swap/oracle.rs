use super::guard::{TOKEN, TOKEN_2022};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hash;

pub const RECEIVER: Pubkey = pubkey!("rec2HHDDnjLfj4kE7VyEtFA1HPGQLK33259532cRyHp");
pub const PYTH_SOL: Pubkey = pubkey!("7AviUf9nL62mcxNbQGKm4nKDQnPjswo6c5MX4D57HmyE");
pub const PYTH_USDC: Pubkey = pubkey!("6HAuqASbHEh4w4REJEUUUCginTLfj1kwCh215ZLtMkrT");
pub const CHAINLINK_SOL: Pubkey = pubkey!("CH31Xns5z3M1cTAbKW34jcxPPciazARpijcHj9rxtemt");
pub const CHAINLINK_STORE: Pubkey = pubkey!("HEvSKofvBgfaexv23kMabbYqxasxU3mQ4ibBMEmJWHny");
pub const SOL_FEED: [u8; 32] = [0xef, 0x0d, 0x8b, 0x6f, 0xda, 0x2c, 0xeb, 0xa4, 0x1d, 0xa1, 0x5d, 0x40, 0x95, 0xd1, 0xda, 0x39, 0x2a, 0x0d, 0x2f, 0x8e, 0xd0, 0xc6, 0xc7, 0xbc, 0x0f, 0x4c, 0xfa, 0xc8, 0xc2, 0x80, 0xb5, 0x6d];
pub const USDC_FEED: [u8; 32] = [0xea, 0xa0, 0x20, 0xc6, 0x1c, 0xc4, 0x79, 0x71, 0x28, 0x13, 0x46, 0x1c, 0xe1, 0x53, 0x89, 0x4a, 0x96, 0xa6, 0xc0, 0x0b, 0x21, 0xed, 0x0c, 0xfc, 0x27, 0x98, 0xd1, 0xf9, 0xa9, 0xe9, 0xc9, 0x4a];

#[error_code]
pub enum OracleError {
    InvalidAccount,
    InvalidPrice,
    Stale,
    Confidence,
    Overflow,
    StockDisabled,
    MarketClosed,
    Impact,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct OraclePolicy {
    pub max_age_seconds: u64,
    pub max_confidence_bps: u16,
    pub cross_check_deviation_bps: u16,
    pub block_cross_check: bool,
    pub require_manager_bound: bool,
    pub stock_enabled: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Price {
    pub value: u128,
    pub exponent: i32,
}

fn fresh(timestamp: i64, now: i64, max_age: u64) -> Result<()> {
    require!(timestamp > 0 && now >= timestamp && (now - timestamp) as u64 <= max_age, OracleError::Stale);
    Ok(())
}

/// DEC-202; TODO(decision): Q1 option A uses pro-compatible sponsored Pyth prices.
pub fn pyth(account: &AccountInfo, expected: &Pubkey, feed: &[u8; 32], now: i64, policy: &OraclePolicy) -> Result<Price> {
    require!(*account.key == *expected && *account.owner == RECEIVER && !account.is_writable, OracleError::InvalidAccount);
    let data = account.try_borrow_data()?;
    require!(data.len() == 134 && data[..8] == hash(b"account:PriceUpdateV2").to_bytes()[..8]
        && data[40] == 1 && data[41..73] == *feed, OracleError::InvalidAccount);
    let value = i64::from_le_bytes(data[73..81].try_into().unwrap());
    let confidence = u64::from_le_bytes(data[81..89].try_into().unwrap());
    let exponent = i32::from_le_bytes(data[89..93].try_into().unwrap());
    let timestamp = i64::from_le_bytes(data[93..101].try_into().unwrap());
    fresh(timestamp, now, policy.max_age_seconds)?;
    require!(value > 0 && (-18..=0).contains(&exponent), OracleError::InvalidPrice);
    require!(policy.max_confidence_bps < 10_000
        && u128::from(confidence) * 10_000 <= value as u128 * u128::from(policy.max_confidence_bps), OracleError::Confidence);
    Ok(Price { value: value as u128, exponent })
}

/// DEC-202: pinned store layout, equivalent to SDK v2 single-transmission read.
pub fn chainlink_sol(account: &AccountInfo, now: i64, policy: &OraclePolicy) -> Result<Price> {
    require!(*account.key == CHAINLINK_SOL && *account.owner == CHAINLINK_STORE && !account.is_writable, OracleError::InvalidAccount);
    let data = account.try_borrow_data()?;
    require!(data.len() >= 248 && data[..8] == [96, 179, 69, 66, 128, 129, 73, 117]
        && data[8] == 2 && data[138] == 8 && data[143..147] != [0; 4]
        && data[148..152] == [1, 0, 0, 0], OracleError::InvalidAccount);
    let timestamp = u32::from_le_bytes(data[208..212].try_into().unwrap());
    fresh(i64::from(timestamp), now, policy.max_age_seconds)?;
    let value = i128::from_le_bytes(data[216..232].try_into().unwrap());
    require!(value > 0, OracleError::InvalidPrice);
    Ok(Price { value: value as u128, exponent: -8 })
}

#[event]
pub struct OracleDeviation {
    pub fund: Pubkey,
    pub deviation_bps: u128,
    pub bound_bps: u16,
}

pub fn cross_check(fund: Pubkey, pyth_price: Price, chainlink_price: Price, policy: &OraclePolicy) -> Result<()> {
    let exponent = pyth_price.exponent.min(chainlink_price.exponent);
    let primary = checked_mul(pyth_price.value, power((pyth_price.exponent - exponent) as u32)?)?;
    let secondary = checked_mul(chainlink_price.value, power((chainlink_price.exponent - exponent) as u32)?)?;
    require!(secondary > 0, OracleError::InvalidPrice);
    let deviation = checked_mul(primary.abs_diff(secondary), 10_000)?.div_ceil(secondary);
    if deviation > u128::from(policy.cross_check_deviation_bps) {
        emit!(OracleDeviation { fund, deviation_bps: deviation, bound_bps: policy.cross_check_deviation_bps });
        // TODO(decision): Q1 monitor only; sealed switch permits blocking after a ruling.
        require!(!policy.block_cross_check, OracleError::Impact);
    }
    Ok(())
}

fn checked_mul(left: u128, right: u128) -> Result<u128> {
    left.checked_mul(right).ok_or_else(|| error!(OracleError::Overflow))
}

fn power(exponent: u32) -> Result<u128> {
    require!(exponent <= 38, OracleError::Overflow);
    10u128.checked_pow(exponent).ok_or_else(|| error!(OracleError::Overflow))
}

fn gcd(mut left: u128, mut right: u128) -> u128 {
    while right != 0 { let remainder = left % right; left = right; right = remainder; }
    left
}

/// DEC-202: exact integer ratio with cancellation, rounded upward at the final minimum.
pub fn minimum(amount: u64, input: Price, output: Price, input_decimals: u8, output_decimals: u8,
    api_min: u64, max_impact_bps: u16, policy: &OraclePolicy) -> Result<u64> {
    require!(input.value > 0 && output.value > 0 && input_decimals <= 18 && output_decimals <= 18, OracleError::InvalidPrice);
    // TODO(decision): Q1 option A retains EVM's optional 0 / >=10000 no-maximum semantics.
    let bounded = max_impact_bps > 0 && max_impact_bps < 10_000;
    require!(!policy.require_manager_bound || bounded, OracleError::Impact);
    if !bounded { return Ok(api_min); }
    let delta = input.exponent - output.exponent + i32::from(output_decimals) - i32::from(input_decimals);
    let mut numerator = [u128::from(amount), input.value, u128::from(10_000 - max_impact_bps), if delta > 0 { power(delta as u32)? } else { 1 }];
    let mut denominator = [output.value, 10_000, if delta < 0 { power(delta.unsigned_abs())? } else { 1 }];
    for top in &mut numerator { for bottom in &mut denominator { let common = gcd(*top, *bottom); *top /= common; *bottom /= common; } }
    let top = numerator.into_iter().try_fold(1u128, checked_mul)?;
    let bottom = denominator.into_iter().try_fold(1u128, checked_mul)?;
    let implied = u64::try_from(top.div_ceil(bottom)).map_err(|_| error!(OracleError::Overflow))?;
    Ok(api_min.max(implied))
}

pub fn mint_decimals(mint: &AccountInfo, expected: &Pubkey) -> Result<u8> {
    require!(*mint.key == *expected && (*mint.owner == TOKEN || *mint.owner == TOKEN_2022) && !mint.is_writable, OracleError::InvalidAccount);
    let data = mint.try_borrow_data()?;
    require!(data.len() >= 82 && data[45] == 1 && data[44] <= 18, OracleError::InvalidAccount);
    Ok(data[44])
}

/// DEC-198: use current ScaledUiAmount mint multiplier, never a hardcoded NVDAx factor.
pub fn multiplier(mint: &AccountInfo, now: i64) -> Result<(u128, u128)> {
    require!(*mint.owner == TOKEN_2022 && !mint.is_writable, OracleError::InvalidAccount);
    let data = mint.try_borrow_data()?;
    require!(data.len() > 166 && data[165] == 1, OracleError::InvalidAccount);
    let mut cursor = 166;
    let mut result = None;
    while cursor + 4 <= data.len() {
        let kind = u16::from_le_bytes(data[cursor..cursor + 2].try_into().unwrap());
        let length = usize::from(u16::from_le_bytes(data[cursor + 2..cursor + 4].try_into().unwrap()));
        cursor += 4;
        if kind == 0 { require!(data[cursor - 4..].iter().all(|byte| *byte == 0), OracleError::InvalidAccount); break; }
        require!(cursor + length <= data.len(), OracleError::InvalidAccount);
        if kind == 25 {
            require!(length == 56 && result.is_none(), OracleError::InvalidAccount);
            let activation = i64::from_le_bytes(data[cursor + 40..cursor + 48].try_into().unwrap());
            let offset = cursor + if now >= activation { 48 } else { 32 };
            let bits = u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
            let exponent = ((bits >> 52) & 0x7ff) as i32 - 1023 - 52;
            require!(bits >> 63 == 0 && ((bits >> 52) & 0x7ff) != 0 && ((bits >> 52) & 0x7ff) != 0x7ff
                && (-100..=60).contains(&exponent), OracleError::InvalidPrice);
            let significand = u128::from((bits & ((1u64 << 52) - 1)) | (1u64 << 52));
            result = Some(if exponent < 0 { (significand, 1u128 << exponent.unsigned_abs()) }
                else { (significand.checked_shl(exponent as u32).ok_or(OracleError::Overflow)?, 1) });
        }
        cursor += length;
    }
    result.ok_or_else(|| error!(OracleError::InvalidAccount))
}

pub fn stock_price(underlying: Price, mint: &AccountInfo, now: i64) -> Result<Price> {
    let (numerator, denominator) = multiplier(mint, now)?;
    let value = checked_mul(underlying.value, numerator)? / denominator;
    require!(value > 0, OracleError::InvalidPrice);
    Ok(Price { value, exponent: underlying.exponent })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy() -> OraclePolicy { OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
        cross_check_deviation_bps: 50, block_cross_check: false, require_manager_bound: false, stock_enabled: false } }
    #[test]
    fn stricter_api_or_oracle_minimum_and_optional_manager_bound() {
        let usdc = Price { value: 100_000_000, exponent: -8 };
        let sol = Price { value: 12_000_000_000, exponent: -8 };
        assert_eq!(minimum(15_000_000, usdc, sol, 6, 9, 1, 100, &policy()).unwrap(), 123_750_000);
        assert_eq!(minimum(15_000_000, usdc, sol, 6, 9, 125_000_000, 100, &policy()).unwrap(), 125_000_000);
        assert_eq!(minimum(15_000_000, usdc, sol, 6, 9, 1, 0, &policy()).unwrap(), 1);
        assert_eq!(minimum(15_000_000, usdc, sol, 6, 9, 1, 10_000, &policy()).unwrap(), 1);
        let mut required = policy(); required.require_manager_bound = true;
        assert!(minimum(1, usdc, sol, 6, 9, 1, 0, &required).is_err());
        assert_eq!(minimum(1, usdc, sol, 6, 9, 1, 100, &policy()).unwrap(), 9);
    }
    #[test]
    fn stale_future_and_cross_check_switch() {
        assert!(fresh(100, 221, 120).is_err()); assert!(fresh(222, 221, 120).is_err());
        assert!(fresh(100, 220, 120).is_ok());
        let first = Price { value: 100, exponent: 0 }; let second = Price { value: 101, exponent: 0 };
        assert!(cross_check(Pubkey::default(), first, second, &policy()).is_ok());
        let mut strict = policy(); strict.block_cross_check = true;
        assert!(cross_check(Pubkey::default(), first, second, &strict).is_err());
    }
}
