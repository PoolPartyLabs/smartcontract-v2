use super::{protocol::*, KaminoError};
use crate::state::kamino::KaminoPosition;
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub struct KaminoValue {
    pub units: u64,
    pub value: u64,
    pub principal: u64,
    pub income: u64,
    pub slot: u64,
}

pub fn checkpoint(position: &mut KaminoPosition, reserve: ReserveSnapshot) -> Result<KaminoValue> {
    require!(!reserve.stale, KaminoError::StaleReserve);
    let value = reserve.value(position.units)?;
    let principal = position.principal.min(value);
    let income = value - principal;
    position.last_value = value;
    position.last_principal = principal;
    position.last_income = income;
    position.last_refresh_slot = reserve.slot;
    Ok(KaminoValue {
        units: position.units,
        value,
        principal,
        income,
        slot: reserve.slot,
    })
}

/// DEC-059, DEC-068, DEC-080: report builder must call this, not a cached checkpoint or wallet balance.
/// Refresh and read are atomic; interest is uncollected, and donated collateral is excluded.
pub fn refresh_and_value<'info>(
    position: &mut KaminoPosition,
    vault: &Pubkey,
    collateral: &AccountInfo<'info>,
    program: &AccountInfo<'info>,
    market: &AccountInfo<'info>,
    reserve: &AccountInfo<'info>,
) -> Result<KaminoValue> {
    require_keys_eq!(
        *vault,
        Pubkey::find_program_address(&[b"vault", position.fund.as_ref()], &crate::ID).0,
        KaminoError::Unauthorized
    );
    require_keys_eq!(position.reserve, RESERVE, KaminoError::WrongReserve);
    require!(
        token_balance(collateral, &COLLATERAL, vault, true)? >= position.units,
        KaminoError::MissingCollateral
    );
    checkpoint(position, refresh(program, market, reserve)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn position() -> KaminoPosition {
        KaminoPosition {
            fund: Pubkey::new_unique(),
            reserve: RESERVE,
            enabled: true,
            units: 100,
            principal: 100,
            idle_principal: 0,
            idle_income: 0,
            cumulative_realized_income: 0,
            pending_units: 0,
            pending_min_liquidity: 0,
            last_value: 0,
            last_principal: 0,
            last_income: 0,
            last_refresh_slot: 0,
        }
    }

    #[test]
    fn reports_preserve_cost_basis_through_losses_and_recovery() {
        let mut position = position();
        let mut reserve = ReserveSnapshot {
            slot: 77,
            stale: false,
            available: 80,
            liquidity_sf: 80 * SCALE,
            collateral_supply: 100,
            queued_units: 0,
        };
        assert_eq!(checkpoint(&mut position, reserve).unwrap().principal, 80);
        assert_eq!(position.principal, 100);
        reserve.liquidity_sf = 120 * SCALE;
        let value = checkpoint(&mut position, reserve).unwrap();
        assert_eq!((value.principal, value.income), (100, 20));
        assert_eq!(position.principal, 100);
        assert_eq!(position.cumulative_realized_income, 0);
        assert_eq!(position.idle_income, 0);
        reserve.stale = true;
        assert!(checkpoint(&mut position, reserve).is_err());
    }

    #[test]
    fn valuation_is_not_capped_to_cash_and_queue_reduces_withdrawability() {
        let reserve = ReserveSnapshot {
            slot: 1,
            stale: false,
            available: 10,
            liquidity_sf: 120 * SCALE,
            collateral_supply: 100,
            queued_units: 5,
        };
        assert_eq!(reserve.value(100).unwrap(), 120);
        assert_eq!(reserve.freely_available().unwrap(), 4);
    }
}
