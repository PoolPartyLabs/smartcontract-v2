use super::error::RaydiumError;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::{AccountMeta, Instruction}, program::invoke_signed};

pub const CLMM: Pubkey = pubkey!("CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK");
pub const TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const TOKEN_2022: Pubkey = pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
pub const ATA: Pubkey = pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const MEMO: Pubkey = pubkey!("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");
pub const TSLA_POOL: Pubkey = pubkey!("8aDaBQkTrS6HVMjyc6EZebgdiaXhLYGriDWKWWp1NpFF");
pub const SOL_POOL: Pubkey = pubkey!("3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv");
pub const USDC: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const TSLA: Pubkey = pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB");
pub const WSOL: Pubkey = pubkey!("So11111111111111111111111111111111111111112");

pub fn discriminator(namespace: &str, name: &str) -> [u8; 8] {
    anchor_lang::solana_program::hash::hash(format!("{namespace}:{name}").as_bytes()).to_bytes()[..8]
        .try_into().unwrap()
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct OpenArgs {
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub liquidity: u128,
    pub amount_0_max: u64,
    pub amount_1_max: u64,
    pub minimum_liquidity: u128,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct CloseArgs {
    pub amount_0_min: u64,
    pub amount_1_min: u64,
}

/// ABI pinned to raydium-clmm ed1eb41519d5355755f7df52b43fa9610938b60b.
pub fn open_data(args: &OpenArgs, lower_start: i32, upper_start: i32) -> Result<Vec<u8>> {
    require!(args.liquidity > 0 && args.minimum_liquidity > 0
        && args.liquidity >= args.minimum_liquidity, RaydiumError::InvalidRange);
    let mut data = discriminator("global", "open_position_with_token22_nft").to_vec();
    for tick in [args.tick_lower, args.tick_upper, lower_start, upper_start] {
        data.extend_from_slice(&tick.to_le_bytes());
    }
    data.extend_from_slice(&args.liquidity.to_le_bytes());
    data.extend_from_slice(&args.amount_0_max.to_le_bytes());
    data.extend_from_slice(&args.amount_1_max.to_le_bytes());
    data.extend_from_slice(&[0, 0]);
    Ok(data)
}

pub fn decrease_data(liquidity: u128, minimum: [u64; 2]) -> Vec<u8> {
    let mut data = discriminator("global", "decrease_liquidity_v2").to_vec();
    data.extend_from_slice(&liquidity.to_le_bytes());
    data.extend_from_slice(&minimum[0].to_le_bytes());
    data.extend_from_slice(&minimum[1].to_le_bytes());
    data
}

pub fn cpi<'info>(program: &AccountInfo<'info>, accounts: &[(AccountInfo<'info>, bool, bool)], data: Vec<u8>, seeds: &[&[&[u8]]]) -> Result<()> {
    let instruction = Instruction {
        program_id: *program.key,
        accounts: accounts.iter().map(|(account, writable, signer)| {
            if *writable { AccountMeta::new(*account.key, *signer) }
            else { AccountMeta::new_readonly(*account.key, *signer) }
        }).collect(),
        data,
    };
    let mut infos: Vec<AccountInfo<'info>> = accounts.iter().map(|(account, _, _)| account.clone()).collect();
    infos.push(program.clone());
    invoke_signed(&instruction, &infos, seeds).map_err(Into::into)
}

pub fn token_delegate<'info>(program: &AccountInfo<'info>, token: &AccountInfo<'info>, delegate: &AccountInfo<'info>, vault: &AccountInfo<'info>, amount: Option<u64>, seeds: &[&[&[u8]]]) -> Result<()> {
    let mut data = vec![if amount.is_some() { 4 } else { 5 }];
    if let Some(amount) = amount { data.extend_from_slice(&amount.to_le_bytes()); }
    let mut accounts = vec![(token.clone(), true, false)];
    if amount.is_some() { accounts.push((delegate.clone(), false, false)); }
    accounts.push((vault.clone(), false, true));
    cpi(program, &accounts, data, seeds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_open_wire_and_empty_position_rejection() {
        let args = OpenArgs { tick_lower: -60, tick_upper: 60, liquidity: 123,
            amount_0_max: 456, amount_1_max: 789, minimum_liquidity: 100 };
        let data = open_data(&args, -60, 0).unwrap();
        assert_eq!(data.len(), 58);
        assert_eq!(&data[8..12], &(-60i32).to_le_bytes());
        assert_eq!(&data[24..40], &123u128.to_le_bytes());
        assert_eq!(&data[56..], &[0, 0]);
        let mut empty = args;
        empty.liquidity = 0;
        assert!(open_data(&empty, 0, 0).is_err());
        assert_eq!(decrease_data(0, [0, 0]).len(), 40);
    }
}
