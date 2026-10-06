use super::error::RaydiumError;
use anchor_lang::prelude::*;

pub const Q64: u128 = 1u128 << 64;
pub const MIN_TICK: i32 = -443636;
pub const MAX_TICK: i32 = 443636;

/// Exact factors from raydium-clmm ed1eb41519d5355755f7df52b43fa9610938b60b.
pub fn sqrt_price_at_tick(tick: i32) -> Result<u128> {
    require!(
        (MIN_TICK..=MAX_TICK).contains(&tick),
        RaydiumError::InvalidRange
    );
    let factors = [
        0xfffcb933bd6fb800u128,
        0xfff97272373d4000,
        0xfff2e50f5f657000,
        0xffe5caca7e10f000,
        0xffcb9843d60f7000,
        0xff973b41fa98e800,
        0xff2ea16466c9b000,
        0xfe5dee046a9a3800,
        0xfcbe86c7900bb000,
        0xf987a7253ac65800,
        0xf3392b0822bb6000,
        0xe7159475a2caf000,
        0xd097f3bdfd2f2000,
        0xa9f746462d9f8000,
        0x70d869a156f31c00,
        0x31be135f97ed3200,
        0x9aa508b5b85a500,
        0x5d6af8dedc582c,
        0x2216e584f5fa,
    ];
    let mut ratio = Q64;
    for (index, factor) in factors.iter().enumerate() {
        if tick.unsigned_abs() & (1 << index) != 0 {
            ratio = ratio.checked_mul(*factor).ok_or(RaydiumError::Arithmetic)? >> 64;
        }
    }
    if tick > 0 {
        ratio = u128::MAX / ratio;
    }
    Ok(ratio)
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct Wide([u64; 6]);

impl Wide {
    fn product(left: u128, right: u128) -> Self {
        let left_words = [left as u64, (left >> 64) as u64];
        let right_words = [right as u64, (right >> 64) as u64];
        let mut output = Self::default();
        for (left_index, left_word) in left_words.iter().enumerate() {
            let mut carry = 0u128;
            for (right_index, right_word) in right_words.iter().enumerate() {
                let index = left_index + right_index;
                let total =
                    *left_word as u128 * *right_word as u128 + output.0[index] as u128 + carry;
                output.0[index] = total as u64;
                carry = total >> 64;
            }
            output.0[left_index + 2] = carry as u64;
        }
        output
    }

    fn shift_word(self) -> Self {
        Self([0, self.0[0], self.0[1], self.0[2], self.0[3], self.0[4]])
    }

    fn ge(&self, other: &Self) -> bool {
        for index in (0..6).rev() {
            if self.0[index] != other.0[index] {
                return self.0[index] > other.0[index];
            }
        }
        true
    }

    fn subtract(&mut self, other: &Self) {
        let mut borrow = false;
        for index in 0..6 {
            let (difference, first) = self.0[index].overflowing_sub(other.0[index]);
            let (difference, second) = difference.overflowing_sub(u64::from(borrow));
            self.0[index] = difference;
            borrow = first || second;
        }
    }

    fn divide_u64(self, denominator: Self, round_up: bool) -> Result<u64> {
        require!(denominator != Self::default(), RaydiumError::Arithmetic);
        let mut remainder = Self::default();
        let mut quotient = 0u64;
        for bit in (0..384).rev() {
            let mut carry = (self.0[bit / 64] >> (bit % 64)) & 1;
            for word in &mut remainder.0 {
                let next = *word >> 63;
                *word = (*word << 1) | carry;
                carry = next;
            }
            if remainder.ge(&denominator) {
                remainder.subtract(&denominator);
                require!(bit < 64, RaydiumError::Arithmetic);
                quotient |= 1u64 << bit;
            }
        }
        if round_up && remainder != Self::default() {
            quotient = quotient.checked_add(1).ok_or(RaydiumError::Arithmetic)?;
        }
        Ok(quotient)
    }
}

/// DEC-193: protocol floor rounding for withdrawals/reports; ceil for deposits.
pub fn amounts(
    liquidity: u128,
    sqrt: u128,
    lower: u128,
    upper: u128,
    round_up: bool,
) -> Result<[u64; 2]> {
    require!(
        lower > 0 && lower < upper && sqrt > 0,
        RaydiumError::InvalidRange
    );
    let price = sqrt.clamp(lower, upper);
    let amount_0 = Wide::product(liquidity, upper - price)
        .shift_word()
        .divide_u64(Wide::product(upper, price), round_up)?;
    let amount_1 =
        Wide::product(liquidity, price - lower).divide_u64(Wide::product(Q64, 1), round_up)?;
    Ok([amount_0, amount_1])
}

pub fn accrued_fee(
    liquidity: u128,
    growth_inside: u128,
    checkpoint: u128,
    owed: u64,
) -> Result<u64> {
    let additional = Wide::product(liquidity, growth_inside.wrapping_sub(checkpoint))
        .divide_u64(Wide::product(Q64, 1), false)?;
    owed.checked_add(additional)
        .ok_or_else(|| error!(RaydiumError::Arithmetic))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn differential_against_pinned_raydium_sdk() {
        let vectors = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/raydium/math-vectors.csv"
        ));
        let mut count = 0;
        for line in vectors.lines().filter(|line| !line.starts_with('#')) {
            let fields: Vec<&str> = line.split(',').collect();
            let lower_tick = fields[0].parse().unwrap();
            let upper_tick = fields[1].parse().unwrap();
            let lower = fields[2].parse().unwrap();
            let upper = fields[3].parse().unwrap();
            assert_eq!(sqrt_price_at_tick(lower_tick).unwrap(), lower);
            assert_eq!(sqrt_price_at_tick(upper_tick).unwrap(), upper);
            let result = amounts(
                fields[5].parse().unwrap(),
                fields[4].parse().unwrap(),
                lower,
                upper,
                fields[6] == "1",
            )
            .unwrap();
            assert_eq!(
                result,
                [
                    fields[7].parse::<u64>().unwrap(),
                    fields[8].parse::<u64>().unwrap()
                ],
                "{line}"
            );
            count += 1;
        }
        assert!(count >= 500);
    }

    #[test]
    fn pinned_tick_extremes_and_negative_array_boundaries() {
        assert_eq!(sqrt_price_at_tick(MIN_TICK).unwrap(), 4295048016);
        assert_eq!(
            sqrt_price_at_tick(MAX_TICK).unwrap(),
            79226673521066979257578248091
        );
        assert_eq!(sqrt_price_at_tick(0).unwrap(), Q64);
        assert!(sqrt_price_at_tick(MAX_TICK + 1).is_err());
    }

    #[test]
    fn protocol_rounding_and_full_width_intermediates() {
        assert_eq!(
            amounts(100, Q64, Q64 / 2, Q64 * 2, false).unwrap(),
            [50, 50]
        );
        assert_eq!(amounts(1, Q64, Q64 / 2, Q64 * 2, true).unwrap(), [1, 1]);
        assert_eq!(amounts(1, Q64, Q64 / 2, Q64 * 2, false).unwrap(), [0, 0]);
        assert_eq!(
            amounts(100, Q64 / 4, Q64 / 2, Q64 * 2, false).unwrap(),
            [150, 0]
        );
        assert_eq!(
            amounts(100, Q64 * 4, Q64 / 2, Q64 * 2, false).unwrap(),
            [0, 150]
        );
        assert!(amounts(u128::MAX, Q64, Q64 / 2, Q64 * 2, false).is_err());
        assert_eq!(accrued_fee(2, 0, u128::MAX - Q64 + 1, 7).unwrap(), 9);
    }
}
