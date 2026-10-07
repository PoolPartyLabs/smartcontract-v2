use super::guards::{require_fund_address, CoreError};
use crate::state::{FundState, kamino::KaminoPosition, raydium::RaydiumPosition};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct PruneRegistry<'info> {
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
}

/// DEC-151/191/195: detach zero-exposure entries; keep rent and replay evidence in their original accounts.
pub fn handler(ctx: Context<PruneRegistry>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty() && ctx.accounts.fund.active_command == Pubkey::default(), CoreError::InvalidConfiguration);
    require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    for account in ctx.remaining_accounts {
        require_keys_eq!(*account.owner, crate::ID, CoreError::InvalidConfiguration);
        let data = account.try_borrow_data()?;
        if data.starts_with(KaminoPosition::DISCRIMINATOR) {
            let position = KaminoPosition::try_deserialize(&mut &data[..])?;
            require!(position.fund == ctx.accounts.fund.key() && vacant_kamino(&position), CoreError::InvalidConfiguration);
            require_keys_eq!(*account.key, Pubkey::find_program_address(&[b"position", position.fund.as_ref(), position.reserve.as_ref()], &crate::ID).0,
                CoreError::InvalidConfiguration);
        } else if data.starts_with(crate::state::transit::Transit::DISCRIMINATOR) {
            let transit = crate::state::transit::Transit::try_deserialize(&mut &data[..])?;
            require!(transit.fund == ctx.accounts.fund.key() && transit.outbound && transit.received,
                CoreError::InvalidConfiguration);
            require!(!ctx.accounts.fund.transit_registry.contains(account.key), CoreError::InvalidConfiguration);
            continue;
        } else {
            let position = RaydiumPosition::try_deserialize(&mut &data[..])?;
            require!(position.fund == ctx.accounts.fund.key() && position.closed && position.liquidity == 0, CoreError::InvalidConfiguration);
            require_keys_eq!(*account.key, Pubkey::find_program_address(&[b"position", position.fund.as_ref(), position.personal_position.as_ref()], &crate::ID).0,
                CoreError::InvalidConfiguration);
        }
        let index = ctx.accounts.fund.position_registry.iter().position(|key| *key == *account.key)
            .ok_or(CoreError::InvalidConfiguration)?;
        ctx.accounts.fund.position_registry.remove(index);
    }
    Ok(())
}

fn vacant_kamino(position: &KaminoPosition) -> bool {
    position.units == 0 && position.principal == 0 && position.pending_units == 0
        && position.idle_principal == 0 && position.idle_income == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pending_units_or_recorded_value_never_become_garbage() {
        let bytes = vec![0; KaminoPosition::INIT_SPACE];
        let mut position = KaminoPosition::deserialize(&mut bytes.as_slice()).unwrap();
        assert!(vacant_kamino(&position));
        position.pending_units = 1;
        assert!(!vacant_kamino(&position));
        position.pending_units = 0;
        position.principal = 1;
        assert!(!vacant_kamino(&position));
    }
}
