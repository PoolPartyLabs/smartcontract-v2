use super::codec::{self, NativeReport};
use crate::instructions::core::{binding::word, custody, guards::require_fund_address};
use crate::state::{FundState, TokenLedger, kamino::KaminoPosition, raydium::RaydiumPosition, transit::Transit};
use anchor_lang::prelude::*;

#[error_code]
pub enum ReportError {
    InvalidAccounts,
    AdapterNotIntegrated,
    TransitNotIntegrated,
    ResultsNotIntegrated,
    StockWitnessNotIntegrated,
    ReportTooLarge,
    InvalidWormhole,
    SequenceOverflow,
    OrderExecutionNotIntegrated,
    InvalidOrder,
}

/// DEC-093, DEC-192: never accept keeper-supplied quantities or silently omit live exposure.
pub fn snapshot(
    fund: &FundState,
    key: Pubkey,
    accounts: &[AccountInfo],
    clock: &Clock,
) -> Result<NativeReport> {
    require_fund_address(fund, &key)?;
    require!(fund.active_positions == 0 || !fund.position_registry.is_empty(), ReportError::AdapterNotIntegrated);
    require!(fund.pending_transits as usize == fund.transit_registry.len(), ReportError::TransitNotIntegrated);
    require!(fund.pending_results == 0, ReportError::ResultsNotIntegrated);
    require!(
        accounts.len() >= fund.assets.len() * 2 && clock.unix_timestamp >= 0,
        ReportError::InvalidAccounts
    );
    let vault =
        Pubkey::create_program_address(&[b"vault", key.as_ref(), &[fund.vault_bump]], &crate::ID)
            .map_err(|_| error!(ReportError::InvalidAccounts))?;
    let mut report = NativeReport {
        fund_id: fund.fund_id,
        mandate_hash: fund.mandate_hash,
        native_mandate_hash: fund.native_mandate_hash,
        sequence: fund
            .report_sequence
            .checked_add(1)
            .ok_or_else(|| error!(ReportError::SequenceOverflow))?,
        chain: fund.spoke_chain_id,
        slot: clock.slot,
        timestamp: clock.unix_timestamp as u64,
        cumulative_received: fund.cumulative_received,
        cumulative_sent_home: fund.cumulative_sent_home,
        ..NativeReport::default()
    };
    for (asset, pair) in fund.assets.iter().zip(accounts[..fund.assets.len() * 2].chunks_exact(2)) {
        let ledger_key = Pubkey::find_program_address(
            &[b"ledger", key.as_ref(), asset.mint.as_ref()],
            &crate::ID,
        )
        .0;
        require_keys_eq!(*pair[0].key, ledger_key, ReportError::InvalidAccounts);
        require_keys_eq!(*pair[0].owner, crate::ID, ReportError::InvalidAccounts);
        let ledger = TokenLedger::try_deserialize(&mut &pair[0].try_borrow_data()?[..])?;
        require!(
            ledger.fund == key && ledger.mint == asset.mint,
            ReportError::InvalidAccounts
        );
        let observed = custody::recorded_custody_balance(&pair[1], &vault, &asset.mint)?;
        ledger.excess(observed)?;
        report
            .unallocated
            .push([asset.mint.to_bytes(), word(u128::from(ledger.principal))]);
        if ledger.collected_income != 0 {
            report.collected_income.push([
                asset.mint.to_bytes(),
                word(u128::from(ledger.collected_income)),
            ]);
        }
        if ledger.cumulative_income != 0 {
            report
                .cumulative_income
                .push([asset.mint.to_bytes(), word(ledger.cumulative_income)]);
        }
    }
    let mut cursor = fund.assets.len() * 2;
    for (index, asset) in fund.assets.iter().enumerate().filter(|(_, asset)| asset.stock) {
        let mint = accounts.get(cursor).ok_or(ReportError::StockWitnessNotIntegrated)?;
        require_keys_eq!(*mint.key, asset.mint, ReportError::InvalidAccounts);
        report.mint_states.push(crate::instructions::core::stock::witness(mint, &accounts[index * 2 + 1])?);
        cursor += 1;
    }
    let mut active = 0usize;
    for position_key in &fund.position_registry {
        let record = accounts.get(cursor).ok_or(ReportError::AdapterNotIntegrated)?;
        cursor += 1;
        require_keys_eq!(*record.key, *position_key, ReportError::InvalidAccounts);
        require_keys_eq!(*record.owner, crate::ID, ReportError::InvalidAccounts);
        let data = record.try_borrow_data()?;
        if data.get(..8) == Some(KaminoPosition::DISCRIMINATOR) {
            let mut position = KaminoPosition::try_deserialize(&mut &data[..])?;
            require_keys_eq!(position.fund, key, ReportError::InvalidAccounts);
            let expected = Pubkey::find_program_address(&[b"position", key.as_ref(), position.reserve.as_ref()], &crate::ID).0;
            require_keys_eq!(*position_key, expected, ReportError::InvalidAccounts);
            crate::instructions::core::admission::venue(fund, crate::instructions::kamino::protocol::PROGRAM, Pubkey::default(), position.reserve)?;
            if position.units == 0 { continue; }
            active += 1;
            let valuation_accounts = accounts.get(cursor..cursor + 4).ok_or(ReportError::AdapterNotIntegrated)?;
            cursor += 4;
            let value = crate::instructions::kamino::valuation::refresh_and_value(&mut position, &vault, &valuation_accounts[0], &valuation_accounts[1], &valuation_accounts[2], &valuation_accounts[3])?;
            report.positions.push([
                crate::instructions::kamino::protocol::PROGRAM.to_bytes(), [0;32], position.reserve.to_bytes(), position_key.to_bytes(),
                word(0), word(0), word(0), custody::USDC.to_bytes(), [0;32], word(u128::from(value.principal)), word(0), word(u128::from(value.income)), word(0),
            ]);
        } else {
            let position = RaydiumPosition::try_deserialize(&mut &data[..])?;
            require_keys_eq!(position.fund, key, ReportError::InvalidAccounts);
            let expected = Pubkey::find_program_address(&[b"position", key.as_ref(), position.personal_position.as_ref()], &crate::ID).0;
            require_keys_eq!(*position_key, expected, ReportError::InvalidAccounts);
            crate::instructions::core::admission::venue(fund, crate::instructions::raydium::wire::CLMM, position.pool, Pubkey::default())?;
            if position.closed { require!(position.liquidity == 0, ReportError::InvalidAccounts); continue; }
            active += 1;
            let valuation_accounts = accounts.get(cursor..cursor + 4).ok_or(ReportError::AdapterNotIntegrated)?;
            cursor += 4;
            require_keys_eq!(*valuation_accounts[0].key, position.pool, ReportError::InvalidAccounts);
            require_keys_eq!(*valuation_accounts[1].key, position.personal_position, ReportError::InvalidAccounts);
            let native = crate::instructions::raydium::validation::position(&valuation_accounts[1])?;
            require!(native.mint == position.nft_mint && native.lower == position.tick_lower && native.upper == position.tick_upper && native.liquidity == position.liquidity, ReportError::InvalidAccounts);
            let pool = crate::instructions::raydium::validation::pool(&valuation_accounts[0])?;
            let (principal, income) = crate::instructions::raydium::validation::valuation(&valuation_accounts[0], &valuation_accounts[1], &valuation_accounts[2], &valuation_accounts[3])?;
            report.positions.push([
                crate::instructions::raydium::wire::CLMM.to_bytes(), position.pool.to_bytes(), [0;32], position.personal_position.to_bytes(),
                codec::signed_word(i64::from(position.tick_lower)), codec::signed_word(i64::from(position.tick_upper)), word(position.liquidity),
                pool.mints[0].to_bytes(), pool.mints[1].to_bytes(), word(u128::from(principal[0])), word(u128::from(principal[1])), word(u128::from(income[0])), word(u128::from(income[1])),
            ]);
        }
    }
    require!(active == fund.active_positions as usize, ReportError::AdapterNotIntegrated);
    for transit_key in &fund.transit_registry {
        let account = accounts.get(cursor).ok_or(ReportError::TransitNotIntegrated)?;
        cursor += 1;
        require_keys_eq!(*account.key, *transit_key, ReportError::InvalidAccounts);
        require_keys_eq!(*account.owner, crate::ID, ReportError::InvalidAccounts);
        let transit = Transit::try_deserialize(&mut &account.try_borrow_data()?[..])?;
        require_keys_eq!(transit.fund, key, ReportError::InvalidAccounts);
        require_keys_eq!(*transit_key, Pubkey::find_program_address(&[b"transit", key.as_ref(), &transit.transit_id], &crate::ID).0, ReportError::InvalidAccounts);
        require!(transit.in_flight == transit.amount.checked_sub(transit.max_fee).ok_or(ReportError::InvalidAccounts)?, ReportError::InvalidAccounts);
        if transit.outbound {
            report.in_flight.push([transit.transit_id, word(u128::from(transit.in_flight)), word(0)]);
        } else {
            require!(transit.received && transit.credited == transit.amount.checked_sub(transit.fee_executed).ok_or(ReportError::InvalidAccounts)?, ReportError::InvalidAccounts);
            report.arrived.push([transit.transit_id, word(u128::from(transit.credited))]);
        }
    }
    require!(cursor == accounts.len(), ReportError::InvalidAccounts);
    Ok(report)
}

pub fn encoded_snapshot(
    fund: &FundState,
    key: Pubkey,
    accounts: &[AccountInfo],
    clock: &Clock,
) -> Result<Vec<u8>> {
    codec::encode(&snapshot(fund, key, accounts, clock)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_silently_omit_unintegrated_exposure_or_stock_witness() {
        let (mut fund, key) = crate::instructions::core::guards::fixture();
        let clock = Clock {
            slot: 100,
            unix_timestamp: 1000,
            ..Clock::default()
        };
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_ok());
        fund.active_positions = 1;
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_err());
        fund.active_positions = 0;
        fund.pending_transits = 1;
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_err());
        fund.pending_transits = 0;
        fund.pending_results = 1;
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_err());
        fund.pending_results = 0;
        fund.assets.push(crate::state::Asset {
            mint: custody::TSLAX,
            accounting_id: [1; 20],
            stock: true,
        });
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_err());
        fund.assets.clear();
        fund.report_sequence = u64::MAX;
        assert!(encoded_snapshot(&fund, key, &[], &clock).is_err());
    }
}
