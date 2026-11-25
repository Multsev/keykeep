//! Three-way reconciliation of the portable fields. Only digests of the last
//! common version are retained alongside the encrypted local sync settings.
use super::*;
use crate::{kdbx::exchange_id, legacy::Vault};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) type Baseline = BTreeMap<String, String>;
fn folder(id: &str) -> String {
    if id == "root" {
        id.into()
    } else {
        exchange_id("folder", id).to_string()
    }
}
pub(crate) fn baseline(v: &Vault) -> Result<Baseline> {
    let mut map = Baseline::new();
    let digest = |value: Value| format!("{:x}", Sha256::digest(value.to_string()));
    for f in v.folders.iter().filter(|f| f.id != "root") {
        map.insert(
            format!("f:{}", folder(&f.id)),
            digest(json!([f.name, folder(&f.parent_id)])),
        );
    }
    for e in &v.entries {
        let mut value = json!(&e.values);
        value["folderId"] = json!(folder(&e.values.folder_id));
        map.insert(format!("e:{}", exchange_id("entry", &e.id)), digest(value));
    }
    Ok(map)
}

impl Client {
    pub(crate) fn automatic(
        self,
        local: Vault,
        local_digest: String,
        choices: Value,
    ) -> Result<Outcome> {
        let password = Zeroizing::new(self.account.auto_password.clone());
        let remote = self.info(&self.path())?;
        let hash = remote["sha256"].as_str();
        let synced = self.account.synced.as_ref();
        let same_remote = synced.is_some_and(|s| Some(s.remote.as_str()) == hash);
        let same_local = synced.is_some_and(|s| s.local == local_digest);
        if same_local && same_remote {
            return Ok(Outcome::Info(json!({"unchanged":true})));
        }
        if remote.is_null() && synced.is_some() {
            return Err("Облачный файл удалён. Проверьте версии в настройках.");
        }
        let mut next = local.clone();
        let mut pull_only = false;
        if !same_remote && hash.is_some() {
            let bytes = self.download(&self.path())?;
            if Some(format!("{:x}", Sha256::digest(&bytes)).as_str()) != hash {
                return Err(STALE);
            }
            let cloud = crate::kdbx::import(&bytes, &password, None)?;
            if same_local
                || (local.entries.is_empty() && local.folders.len() == 1 && synced.is_none())
            {
                next = cloud;
                pull_only = true;
            } else {
                let l = baseline(&local)?;
                let r = baseline(&cloud)?;
                let base = &self.account.auto_base;
                let keys: BTreeSet<_> = l.keys().chain(r.keys()).chain(base.keys()).collect();
                let mut use_remote = BTreeSet::new();
                let mut conflicts = Vec::new();
                for k in keys {
                    let left = l.get(k);
                    let right = r.get(k);
                    if left == right {
                        continue;
                    }
                    if left == base.get(k) {
                        use_remote.insert(k.clone());
                        continue;
                    }
                    if right == base.get(k) {
                        continue;
                    }
                    let chosen = if choices["remote"] == remote["sha256"]
                        && choices["local"] == local_digest
                    {
                        choices["versions"][k].as_str()
                    } else {
                        None
                    };
                    match chosen {
                        Some("remote") => {
                            use_remote.insert(k.clone());
                        }
                        Some("local") => {}
                        _ => {
                            let label = local
                                .entries
                                .iter()
                                .chain(&cloud.entries)
                                .find(|e| format!("e:{}", exchange_id("entry", &e.id)) == *k)
                                .map(|e| e.values.title.as_str())
                                .or_else(|| {
                                    local
                                        .folders
                                        .iter()
                                        .chain(&cloud.folders)
                                        .find(|f| format!("f:{}", folder(&f.id)) == *k)
                                        .map(|f| f.name.as_str())
                                })
                                .unwrap_or(k);
                            conflicts.push(json!({"id":k,"name":label,"localExists":left.is_some(),"remoteExists":right.is_some()}));
                        }
                    }
                }
                if !conflicts.is_empty() {
                    return Ok(Outcome::Info(
                        json!({"conflicts":conflicts,"local":local_digest,"remote":remote["sha256"]}),
                    ));
                }
                let local_folder = |id: &str| {
                    local
                        .folders
                        .iter()
                        .find(|f| folder(&f.id) == folder(id))
                        .map(|f| f.id.clone())
                        .unwrap_or_else(|| id.into())
                };
                next.folders
                    .retain(|f| !use_remote.contains(&format!("f:{}", folder(&f.id))));
                for f in cloud
                    .folders
                    .iter()
                    .filter(|f| use_remote.contains(&format!("f:{}", folder(&f.id))))
                {
                    let mut f = f.clone();
                    f.id = local_folder(&f.id);
                    f.parent_id = local_folder(&f.parent_id);
                    next.folders.push(f);
                }
                next.entries.retain(|e| {
                    !use_remote.contains(&format!("e:{}", exchange_id("entry", &e.id)))
                });
                for e in &cloud.entries {
                    let id = exchange_id("entry", &e.id);
                    let other = local
                        .entries
                        .iter()
                        .find(|x| exchange_id("entry", &x.id) == id);
                    let mut remote_entry = e.clone();
                    remote_entry.values.folder_id = local_folder(&e.values.folder_id);
                    if use_remote.contains(&format!("e:{id}")) {
                        if let Some(old) = other {
                            remote_entry.id.clone_from(&old.id);
                            archive(&mut remote_entry, old)?;
                        }
                        next.entries.push(remote_entry);
                    } else if let Some(keep) = next
                        .entries
                        .iter_mut()
                        .find(|x| exchange_id("entry", &x.id) == id)
                    {
                        archive(keep, &remote_entry)?;
                    }
                }
                next.validate()?;
            }
        }
        let remote_hash = if pull_only {
            hash.ok_or(STALE)?.into()
        } else {
            let bytes = crate::kdbx::export(&next, &password, None)?;
            let digest = format!("{:x}", Sha256::digest(&bytes));
            self.upload(bytes, remote)?;
            digest
        };
        Ok(Outcome::Automatic(Box::new(next), remote_hash))
    }
}
fn archive(keep: &mut crate::legacy::Entry, other: &crate::legacy::Entry) -> Result<()> {
    for revision in &other.history {
        if !keep.history.contains(revision) {
            keep.history.push(revision.clone());
        }
    }
    if keep.values != other.values {
        let old = crate::legacy::Revision {
            changed_at: other.updated_at.clone(),
            values: Some(serde_json::to_string(&other.values).map_err(|_| SERVICE)?),
            password: None,
        };
        if !keep.history.contains(&old) {
            keep.history.push(old);
        }
    }
    Ok(())
}
