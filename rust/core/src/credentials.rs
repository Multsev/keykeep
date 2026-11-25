use base64::{Engine, engine::general_purpose::URL_SAFE};
use rand::{Rng, rngs::OsRng, seq::SliceRandom};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

/// Verify the exact Dart verifier before importing an existing installation.
pub fn legacy_pin_matches(pin: &str, salt: &str, encoded: &str) -> bool {
    let Ok(expected) = URL_SAFE.decode(encoded) else {
        return false;
    };
    let input = Zeroizing::new(format!("{salt}:{pin}"));
    let mut hash = Sha256::digest(input.as_bytes());
    for _ in 1..120_000 {
        hash = Sha256::digest(hash);
    }
    bool::from(hash.as_slice().ct_eq(&expected))
}

pub fn generate_password(length: usize, symbols: bool) -> Option<Zeroizing<String>> {
    if !(8..=4096).contains(&length) {
        return None;
    }
    let groups: &[&[u8]] = &[
        b"abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ",
        b"23456789",
        b"!@#%&*+-_=",
    ];
    let groups = &groups[..if symbols { 3 } else { 2 }];
    let alphabet = groups.concat();
    let mut rng = OsRng;
    let mut result = Zeroizing::new(Vec::with_capacity(length));
    for group in groups {
        result.push(group[rng.gen_range(0..group.len())]);
    }
    while result.len() < length {
        result.push(alphabet[rng.gen_range(0..alphabet.len())]);
    }
    result.shuffle(&mut rng);
    Some(Zeroizing::new(
        String::from_utf8(result.to_vec()).expect("ASCII alphabet"),
    ))
}

/// RFC 6238 with the same six digits and 30-second period as the Android version.
pub fn totp(secret: &str, seconds: u64) -> Option<String> {
    let mut key = Zeroizing::new(Vec::new());
    let mut buffer = 0u16;
    let mut bits = 0;
    for c in secret
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-' && *c != '=')
    {
        let n = match c.to_ascii_uppercase() {
            c @ 'A'..='Z' => c as u16 - 'A' as u16,
            c @ '2'..='7' => c as u16 - '2' as u16 + 26,
            _ => return None,
        };
        buffer = (buffer << 5) | n;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            key.push((buffer >> bits) as u8);
        }
    }
    if key.is_empty() {
        return None;
    }
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, &key);
    let tag = ring::hmac::sign(&key, &(seconds / 30).to_be_bytes());
    let bytes = tag.as_ref();
    let offset = (bytes[19] & 15) as usize;
    let number = u32::from_be_bytes(bytes[offset..offset + 4].try_into().ok()?) & 0x7fff_ffff;
    Some(format!("{:06}", number % 1_000_000))
}
