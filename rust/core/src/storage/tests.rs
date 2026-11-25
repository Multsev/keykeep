use super::*;
use crate::session::Session;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::json;
use std::{
    fs,
    io::{BufRead, BufReader},
    os::unix::process::ExitStatusExt,
    path::PathBuf,
    process::{Command, Stdio},
};

const PIN: &str = "test-only";
const DEVICE: [u8; 32] = [31; 32];
const CHILD_PATH: &str = "KEYKEEP_TEST_CRASH_VAULT";
const CHILD_STAGE: &str = "KEYKEEP_TEST_CRASH_STAGE";

fn child_write(path: PathBuf) {
    let mut s = Session::new(path, DEVICE).unwrap();
    s.call(json!({"op":"unlock","pin":PIN})).unwrap();
    if std::env::var(CHILD_STAGE).as_deref() == Ok("during") {
        // The kernel terminates only this child on its second write after a short first write.
        let limit = libc::rlimit {
            rlim_cur: 1024,
            rlim_max: 1024,
        };
        unsafe {
            libc::signal(libc::SIGXFSZ, libc::SIG_DFL);
            assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &limit), 0);
        }
    }
    s.call(json!({"op":"save","id":"","time":"2026-01-01","values":{
        "title":"new","username":"demo","password":"fixture-secret","note":"x".repeat(65536)
    }}))
    .unwrap();
    println!("COMMITTED");
    std::io::stdout().flush().unwrap();
    std::thread::park_timeout(std::time::Duration::from_secs(10));
}

#[test]
fn interrupted_save_preserves_committed_data_and_releases_session_lock() {
    if let Some(path) = std::env::var_os(CHILD_PATH) {
        child_write(path.into());
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("vault.kk");
    let mut s = Session::new(file.clone(), DEVICE).unwrap();
    s.call(json!({"op":"create","pin":PIN})).unwrap();
    s.call(json!({"op":"save","id":"","time":"2025-01-01","values":{"title":"old","username":"demo","password":"fixture-only"}})).unwrap();
    let previous = fs::read(&file).unwrap();
    let imported = Vault::from_android(None, None).unwrap();
    let data = crate::kdbx::export(&imported, "exchange-test", None).unwrap();
    s.call(json!({"op":"importKdbx","password":"exchange-test","data":STANDARD.encode(data),"confirmed":true})).unwrap();
    drop(s);
    let snapshot = file.with_extension("before-import.kk");
    assert_eq!(fs::read(&snapshot).unwrap(), previous);
    assert_eq!(
        open(&previous, PIN, &DEVICE).unwrap().entries[0]
            .values
            .title,
        "old"
    );
    let before = fs::read(&file).unwrap();
    let spawn = |stage: &str| {
        Command::new(std::env::current_exe().unwrap())
        .args(["--exact","storage::tests::interrupted_save_preserves_committed_data_and_releases_session_lock","--nocapture"])
        .env(CHILD_PATH,&file).env(CHILD_STAGE,stage).stdout(Stdio::piped()).spawn().unwrap()
    };
    let status = spawn("during").wait().unwrap();
    assert_eq!(status.signal(), Some(libc::SIGXFSZ));
    assert_eq!(fs::read(&file).unwrap(), before);
    assert!(open(&before, PIN, &DEVICE).unwrap().entries.is_empty());
    let mut child = spawn("after");
    let output = BufReader::new(child.stdout.take().unwrap());
    assert!(
        output
            .lines()
            .map_while(std::result::Result::ok)
            .any(|line| line.contains("COMMITTED"))
    );
    assert!(Session::new(file.clone(), DEVICE).is_err());
    child.kill().unwrap();
    assert_eq!(child.wait().unwrap().signal(), Some(libc::SIGKILL));
    let mut reopened = Session::new(file.clone(), DEVICE).unwrap();
    reopened.call(json!({"op":"unlock","pin":PIN})).unwrap();
    let rows = reopened
        .call(json!({"op":"list","folder":"root","query":""}))
        .unwrap();
    assert_eq!(rows["entries"][0]["title"], "new");
    assert_eq!(fs::read(snapshot).unwrap(), previous);
}

#[test]
fn erasure_resumes_after_restart_and_preserves_unrelated_files() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault.kk");
    let export = dir.path().join("export.kdbx");
    fs::write(&export, b"external copy").unwrap();
    let mut s = Session::new(path.clone(), DEVICE).unwrap();
    s.call(json!({"op":"create","pin":PIN})).unwrap();
    for ext in ["before-import.kk", "before-restore.kk"] {
        fs::copy(&path, path.with_extension(ext)).unwrap();
    }
    for (pin, confirmed) in [(PIN, false), ("incorrect", true)] {
        assert!(
            s.call(json!({"op":"beginErase","currentPin":pin,"confirmed":confirmed}))
                .is_err()
        );
        assert!(path.exists());
        assert!(!path.with_extension("erasing").exists());
    }
    s.call(json!({"op":"beginErase","currentPin":PIN,"confirmed":true}))
        .unwrap();
    assert!(s.active_pin().is_none());
    drop(s);
    let mut s = Session::new(path.clone(), [0; 32]).unwrap();
    assert!(s.erasing());
    assert!(s.call(json!({"op":"unlock","pin":PIN})).is_err());
    s.finish_erasure([9; 32]).unwrap();
    for ext in [
        "kk",
        "attempts",
        "before-import.kk",
        "before-restore.kk",
        "erasing",
    ] {
        assert!(!path.with_extension(ext).exists());
    }
    assert_eq!(fs::read(export).unwrap(), b"external copy");
    assert!(s.finish_erasure([0; 32]).is_err());
    s.call(json!({"op":"create","pin":PIN})).unwrap();
    let data = fs::read(path).unwrap();
    assert!(open(&data, PIN, &DEVICE).is_err());
    assert!(open(&data, PIN, &[9; 32]).is_ok());
}

#[test]
fn session_snapshot_nonce_and_rotation() {
    let vault = Vault::from_android(None, None).unwrap();
    let mut key = None;
    let first = seal_cached(&mut key, &vault, PIN, &DEVICE).unwrap();
    let next = seal_cached(&mut key, &vault, PIN, &DEVICE).unwrap();
    assert_eq!(&first[4..20], &next[4..20]);
    assert_ne!(&first[20..32], &next[20..32]);
    key.as_mut().unwrap().sequence = 65536;
    let rotated = seal_cached(&mut key, &vault, PIN, &DEVICE).unwrap();
    assert_ne!(&next[4..20], &rotated[4..20]);
    assert!(open(&rotated, PIN, &DEVICE).is_ok());
}
