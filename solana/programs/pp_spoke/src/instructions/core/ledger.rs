use super::guards::CoreError;
use crate::state::TokenLedger;
use anchor_lang::prelude::*;

#[event]
pub struct LedgerChanged {
    pub fund: Pubkey,
    pub mint: Pubkey,
    pub principal: u64,
    pub collected_income: u64,
    pub cumulative_income: u128,
}

impl TokenLedger {
    pub fn recorded_total(&self) -> Result<u64> {
        self.principal
            .checked_add(self.collected_income)
            .ok_or_else(|| error!(CoreError::ArithmeticOverflow))
    }

    pub fn excess(&self, observed: u64) -> Result<u64> {
        observed
            .checked_sub(self.recorded_total()?)
            .ok_or_else(|| error!(CoreError::InvalidCustody))
    }

    /// DEC-191: only an atomic bridge/adapter receipt may call this internal helper.
    pub fn credit_principal(&mut self, amount: u64) -> Result<()> {
        self.principal = self
            .principal
            .checked_add(amount)
            .ok_or_else(|| error!(CoreError::ArithmeticOverflow))?;
        self.emit_change();
        Ok(())
    }

    pub fn debit_principal(&mut self, amount: u64) -> Result<()> {
        self.principal = self
            .principal
            .checked_sub(amount)
            .ok_or_else(|| error!(CoreError::InsufficientRecordedBalance))?;
        self.emit_change();
        Ok(())
    }

    /// DEC-079, DEC-193: realized adapter income, never balance-derived donations.
    pub fn credit_income(&mut self, amount: u64) -> Result<()> {
        let collected = self
            .collected_income
            .checked_add(amount)
            .ok_or_else(|| error!(CoreError::ArithmeticOverflow))?;
        let cumulative = self
            .cumulative_income
            .checked_add(u128::from(amount))
            .ok_or_else(|| error!(CoreError::ArithmeticOverflow))?;
        self.collected_income = collected;
        self.cumulative_income = cumulative;
        self.emit_change();
        Ok(())
    }

    pub fn debit_income(&mut self, amount: u64) -> Result<()> {
        self.collected_income = self
            .collected_income
            .checked_sub(amount)
            .ok_or_else(|| error!(CoreError::InsufficientRecordedBalance))?;
        self.emit_change();
        Ok(())
    }

    fn emit_change(&self) {
        emit!(LedgerChanged {
            fund: self.fund,
            mint: self.mint,
            principal: self.principal,
            collected_income: self.collected_income,
            cumulative_income: self.cumulative_income,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn donations_are_excess_not_principal_or_income() {
        let mut ledger = TokenLedger::default();
        ledger.credit_principal(50_000_000).unwrap();
        ledger.credit_income(12).unwrap();
        assert_eq!(ledger.excess(60_000_012).unwrap(), 10_000_000);
        assert_eq!(ledger.principal, 50_000_000);
        ledger.debit_income(12).unwrap();
        assert_eq!(ledger.cumulative_income, 12);
        assert!(ledger.debit_principal(50_000_001).is_err());
        assert_eq!(ledger.principal, 50_000_000);
    }

    #[test]
    fn overflow_and_balance_shortfalls_fail_without_partial_income_credit() {
        let mut ledger = TokenLedger {
            cumulative_income: u128::MAX,
            ..TokenLedger::default()
        };
        assert!(ledger.credit_income(1).is_err());
        assert_eq!(ledger.collected_income, 0);
        ledger.principal = u64::MAX;
        assert!(ledger.credit_principal(1).is_err());
        assert!(ledger.excess(0).is_err());
    }
}
