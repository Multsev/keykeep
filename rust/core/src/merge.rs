//! Combine two unlocked vaults without discarding older credential values.
use crate::kdbx::exchange_id;
use crate::legacy::{Entry, Revision, Values, Vault};
use std::collections::HashMap;

fn timestamp(value: &str) -> Option<chrono::NaiveDateTime> {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|v| v.naive_utc())
        .ok()
        .or_else(|| value.parse().ok())
}

fn combine(local: &Entry, remote: &Entry) -> Result<Entry, &'static str> {
    let (winner, other) = if timestamp(&remote.updated_at) > timestamp(&local.updated_at) {
        (remote, local)
    } else {
        (local, remote)
    };
    let mut entry = winner.clone();
    for revision in &other.history {
        if !entry.history.contains(revision) {
            entry.history.push(revision.clone());
        }
    }
    if winner.values != other.values {
        let revision = Revision {
            changed_at: other.updated_at.clone(),
            values: Some(serde_json::to_string(&other.values).map_err(|_| "Ошибка истории")?),
            password: None,
        };
        if !entry.history.contains(&revision) {
            entry.history.push(revision);
        }
    }
    entry
        .history
        .sort_by_cached_key(|r| timestamp(&r.changed_at));
    Ok(entry)
}

pub(crate) fn merge(local: &Vault, mut remote: Vault) -> Result<Vault, &'static str> {
    let mut next = local.clone();
    let folder_ids: HashMap<_, _> = local
        .folders
        .iter()
        .filter(|f| f.id != "root")
        .map(|f| (exchange_id("folder", &f.id).to_string(), f.id.as_str()))
        .collect();
    let local_folder = |id: &str| folder_ids.get(id).copied().unwrap_or(id).to_owned();
    for folder in &mut remote.folders {
        if folder.id == "root" || folder_ids.contains_key(&folder.id) {
            continue;
        }
        folder.parent_id = local_folder(&folder.parent_id);
        next.folders.push(folder.clone());
    }
    let ids: HashMap<_, _> = local
        .entries
        .iter()
        .enumerate()
        .map(|(index, e)| (exchange_id("entry", &e.id).to_string(), index))
        .collect();
    for mut entry in remote.entries {
        entry.values.folder_id = local_folder(&entry.values.folder_id);
        for revision in &mut entry.history {
            if let Some(raw) = &revision.values
                && let Ok(mut old) = serde_json::from_str::<Values>(raw)
            {
                let folder = local_folder(&old.folder_id);
                if old.folder_id != folder {
                    old.folder_id = folder;
                    revision.values =
                        Some(serde_json::to_string(&old).map_err(|_| "Ошибка истории")?);
                }
            }
        }
        if let Some(&index) = ids.get(&entry.id) {
            entry.id.clone_from(&local.entries[index].id);
            next.entries[index] = combine(&local.entries[index], &entry)?;
        } else {
            next.entries.push(entry);
        }
    }
    next.validate()?;
    Ok(next)
}
