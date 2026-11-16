//! What the tokens of a session would cost at Claude's prices, shown in the status line next to the tokens.
//!
//! Blablador itself is free for its users, so the number is a reference, not a bill: the priciest rate Anthropic
//! publishes for a standard (non-batch, non-fast) Claude model. From
//! https://platform.claude.com/docs/en/about-claude/pricing on 2026-11-16: Claude Fable 5, Fable 5.1, Mythos 5 and
//! Mythos 5.1 cost $10 per million input tokens and $50 per million output tokens; Fable 5.2 is $8/$40, and Fable
//! 5.2's fast mode $16/$80. The newest priciest standard rate is the one below; edit the constant to compare
//! against another model, and the label in the status line follows.

/// A price per million tokens, and the name shown to the user.
pub struct Reference {
    pub name: &'static str,
    pub input: f64,
    pub output: f64,
}

pub const REFERENCE: Reference = Reference { name: "Claude Fable 5", input: 10.0, output: 50.0 };

/// What `input` + `output` tokens cost in US dollars at [`REFERENCE`]'s rates.
pub fn usd(input: u64, output: u64) -> f64 {
    (input as f64 * REFERENCE.input + output as f64 * REFERENCE.output) / 1_000_000.0
}

/// Dollars with a precision that still shows something when the amount is a fraction of a cent.
pub fn money(usd: f64) -> String {
    if usd >= 100.0 {
        format!("${usd:.0}")
    } else if usd >= 1.0 {
        format!("${usd:.2}")
    } else if usd >= 0.01 {
        format!("${usd:.3}")
    } else {
        format!("${usd:.4}")
    }
}

/// "≈$0.42 at Claude Fable 5": the cost of the session so far.
pub fn line(input: u64, output: u64) -> String {
    format!("≈{} at {}", money(usd(input, output)), REFERENCE.name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_per_million_tokens() {
        assert_eq!(usd(1_000_000, 0), REFERENCE.input);
        assert_eq!(usd(0, 1_000_000), REFERENCE.output);
        assert_eq!(usd(0, 0), 0.0);
        assert!((usd(150_000, 20_000) - 2.5).abs() < 1e-9);
    }

    #[test]
    fn money_keeps_small_amounts_visible() {
        assert_eq!(money(0.0), "$0.0000");
        assert_eq!(money(0.00042), "$0.0004");
        assert_eq!(money(0.0421), "$0.042");
        assert_eq!(money(1.2345), "$1.23");
        assert_eq!(money(1234.6), "$1235");
    }

    #[test]
    fn the_line_names_the_model_it_compares_with() {
        let l = line(1_000_000, 1_000_000);
        assert!(l.starts_with("≈$60"), "{l}");
        assert!(l.ends_with(REFERENCE.name), "{l}");
    }
}
