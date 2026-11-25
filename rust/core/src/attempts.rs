//! Retry delays persist across process restarts and protect both unlock and PIN changes.
use crate::storage;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::ErrorKind,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Default, Serialize, Deserialize)]
struct Counter {
    failures: u32,
    blocked_until: u64,
}

pub struct Attempts(PathBuf);
const ERROR: &str = "Не удалось проверить число попыток входа";
impl Attempts {
    pub fn new(path: PathBuf) -> Self {
        Self(path)
    }
    fn read(&self) -> Result<Counter, &'static str> {
        match fs::read(&self.0) {
            Ok(data) => serde_json::from_slice(&data).map_err(|_| ERROR),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(Counter::default()),
            Err(_) => Err(ERROR),
        }
    }
    fn now() -> Result<u64, &'static str> {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|t| t.as_secs())
            .map_err(|_| ERROR)
    }
    pub fn check(&self) -> Result<(), &'static str> {
        if self.read()?.blocked_until > Self::now()? {
            return Err("Слишком много попыток. Попробуйте позже.");
        }
        Ok(())
    }
    pub fn failed(&self) -> Result<(), &'static str> {
        let mut counter = self.read()?;
        counter.failures = counter.failures.saturating_add(1);
        counter.blocked_until = if counter.failures < 4 {
            0
        } else {
            Self::now()? + (5u64 << (counter.failures - 4).min(6)).min(300)
        };
        storage::persist(&self.0, &serde_json::to_vec(&counter).map_err(|_| ERROR)?)
            .map_err(|_| ERROR)
    }
    pub fn clear(&self) -> Result<(), &'static str> {
        match fs::remove_file(&self.0) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
            Err(_) => Err(ERROR),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fourth_failure_survives_restart_and_success_resets() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("attempts");
        let a = Attempts::new(path.clone());
        for _ in 0..4 {
            a.check().unwrap();
            a.failed().unwrap();
        }
        let b = Attempts::new(path);
        assert!(b.check().is_err());
        b.clear().unwrap();
        b.check().unwrap();
    }
}
