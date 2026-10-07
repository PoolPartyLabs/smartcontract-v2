use super::{custody, guards::CoreError};
use crate::instructions::{core::binding::word, report::codec::signed_word};
use anchor_lang::prelude::*;

/// DEC-194, DEC-198: changed issuer state is not authorized by a caller's witness.
pub fn witness(mint: &AccountInfo, custody_account: &AccountInfo) -> Result<[[u8; 32]; 7]> {
    require!([custody::TSLAX, custody::NVDAX].contains(mint.key), CoreError::InvalidConfiguration);
    require_keys_eq!(*mint.owner, custody::TOKEN_2022, CoreError::InvalidCustody);
    require!(!mint.is_writable, CoreError::InvalidCustody);
    let data = mint.try_borrow_data()?;
    require!(data.len() >= 166 && data[44] == 8 && data[45] == 1 && data[165] == 1, CoreError::InvalidCustody);
    let token = custody_account.try_borrow_data()?;
    require!(token.len() >= 165 && token[108] == 1 && token[..32] == mint.key.to_bytes(), CoreError::InvalidCustody);
    require_keys_eq!(*custody_account.owner, custody::TOKEN_2022, CoreError::InvalidCustody);
    let mut offset = 166;
    let mut seen = 0u16;
    let allowed = [4u16, 6, 12, 14, 18, 19, 25, 26];
    let mut multiplier = 0u64;
    let mut next_multiplier = 0u64;
    let mut effective_at = 0i64;
    while offset + 4 <= data.len() {
        let kind = u16::from_le_bytes(data[offset..offset + 2].try_into().unwrap());
        if kind == 0 { break; }
        let length = u16::from_le_bytes(data[offset + 2..offset + 4].try_into().unwrap()) as usize;
        let index = allowed.iter().position(|entry| *entry == kind).ok_or(CoreError::InvalidCustody)?;
        require!(seen & (1 << index) == 0, CoreError::InvalidCustody);
        seen |= 1 << index;
        let value = data.get(offset + 4..offset + 4 + length).ok_or(CoreError::InvalidCustody)?;
        match kind {
            4 => require!(length == 65, CoreError::InvalidCustody),
            6 => require!(value == [1], CoreError::InvalidCustody),
            12 => require!(length == 32, CoreError::InvalidCustody),
            14 => require!(length == 64 && value[32..64] == [0; 32], CoreError::InvalidCustody),
            18 => require!(length == 64, CoreError::InvalidCustody),
            19 => require!(length >= 64, CoreError::InvalidCustody),
            25 => {
                require!(length == 56, CoreError::InvalidCustody);
                multiplier = u64::from_le_bytes(value[32..40].try_into().unwrap());
                effective_at = i64::from_le_bytes(value[40..48].try_into().unwrap());
                next_multiplier = u64::from_le_bytes(value[48..56].try_into().unwrap());
                crate::instructions::raydium::validation::stock_multiplier(*mint.key, multiplier, next_multiplier, effective_at)?;
            }
            26 => require!(length == 33 && value[32] == 0, CoreError::InvalidCustody),
            _ => return err!(CoreError::InvalidCustody),
        }
        offset += 4 + length;
    }
    require!(seen == 255 && data[offset..].iter().all(|value| *value == 0), CoreError::InvalidCustody);
    Ok([mint.key.to_bytes(), word(u128::from(multiplier)), word(u128::from(next_multiplier)), signed_word(effective_at), word(0), word(0), word(0)])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn witness_rejects_missing_changed_paused_frozen_or_hooked_state() {
        let mut data = vec![0; 166];
        data[44] = 8; data[45] = 1; data[165] = 1;
        for (kind, length) in [(4u16,65usize),(6,1),(12,32),(14,64),(18,64),(19,64),(25,56),(26,33)] {
            data.extend(kind.to_le_bytes()); data.extend((length as u16).to_le_bytes());
            let mut value = vec![0; length];
            if kind == 6 { value[0] = 1; }
            if kind == 25 { value[32..40].copy_from_slice(&1f64.to_le_bytes()); value[48..56].copy_from_slice(&1f64.to_le_bytes()); }
            data.extend(value);
        }
        let mut token = vec![0;165]; token[..32].copy_from_slice(custody::TSLAX.as_ref()); token[108] = 1;
        for variant in 0..6 {
            let mut mint_data = data.clone(); let mut token_data = token.clone();
            match variant { 1 => token_data[108] = 2, 2 => *mint_data.last_mut().unwrap() = 1,
                3 => mint_data[166 + 69 + 5 + 36 + 4 + 32] = 1,
                4 => mint_data[166 + 69 + 5 + 36 + 68 + 68 + 68 + 4 + 32] ^= 1,
                5 => mint_data.truncate(166), _ => {} }
            let mut mint_lamports = 1; let mut token_lamports = 1; let token_key = Pubkey::new_unique();
            let mint = AccountInfo::new(&custody::TSLAX,false,false,&mut mint_lamports,&mut mint_data,&custody::TOKEN_2022,false,0);
            let account = AccountInfo::new(&token_key,false,false,&mut token_lamports,&mut token_data,&custody::TOKEN_2022,false,0);
            assert_eq!(witness(&mint,&account).is_ok(), variant == 0);
        }
    }
}
