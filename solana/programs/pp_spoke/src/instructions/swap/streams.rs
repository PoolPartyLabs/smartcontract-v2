use super::oracle::{OracleError, OraclePolicy, Price};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::{AccountMeta, Instruction}, program::{get_return_data, invoke}};

pub const VERIFIER: Pubkey = pubkey!("Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c");
pub const VERIFY: [u8; 8] = [133, 161, 141, 48, 120, 198, 88, 150];

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct StockPolicy {
    pub feed_id: [u8; 32],
    pub report_config: Pubkey,
    pub access_controller: Pubkey,
    pub price_decimals: u8,
}

fn unsigned(data: &[u8], field: usize, width: usize) -> Result<u128> {
    let word = &data[field * 32..(field + 1) * 32];
    require!(word[..32 - width].iter().all(|byte| *byte == 0), OracleError::InvalidPrice);
    let mut encoded = [0u8; 16];
    encoded[16 - width..].copy_from_slice(&word[32 - width..]);
    Ok(u128::from_be_bytes(encoded))
}

/// DEC-198, DEC-202: authenticated v10 underlying equity, regular-session-only.
pub fn decode_v10(report: &[u8], stock: &StockPolicy, policy: &OraclePolicy, now: i64) -> Result<Price> {
    require!(policy.stock_enabled, OracleError::StockDisabled);
    require!(report.len() == 13 * 32 && report[..32] == stock.feed_id
        && stock.feed_id[..2] == [0, 10] && stock.price_decimals <= 18 && now >= 0, OracleError::InvalidPrice);
    let valid_from = unsigned(report, 1, 4)?;
    let observed = unsigned(report, 2, 4)?;
    let expires = unsigned(report, 5, 4)?;
    let source_ns = unsigned(report, 6, 8)?;
    let now_seconds = now as u128;
    require!(valid_from <= observed && observed <= now_seconds && now_seconds <= expires
        && now_seconds - observed <= u128::from(policy.max_age_seconds)
        && source_ns <= now_seconds * 1_000_000_000
        && now_seconds * 1_000_000_000 - source_ns <= u128::from(policy.max_age_seconds) * 1_000_000_000
        && source_ns > 0, OracleError::Stale);
    require!(unsigned(report, 8, 4)? == 2, OracleError::MarketClosed);
    let value = unsigned(report, 7, 16)?;
    require!(value > 0, OracleError::InvalidPrice);
    let activation = unsigned(report, 11, 4)?;
    // TODO(decision): fail closed at a pending corporate action until stream/mint units are reconciled.
    require!(activation == 0 || now_seconds < activation, OracleError::InvalidPrice);
    Ok(Price { value, exponent: -i32::from(stock.price_decimals) })
}

pub fn verify_instruction(stock: &StockPolicy, user: Pubkey, report: &[u8]) -> Result<Instruction> {
    require!(!report.is_empty() && report.len() <= 4096, OracleError::InvalidPrice);
    let mut data = VERIFY.to_vec();
    data.extend_from_slice(&(report.len() as u32).to_le_bytes());
    data.extend_from_slice(report);
    Ok(Instruction { program_id: VERIFIER, accounts: vec![
        AccountMeta::new_readonly(Pubkey::find_program_address(&[b"verifier"], &VERIFIER).0, false),
        AccountMeta::new_readonly(stock.access_controller, false),
        AccountMeta::new_readonly(user, true),
        AccountMeta::new_readonly(stock.report_config, false),
    ], data })
}

/// DEC-202; TODO(decision): Q2 option C disables stock until subscribed feed/config are sealed.
pub fn verify_stock<'info>(program: &AccountInfo<'info>, accounts: &[AccountInfo<'info>], report: &[u8],
    stock: &StockPolicy, policy: &OraclePolicy, now: i64) -> Result<Price> {
    require!(policy.stock_enabled, OracleError::StockDisabled);
    require!(*program.key == VERIFIER && program.executable && accounts.len() == 4
        && accounts[2].is_signer, OracleError::InvalidAccount);
    let instruction = verify_instruction(stock, *accounts[2].key, report)?;
    for (index, (expected, actual)) in instruction.accounts.iter().zip(accounts).enumerate() {
        require!(expected.pubkey == *actual.key && (index == 2 || !actual.is_writable), OracleError::InvalidAccount);
    }
    require!(*accounts[0].owner == VERIFIER, OracleError::InvalidAccount);
    let mut infos = accounts.to_vec(); infos.push(program.clone());
    invoke(&instruction, &infos)?;
    let (owner, verified) = get_return_data().ok_or(OracleError::InvalidPrice)?;
    require!(owner == VERIFIER, OracleError::InvalidAccount);
    decode_v10(&verified, stock, policy, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Vec<u8>, StockPolicy, OraclePolicy) {
        let mut report = vec![0; 416]; report[1] = 10;
        for (field, value) in [(1, 100u128), (2, 110), (5, 200), (6, 110_000_000_000), (7, 120_000_000_000_000_000_000), (8, 2)] {
            report[field * 32 + 16..field * 32 + 32].copy_from_slice(&value.to_be_bytes());
        }
        let stock = StockPolicy { feed_id: report[..32].try_into().unwrap(), report_config: Pubkey::new_unique(),
            access_controller: Pubkey::new_unique(), price_decimals: 18 };
        let policy = OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
            cross_check_deviation_bps: 50, block_cross_check: false, require_manager_bound: false, stock_enabled: true };
        (report, stock, policy)
    }
    #[test]
    fn v10_session_staleness_disabled_and_wire() {
        let (report, stock, mut policy) = fixture();
        assert_eq!(decode_v10(&report, &stock, &policy, 120).unwrap().value, 120_000_000_000_000_000_000);
        assert!(decode_v10(&report, &stock, &policy, 201).is_err());
        assert!(decode_v10(&report, &stock, &policy, 109).is_err());
        let mut closed = report.clone(); closed[8 * 32 + 31] = 1;
        assert!(decode_v10(&closed, &stock, &policy, 120).is_err());
        let mut stale = report.clone(); stale[6 * 32..7 * 32].fill(0);
        assert!(decode_v10(&stale, &stock, &policy, 120).is_err());
        policy.stock_enabled = false;
        assert!(decode_v10(&report, &stock, &policy, 120).is_err());
        let instruction = verify_instruction(&stock, Pubkey::new_unique(), &[1, 2, 3]).unwrap();
        assert_eq!(&instruction.data[..8], &VERIFY);
        assert_eq!(&instruction.data[8..12], &3u32.to_le_bytes());
        assert!(instruction.accounts[2].is_signer);
    }
}
