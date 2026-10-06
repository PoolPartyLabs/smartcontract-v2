use super::snapshot::ReportError;
use crate::instructions::core::binding::word;
use anchor_lang::prelude::*;

pub type Word = [u8; 32];

#[derive(Default, Clone)]
pub struct NativeReport {
    pub fund_id: Word,
    pub mandate_hash: Word,
    pub native_mandate_hash: Word,
    pub sequence: u64,
    pub chain: u64,
    pub slot: u64,
    pub timestamp: u64,
    pub unallocated: Vec<[Word; 2]>,
    pub positions: Vec<[Word; 13]>,
    pub cumulative_income: Vec<[Word; 2]>,
    pub collected_income: Vec<[Word; 2]>,
    pub cumulative_received: u128,
    pub cumulative_sent_home: u128,
    pub arrived: Vec<[Word; 2]>,
    pub in_flight: Vec<[Word; 3]>,
    pub unwind_results: Vec<u8>,
    pub collection_results: Vec<u8>,
    pub mint_states: Vec<[Word; 7]>,
}

fn array<const SIZE: usize>(items: &[[Word; SIZE]]) -> Vec<u8> {
    let mut encoded = word(items.len() as u128).to_vec();
    for item in items {
        for entry in item {
            encoded.extend_from_slice(entry);
        }
    }
    encoded
}

fn bytes(data: &[u8]) -> Vec<u8> {
    let mut encoded = word(data.len() as u128).to_vec();
    encoded.extend_from_slice(data);
    encoded.resize(32 + data.len().div_ceil(32) * 32, 0);
    encoded
}

pub fn signed_word(value: i64) -> Word {
    let mut encoded = if value < 0 { [255; 32] } else { [0; 32] };
    encoded[24..].copy_from_slice(&value.to_be_bytes());
    encoded
}

/// DEC-188, DEC-192: canonical T2a ReportCodecV6 ABI, every pubkey lossless.
pub fn encode(report: &NativeReport) -> Result<Vec<u8>> {
    require!(
        report.unallocated.len() <= 3
            && report.positions.len() <= 64
            && report.cumulative_income.len() <= 3
            && report.collected_income.len() <= 3
            && report.arrived.len() <= 256
            && report.in_flight.len() <= 256
            && report.mint_states.len() <= 3
            && report.unwind_results.len() <= 4096
            && report.collection_results.len() <= 4096,
        ReportError::ReportTooLarge
    );
    let mut head = vec![
        report.fund_id,
        report.mandate_hash,
        report.native_mandate_hash,
        word(u128::from(report.sequence)),
        word(u128::from(report.chain)),
        word(u128::from(report.slot)),
        word(u128::from(report.timestamp)),
        word(0),
        word(0),
        word(0),
        word(0),
        word(report.cumulative_received),
        word(report.cumulative_sent_home),
        word(0),
        word(0),
        word(0),
        word(0),
        word(0),
    ];
    let dynamic = [
        (7, array(&report.unallocated)),
        (8, array(&report.positions)),
        (9, array(&report.cumulative_income)),
        (10, array(&report.collected_income)),
        (13, array(&report.arrived)),
        (14, array(&report.in_flight)),
        (15, bytes(&report.unwind_results)),
        (16, bytes(&report.collection_results)),
        (17, array(&report.mint_states)),
    ];
    let mut tail = Vec::new();
    for (index, data) in dynamic {
        head[index] = word((18 * 32 + tail.len()) as u128);
        tail.extend(data);
    }
    let mut encoded = [word(6), word(64)].concat();
    encoded.extend(head.concat());
    encoded.extend(tail);
    require!(encoded.len() <= 48_000, ReportError::ReportTooLarge);
    Ok(encoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(input: &str) -> Vec<u8> {
        let input = input.trim().trim_start_matches("0x");
        (0..input.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&input[index..index + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn both_t2a_golden_vectors_match_byte_for_byte() {
        let usdc = crate::instructions::core::custody::USDC.to_bytes();
        let stock = crate::instructions::core::custody::TSLAX.to_bytes();
        let mut report = NativeReport {
            fund_id: word(1),
            mandate_hash: word(2),
            native_mandate_hash: word(3),
            sequence: 1,
            chain: 1,
            slot: 453_978_307,
            timestamp: 1_791_286_864,
            unallocated: vec![[usdc, word(50_000_000)]],
            arrived: vec![[word(900), word(49_990_000)]],
            mint_states: vec![[
                stock,
                word(0x3ff0000000000000),
                word(0x3ff0000000000000),
                word(0),
                word(0),
                word(0),
                word(0),
            ]],
            ..NativeReport::default()
        };
        assert_eq!(
            encode(&report).unwrap(),
            hex(include_str!(
                "../../../../../tests/report/fixtures/solana-report-v6.hex"
            ))
        );
        report.positions = vec![[
            word(300),
            word(400),
            word(0),
            [255; 32],
            signed_word(-100),
            signed_word(100),
            word(1000),
            stock,
            usdc,
            word(12),
            word(34),
            word(56),
            word(78),
        ]];
        report.in_flight = vec![[word(901), word(48_000_000), word(1)]];
        assert_eq!(
            encode(&report).unwrap(),
            hex(include_str!(
                "../../../../../tests/report/fixtures/solana-report-v6-position.hex"
            ))
        );
    }

    #[test]
    fn oversized_payloads_fail_instead_of_truncating() {
        let report = NativeReport {
            in_flight: vec![[word(1); 3]; 257],
            ..NativeReport::default()
        };
        assert!(encode(&report).is_err());
    }
}
