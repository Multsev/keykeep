//! Local encrypted snapshot. The platform retains the random 32-byte device secret.
use crate::legacy::Vault;
use rand::{RngCore, rngs::OsRng};
use ring::{aead, pbkdf2};
use std::{io::Write, num::NonZeroU32, path::Path};
use zeroize::Zeroizing;

const MAGIC: &[u8; 4] = b"KK01";

fn derive(pin: &str, device: &[u8; 32], salt: &[u8]) -> Zeroizing<[u8; 32]> {
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
    derived
}
fn key(raw: &[u8]) -> Result<aead::LessSafeKey, &'static str> {
    Ok(aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, raw).map_err(|_| "Ошибка ключа")?,
    ))
}

// Each unlocked MCP session starts a new salt and key. A per-key counter
// guarantees unique GCM nonces, including across failed persistence attempts.
pub(crate) struct SnapshotKey {
    salt: [u8; 16],
    raw: Zeroizing<[u8; 32]>,
    sequence: u64,
}
impl SnapshotKey {
    fn new(pin: &str, device: &[u8; 32]) -> Result<Self, &'static str> {
        let mut salt = [0; 16];
        OsRng
            .try_fill_bytes(&mut salt)
            .map_err(|_| "Ошибка генератора")?;
        Ok(Self {
            salt,
            raw: derive(pin, device, &salt),
            sequence: 0,
        })
    }
    fn seal(&mut self, vault: &Vault) -> Result<Vec<u8>, &'static str> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("Исчерпан диапазон nonce")?;
        let mut nonce = [0; 12];
        nonce[4..].copy_from_slice(&self.sequence.to_be_bytes());
        encrypt(vault, &self.salt, nonce, &self.raw)
    }
}
pub(crate) fn seal_cached(
    cache: &mut Option<SnapshotKey>,
    vault: &Vault,
    pin: &str,
    device: &[u8; 32],
) -> Result<Vec<u8>, &'static str> {
    if cache.as_ref().is_none_or(|k| k.sequence >= 65536) {
        *cache = Some(SnapshotKey::new(pin, device)?);
    }
    cache.as_mut().unwrap().seal(vault)
}
pub fn seal(vault: &Vault, pin: &str, device: &[u8; 32]) -> Result<Vec<u8>, &'static str> {
    let key = SnapshotKey::new(pin, device)?;
    let mut nonce = [0; 12];
    OsRng
        .try_fill_bytes(&mut nonce)
        .map_err(|_| "Ошибка генератора")?;
    encrypt(vault, &key.salt, nonce, &key.raw)
}
fn encrypt(
    vault: &Vault,
    salt: &[u8; 16],
    nonce: [u8; 12],
    raw: &[u8; 32],
) -> Result<Vec<u8>, &'static str> {
    let mut bytes = Zeroizing::new(serde_json::to_vec(vault).map_err(|_| "Ошибка записи")?);
    let mut header = MAGIC.to_vec();
    header.extend(salt);
    header.extend(nonce);
    key(raw)?
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
    let data = key(derive(pin, device, &bytes[4..20]).as_ref())?
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
