//! Local encrypted snapshot. The platform retains the random 32-byte device secret.
use crate::legacy::Vault;
use rand::{RngCore, rngs::OsRng};
use ring::{aead, pbkdf2};
use std::{io::Write, num::NonZeroU32, path::Path};
use zeroize::Zeroizing;

const MAGIC: &[u8; 4] = b"KK01";

fn key(pin: &str, device: &[u8; 32], salt: &[u8]) -> Result<aead::LessSafeKey, &'static str> {
    let mut input = Zeroizing::new(device.to_vec());
    input.extend_from_slice(pin.as_bytes());
    let mut derived = Zeroizing::new([0; 32]);
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        NonZeroU32::new(600_000).unwrap(),
        salt,
        &input,
        derived.as_mut(),
    );
    Ok(aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, derived.as_ref()).map_err(|_| "Ошибка ключа")?,
    ))
}

pub fn seal(vault: &Vault, pin: &str, device: &[u8; 32]) -> Result<Vec<u8>, &'static str> {
    let mut salt = [0; 16];
    let mut nonce = [0; 12];
    OsRng
        .try_fill_bytes(&mut salt)
        .and_then(|_| OsRng.try_fill_bytes(&mut nonce))
        .map_err(|_| "Ошибка генератора")?;
    let mut bytes = Zeroizing::new(serde_json::to_vec(vault).map_err(|_| "Ошибка записи")?);
    let mut header = MAGIC.to_vec();
    header.extend(salt);
    header.extend(nonce);
    key(pin, device, &salt)?
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(&header),
            &mut *bytes,
        )
        .map_err(|_| "Ошибка шифрования")?;
    header.extend_from_slice(&bytes);
    Ok(header)
}

pub fn open(bytes: &[u8], pin: &str, device: &[u8; 32]) -> Result<Vault, &'static str> {
    const ERROR: &str = "Не удалось открыть хранилище";
    if bytes.len() < 48 || !bytes.starts_with(MAGIC) {
        return Err(ERROR);
    }
    let mut body = Zeroizing::new(bytes[32..].to_vec());
    let data = key(pin, device, &bytes[4..20])?
        .open_in_place(
            aead::Nonce::try_assume_unique_for_key(&bytes[20..32]).map_err(|_| ERROR)?,
            aead::Aad::from(&bytes[..32]),
            &mut body,
        )
        .map_err(|_| ERROR)?;
    serde_json::from_slice(data).map_err(|_| ERROR)
}

/// Callers serialize writes and only publish their in-memory revision after success.
pub fn persist(path: &Path, ciphertext: &[u8]) -> std::io::Result<()> {
    persist_file(path, ciphertext, true)
}

pub fn persist_new(path: &Path, ciphertext: &[u8]) -> std::io::Result<()> {
    persist_file(path, ciphertext, false)
}

fn persist_file(path: &Path, ciphertext: &[u8], replace: bool) -> std::io::Result<()> {
    let dir = path.parent().ok_or(std::io::ErrorKind::InvalidInput)?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    tmp.write_all(ciphertext)?;
    tmp.as_file().sync_all()?;
    if replace {
        tmp.persist(path)?;
    } else {
        tmp.persist_noclobber(path)?;
    }
    std::fs::File::open(dir)?.sync_all()
}

#[cfg(test)]
mod tests;
