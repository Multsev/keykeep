use keykeep_core::{credentials::*, legacy::Vault, storage::*};

#[test]
fn totp_vector() {
    assert_eq!(
        totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59).as_deref(),
        Some("287082")
    );
    assert!(totp("!", 59).is_none());
}

#[test]
fn generator_respects_groups() {
    for symbols in [true, false] {
        let pw = generate_password(18, symbols).unwrap();
        assert_eq!(pw.len(), 18);
        assert!(pw.bytes().any(|v| v.is_ascii_alphabetic()));
        assert!(pw.bytes().any(|v| v.is_ascii_digit()));
        assert_eq!(pw.bytes().any(|v| !v.is_ascii_alphanumeric()), symbols);
    }
}

#[test]
fn encrypted_legacy_roundtrip() {
    let source = r#"[{"id":"sample","title":"Пример","username":"test","password":"synthetic-only","updatedAt":"2026-01-01","history":[{"password":"old","changedAt":"2025-01-01"}]}]"#;
    let v = Vault::from_android(None, Some(source)).unwrap();
    let device = [42; 32];
    let encrypted = seal(&v, "test-pin", &device).unwrap();
    assert!(!encrypted.windows(14).any(|w| w == b"synthetic-only"));
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    persist(&path, &encrypted).unwrap();
    assert!(open(&encrypted, "wrong", &device).is_err());
    let mut broken = encrypted.clone();
    *broken.last_mut().unwrap() ^= 1;
    assert!(open(&broken, "test-pin", &device).is_err());
    let saved = open(&std::fs::read(path).unwrap(), "test-pin", &device).unwrap();
    assert!(v.entries == saved.entries);
}
