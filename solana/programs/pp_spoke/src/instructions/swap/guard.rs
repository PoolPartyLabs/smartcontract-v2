use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::{AccountMeta, Instruction}, program::invoke_signed};

pub const JUPITER: Pubkey = pubkey!("JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4");
pub const TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const TOKEN_2022: Pubkey = pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
pub const ATA: Pubkey = pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const WSOL: Pubkey = pubkey!("So11111111111111111111111111111111111111112");
pub const ROUTE: [u8; 8] = [229, 23, 203, 151, 122, 227, 173, 42];

#[error_code]
pub enum SwapError {
    #[msg("Manager Solana Key is not authorized")]
    Unauthorized,
    #[msg("Fund is closed")]
    Closed,
    #[msg("Jupiter program is not pinned or executable")]
    Program,
    #[msg("Unsupported Jupiter route or invalid amount")]
    Route,
    #[msg("Vault custody or account metadata changed")]
    Custody,
    #[msg("Mint is not admitted by the sealed Mandate")]
    Mint,
    #[msg("Slippage exceeds sealed configuration")]
    Slippage,
    #[msg("Actual output is below min_out")]
    MinOut,
    #[msg("Canonical sealed policy and atomic ledger integration are pending")]
    IntegrationPending,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct SwapRequest {
    pub input_mint: Pubkey,
    pub output_mint: Pubkey,
    pub requested_input: u64,
    pub min_out: u64,
    pub slippage_bps: u16,
    pub route_data: Vec<u8>,
}

/// DEC-079, DEC-080: internal principal conversion, never income. T1 must persist atomically.
#[derive(Debug, PartialEq)]
pub struct Conversion {
    pub input_mint: Pubkey,
    pub output_mint: Pubkey,
    pub input_units: u64,
    pub output_units: u64,
}

/// DEC-053, DEC-190: constructed only from T1's authenticated sealed state, not instruction data.
pub struct SealedPolicy<'policy> {
    pub mints: &'policy [Pubkey],
    pub max_slippage_bps: u16,
}

struct Snapshot<'info> {
    account: AccountInfo<'info>,
    owner: Pubkey,
    lamports: u64,
    data: Vec<u8>,
}

pub fn route_amount(request: &SwapRequest, policy: &SealedPolicy) -> Result<u64> {
    require!(request.input_mint != request.output_mint
        && policy.mints.contains(&request.input_mint)
        && policy.mints.contains(&request.output_mint), SwapError::Mint);
    require!(request.slippage_bps <= policy.max_slippage_bps
        && request.slippage_bps < 10_000, SwapError::Slippage);
    let data = &request.route_data;
    // RULINGS R5.1, DEC-193: verified V1 exact-input, one-hop Raydium CLMM only for this slice.
    // Jupiter's upstream jupiter_aggregator.json: route discriminator, variant 26/40, 100%, 0 -> 1.
    require!(data.len() == 35 && data[..8] == ROUTE
        && data[8..12] == [1, 0, 0, 0] && matches!(data[12], 26 | 40)
        && data[13..16] == [100, 0, 1] && data[34] == 0, SwapError::Route);
    let input = u64::from_le_bytes(data[16..24].try_into().unwrap());
    let quoted = u64::from_le_bytes(data[24..32].try_into().unwrap());
    let slippage = u16::from_le_bytes(data[32..34].try_into().unwrap());
    require!(input > 0 && input <= request.requested_input && quoted > 0
        && slippage == request.slippage_bps && request.min_out > 0, SwapError::Route);
    let floor = (u128::from(quoted) * u128::from(10_000 - slippage)).div_ceil(10_000);
    require!(u128::from(request.min_out) >= floor, SwapError::Slippage);
    Ok(input)
}

fn token_data(account: &AccountInfo) -> Result<Vec<u8>> {
    require!(*account.owner == TOKEN || *account.owner == TOKEN_2022, SwapError::Custody);
    let data = account.try_borrow_data()?.to_vec();
    require!(data.len() >= 165 && data[108] == 1, SwapError::Custody);
    Ok(data)
}

fn amount(data: &[u8]) -> u64 {
    u64::from_le_bytes(data[64..72].try_into().unwrap())
}

fn endpoint(account: &AccountInfo, vault: &Pubkey, mint: &Pubkey) -> Result<Vec<u8>> {
    let data = token_data(account)?;
    let expected = Pubkey::find_program_address(&[vault.as_ref(), account.owner.as_ref(), mint.as_ref()], &ATA).0;
    require!(*account.key == expected && data[..32] == mint.to_bytes()
        && data[32..64] == vault.to_bytes()
        && data[72..76] == [0; 4] && data[129..133] == [0; 4], SwapError::Custody);
    Ok(data)
}

fn unchanged(snapshot: &Snapshot, balance: Option<u64>, native_delta: i128) -> Result<()> {
    require!(*snapshot.account.owner == snapshot.owner
        && i128::from(snapshot.account.lamports()) == i128::from(snapshot.lamports) + native_delta,
        SwapError::Custody);
    let mut expected = snapshot.data.clone();
    if let Some(balance) = balance {
        expected[64..72].copy_from_slice(&balance.to_le_bytes());
    }
    require!(**snapshot.account.try_borrow_data()? == expected[..], SwapError::Custody);
    Ok(())
}

/// DEC-190, DEC-193; RULINGS R5.1: guarded CPI primitive, not a policy-authentication entrypoint.
/// Caller authenticates Manager, Fund PDA and sealed policy and commits the returned conversion atomically.
pub fn execute_guarded<'info>(
    program: &AccountInfo<'info>,
    vault: &AccountInfo<'info>,
    accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[u8]],
    request: &SwapRequest,
    policy: &SealedPolicy,
) -> Result<Conversion> {
    require!(*program.key == JUPITER && program.executable, SwapError::Program);
    require!(vault.lamports() == 0 && !vault.is_writable, SwapError::Custody);
    let input = route_amount(request, policy)?;
    require!(accounts.len() >= 9 && accounts.len() <= 48, SwapError::Route);
    require!(*accounts[1].key == *vault.key && accounts[2].is_writable && accounts[3].is_writable
        && *accounts[5].key == request.output_mint
        && (*accounts[4].key == JUPITER || accounts[4].key == accounts[3].key)
        && *accounts[6].key == JUPITER
        && *accounts[8].key == JUPITER, SwapError::Custody);
    let input_data = endpoint(&accounts[2], vault.key, &request.input_mint)?;
    let output_data = endpoint(&accounts[3], vault.key, &request.output_mint)?;
    require!(amount(&input_data) >= input, SwapError::Custody);
    let mut snapshots = Vec::new();
    let mut metas = Vec::with_capacity(accounts.len());
    for account in accounts {
        require!(!account.is_signer || account.key == vault.key, SwapError::Custody);
        require!(!account.is_writable || *account.owner != crate::ID, SwapError::Custody);
        metas.push(AccountMeta { pubkey: *account.key, is_writable: account.is_writable,
            is_signer: account.key == vault.key });
        if *account.owner == TOKEN || *account.owner == TOKEN_2022 {
            let data = account.try_borrow_data()?.to_vec();
            let is_token_account = data.len() == 165
                || (*account.owner == TOKEN_2022 && data.len() > 165 && data[165] == 2);
            if is_token_account && data[32..64] == vault.key.to_bytes()
                && !snapshots.iter().any(|snapshot: &Snapshot| snapshot.account.key == account.key) {
                snapshots.push(Snapshot { account: account.clone(), owner: *account.owner,
                    lamports: account.lamports(), data });
            }
        }
    }
    let instruction = Instruction { program_id: JUPITER, accounts: metas, data: request.route_data.clone() };
    let mut infos = accounts.to_vec();
    infos.push(program.clone());
    invoke_signed(&instruction, &infos, &[signer_seeds])?;
    let input_after = endpoint(&accounts[2], vault.key, &request.input_mint)?;
    let output_after = endpoint(&accounts[3], vault.key, &request.output_mint)?;
    let spent = amount(&input_data).checked_sub(amount(&input_after)).ok_or(SwapError::Custody)?;
    let received = amount(&output_after).checked_sub(amount(&output_data)).ok_or(SwapError::Custody)?;
    require!(spent == input && spent <= request.requested_input, SwapError::Custody);
    require!(received >= request.min_out, SwapError::MinOut);
    for snapshot in &snapshots {
        let (balance, native_delta) = if snapshot.account.key == accounts[2].key {
            (Some(amount(&input_after)), if request.input_mint == WSOL { -i128::from(spent) } else { 0 })
        } else if snapshot.account.key == accounts[3].key {
            (Some(amount(&output_after)), if request.output_mint == WSOL { i128::from(received) } else { 0 })
        } else { (None, 0) };
        unchanged(snapshot, balance, native_delta)?;
    }
    Ok(Conversion { input_mint: request.input_mint, output_mint: request.output_mint,
        input_units: spent, output_units: received })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> SwapRequest {
        let mut route_data = ROUTE.to_vec();
        route_data.extend([1, 0, 0, 0, 40, 100, 0, 1]);
        route_data.extend(100u64.to_le_bytes());
        route_data.extend(200u64.to_le_bytes());
        route_data.extend(100u16.to_le_bytes());
        route_data.push(0);
        SwapRequest { input_mint: TOKEN, output_mint: WSOL, requested_input: 100,
            min_out: 198, slippage_bps: 100, route_data }
    }

    #[test]
    fn enforce_sealed_policy_and_exact_input_wire() {
        let mints = [TOKEN, WSOL];
        let policy = SealedPolicy { mints: &mints, max_slippage_bps: 100 };
        assert_eq!(route_amount(&request(), &policy).unwrap(), 100);
        let mut invalid = request();
        invalid.requested_input = 99;
        assert!(route_amount(&invalid, &policy).is_err());
        invalid = request();
        invalid.min_out = 197;
        assert!(route_amount(&invalid, &policy).is_err());
        invalid = request();
        invalid.route_data[12] = 255;
        assert!(route_amount(&invalid, &policy).is_err());
        invalid = request();
        invalid.route_data.push(0);
        assert!(route_amount(&invalid, &policy).is_err());
        assert!(route_amount(&request(), &SealedPolicy { mints: &[], max_slippage_bps: 100 }).is_err());
        assert!(route_amount(&request(), &SealedPolicy { mints: &mints, max_slippage_bps: 99 }).is_err());
    }

    #[test]
    fn detect_extra_vault_drain_and_authority_mutation() {
        let key = Pubkey::new_unique();
        let mut lamports = 1_000_000;
        let mut data = vec![0u8; 165];
        data[64..72].copy_from_slice(&100u64.to_le_bytes());
        let account = AccountInfo::new(&key, false, true, &mut lamports, &mut data, &TOKEN, false, 0);
        let snapshot = Snapshot { account: account.clone(), owner: TOKEN, lamports: account.lamports(),
            data: account.try_borrow_data().unwrap().to_vec() };
        assert!(unchanged(&snapshot, None, 0).is_ok());
        account.try_borrow_mut_data().unwrap()[64..72].copy_from_slice(&99u64.to_le_bytes());
        assert!(unchanged(&snapshot, None, 0).is_err());
        assert!(unchanged(&snapshot, Some(99), 0).is_ok());
        account.try_borrow_mut_data().unwrap()[32] = 1;
        assert!(unchanged(&snapshot, Some(99), 0).is_err());
    }
}
