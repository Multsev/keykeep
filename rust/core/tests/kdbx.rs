use keykeep_core::{kdbx, legacy::Vault};
use std::{
    env, fs,
    io::Write,
    process::{Command, Stdio},
};

#[test]
fn preserves_nested_groups_protection_layout_history_and_keyfile() {
    let folders = r#"[{"id":"root","name":"Все записи"},{"id":"f9030929-84e5-4501-9ad2-3ccfdbe01f78","name":"Работа"},{"id":"1bd02532-9f4a-47dc-9504-d40c2742efa8","name":"Сервисы","parentId":"f9030929-84e5-4501-9ad2-3ccfdbe01f78"}]"#;
    let entries = r#"[{"id":"93238dd2-5abe-435e-9b48-d9c718c38163","title":"Тест","username":"synthetic","password":"test-value","updatedAt":"2026-01-02T03:04:05Z","folderId":"1bd02532-9f4a-47dc-9504-d40c2742efa8","customFields":[{"name":"Код","value":"ABC","type":"oneTimePassword"},{"name":"ZZ","value":"s","type":"protected"},{"name":"AA","value":"t","type":"text"}],"history":[{"password":"old","changedAt":"2025-01-01"}]}]"#;
    let vault = Vault::from_android(Some(folders), Some(entries)).unwrap();
    let keyfile = b"synthetic key file";
    for version in [3, 4] {
        let bytes =
            kdbx::export_version(&vault, "synthetic-password", Some(keyfile), version).unwrap();
        assert_eq!(bytes[10..12], [version as u8, 0]);
        assert!(kdbx::import(&bytes, "synthetic-password", None).is_err());
        keepass::Database::open(
            &mut bytes.as_slice(),
            keepass::DatabaseKey::new()
                .with_password("synthetic-password")
                .with_keyfile(&mut keyfile.as_slice())
                .unwrap(),
        )
        .unwrap();
        let loaded = kdbx::import(&bytes, "synthetic-password", Some(keyfile)).unwrap();
        assert!(loaded.folders == vault.folders);
        assert!(loaded.entries == vault.entries);
    }
}

#[test]
fn repeated_exports_preserve_flutter_identity() {
    let folders = r#"[{"id":"root","name":"Все записи"},{"id":"1700000000000000","name":"Test"}]"#;
    let entries = r#"[{"id":"AAECAwQFBgcICQoLDA0ODw==","folderId":"1700000000000000","title":"Imported","username":"demo","password":"fixture","updatedAt":"2026-01-01"},{"id":"1700000000000000","folderId":"1700000000000000","title":"Local","username":"demo","password":"fixture","updatedAt":"2026-01-01"}]"#;
    let original = Vault::from_android(Some(folders), Some(entries)).unwrap();
    let roundtrip = |version| {
        let bytes = kdbx::export_version(&original, "fixture", None, version).unwrap();
        kdbx::import(&bytes, "fixture", None).unwrap()
    };
    let first = roundtrip(3);
    let next = roundtrip(4);
    assert!(first.folders == next.folders);
    assert!(first.entries == next.entries);
    assert!(
        first
            .entries
            .iter()
            .any(|e| e.id == "00010203-0405-0607-0809-0a0b0c0d0e0f")
    );
    assert!(
        first
            .entries
            .iter()
            .all(|e| e.id != first.folders[1].id && e.values.folder_id == first.folders[1].id)
    );
}

#[test]
#[ignore = "requires KeePassXC CLI, configured through KEEPASSXC_CLI"]
fn exchange_with_keepassxc() {
    let cli = env::var("KEEPASSXC_CLI").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("xc.kdbx");
    let exported = dir.path().join("exported.kdbx");
    let run = |args: &[&str], input: &[u8]| {
        let mut child = Command::new(&cli)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(
            out.status.success(),
            "KeePassXC command {}: {}",
            args[0],
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    };
    let db = db.to_str().unwrap();
    run(&["db-create", "-p", db], b"fixture123\nfixture123\n");
    run(
        &["add", "-u", "demo", "-p", db, "Fixture"],
        b"fixture123\nsynthetic-only\n",
    );
    let bytes = fs::read(db).unwrap();
    eprintln!("KeePassXC generated KDBX major {}", bytes[10]);
    let vault = kdbx::import(&bytes, "fixture123", None).unwrap();
    assert_eq!(vault.entries[0].values.password, "synthetic-only");
    for version in [3, 4] {
        fs::write(
            &exported,
            kdbx::export_version(&vault, "exchange123", None, version).unwrap(),
        )
        .unwrap();
        let observed = run(
            &[
                "show",
                "-s",
                "-a",
                "Password",
                exported.to_str().unwrap(),
                "Fixture",
            ],
            b"exchange123\n",
        );
        assert_eq!(observed.trim(), "synthetic-only");
    }
}
