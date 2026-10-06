use super::{protocol::*, KaminoError};
use anchor_lang::prelude::*;

/// DEC-193: pinned direct-reserve CPI accounts; legacy SPL USDC and cTokens only.
#[derive(Accounts)]
pub struct KaminoVenue<'info> {
    /// CHECK: executable identity is pinned below and by refresh().
    #[account(address = PROGRAM @ KaminoError::WrongProgram, executable)]
    pub kamino_program: UncheckedAccount<'info>,
    /// CHECK: pinned identity and owner; deployed program validates its complete layout.
    #[account(address = MARKET @ KaminoError::WrongReserve, owner = PROGRAM)]
    pub market: UncheckedAccount<'info>,
    /// CHECK: pinned identity, owner and decoded reserve relationships.
    #[account(mut, address = RESERVE @ KaminoError::WrongReserve, owner = PROGRAM)]
    pub reserve: UncheckedAccount<'info>,
    /// CHECK: validated against the Kamino market authority PDA.
    pub market_authority: UncheckedAccount<'info>,
    /// CHECK: pinned SPL mint, checked before CPI.
    #[account(address = USDC, owner = TOKEN)]
    pub liquidity_mint: UncheckedAccount<'info>,
    /// CHECK: pinned SPL mint and mint authority, checked before CPI.
    #[account(mut, address = COLLATERAL, owner = TOKEN)]
    pub collateral_mint: UncheckedAccount<'info>,
    /// CHECK: pinned reserve supply account and authority, checked before CPI.
    #[account(mut, address = LIQUIDITY_VAULT, owner = TOKEN)]
    pub liquidity_supply: UncheckedAccount<'info>,
    /// CHECK: canonical vault USDC ATA, without delegate/close authority.
    #[account(mut, owner = TOKEN)]
    pub vault_usdc: UncheckedAccount<'info>,
    /// CHECK: canonical vault collateral ATA; only recorded deltas are valued.
    #[account(mut, owner = TOKEN)]
    pub vault_collateral: UncheckedAccount<'info>,
    /// CHECK: pinned executable legacy SPL Token program.
    #[account(address = TOKEN, executable)]
    pub token_program: UncheckedAccount<'info>,
    /// CHECK: pinned instructions sysvar used by Kamino.
    #[account(address = anchor_lang::solana_program::sysvar::instructions::ID)]
    pub instructions_sysvar: UncheckedAccount<'info>,
}

impl<'info> KaminoVenue<'info> {
    pub fn validate(&self, vault: &Pubkey, recorded_units: u64) -> Result<(u64, u64)> {
        let expected = Pubkey::find_program_address(&[b"lma", MARKET.as_ref()], &PROGRAM).0;
        require_keys_eq!(
            self.market_authority.key(),
            expected,
            KaminoError::WrongReserve
        );
        for mint in [&self.liquidity_mint, &self.collateral_mint] {
            let data = mint.try_borrow_data()?;
            require!(
                data.len() == 82 && data[44] == 6 && data[45] == 1,
                KaminoError::InvalidTokenAccount
            );
            if mint.key() == COLLATERAL {
                require!(data[..4] == [1, 0, 0, 0], KaminoError::InvalidTokenAccount);
                require_keys_eq!(
                    read_key(&data, 4)?,
                    expected,
                    KaminoError::InvalidTokenAccount
                );
            }
        }
        token_balance(
            &self.liquidity_supply.to_account_info(),
            &USDC,
            &expected,
            false,
        )?;
        let usdc = token_balance(&self.vault_usdc.to_account_info(), &USDC, vault, true)?;
        let collateral = token_balance(
            &self.vault_collateral.to_account_info(),
            &COLLATERAL,
            vault,
            true,
        )?;
        require!(collateral >= recorded_units, KaminoError::MissingCollateral);
        Ok((usdc, collateral))
    }

    pub fn refresh(&self) -> Result<ReserveSnapshot> {
        refresh(
            &self.kamino_program.to_account_info(),
            &self.market.to_account_info(),
            &self.reserve.to_account_info(),
        )
    }

    pub fn invoke(
        &self,
        vault: AccountInfo<'info>,
        fund: &Pubkey,
        bump: u8,
        amount: u64,
        deposit: bool,
    ) -> Result<()> {
        let reserve = self.reserve.to_account_info();
        let market = self.market.to_account_info();
        let collateral = self.collateral_mint.to_account_info();
        let supply = self.liquidity_supply.to_account_info();
        let usdc = self.vault_usdc.to_account_info();
        let units = self.vault_collateral.to_account_info();
        let mut infos = vec![vault];
        infos.extend(if deposit {
            [reserve, market]
        } else {
            [market, reserve]
        });
        infos.push(self.market_authority.to_account_info());
        infos.push(self.liquidity_mint.to_account_info());
        infos.extend(if deposit {
            [supply, collateral, usdc, units]
        } else {
            [collateral, supply, units, usdc]
        });
        infos.push(self.token_program.to_account_info());
        let keys: [Pubkey; 10] = infos
            .iter()
            .map(|account| *account.key)
            .collect::<Vec<_>>()
            .try_into()
            .map_err(|_| KaminoError::InvalidLayout)?;
        infos.push(self.token_program.to_account_info());
        infos.push(self.instructions_sysvar.to_account_info());
        infos.push(self.kamino_program.to_account_info());
        anchor_lang::solana_program::program::invoke_signed(
            &operation(if deposit { DEPOSIT } else { REDEEM }, amount, &keys),
            &infos,
            &[&[b"vault", fund.as_ref(), &[bump]]],
        )?;
        Ok(())
    }
}
