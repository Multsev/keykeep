//! KeePass exchange for the folder, field and revision types supported by KeyKeep.
use crate::legacy::{Entry, Field, FieldType, Folder, Revision, Values, Vault};
use keepass::{
    Database, DatabaseKey,
    db::{self, GroupMut, GroupRef, fields::*},
};
use uuid::Uuid;

const HISTORY: &str = "KeyKeep:PasswordHistory";
const ORDER: &str = "KeyKeep:FieldLayout";
const UPDATED: &str = "KeyKeep:UpdatedAt";
const INVALID: &str = "Не удалось прочитать поля KeyKeep";
const TOO_DEEP: &str = "Превышена глубина дерева папок";

fn key(password: &str, keyfile: Option<&[u8]>) -> Result<DatabaseKey, &'static str> {
    let key = DatabaseKey::new().with_password(password);
    match keyfile {
        Some(mut bytes) => key
            .with_keyfile(&mut bytes)
            .map_err(|_| "Не удалось прочитать ключевой файл"),
        None => Ok(key),
    }
}

pub fn export(
    vault: &Vault,
    password: &str,
    keyfile: Option<&[u8]>,
) -> Result<Vec<u8>, &'static str> {
    export_version(vault, password, keyfile, 4)
}

pub fn export_version(
    vault: &Vault,
    password: &str,
    keyfile: Option<&[u8]>,
    version: u64,
) -> Result<Vec<u8>, &'static str> {
    if password.is_empty() {
        return Err("Укажите пароль базы KeePass");
    }
    let mut db = Database::new();
    db.root_mut().name = "KeyKeep".into();
    write_group(vault, "root", db.root_mut(), 0)?;
    if version == 3 {
        return export_v3(db.root(), password, keyfile);
    }
    if version != 4 {
        return Err("Неизвестная версия KDBX");
    }
    let mut bytes = Vec::new();
    db.save(&mut bytes, key(password, keyfile)?)
        .map_err(|_| "Не удалось записать KDBX 4")?;
    Ok(bytes)
}

fn export_v3(
    root: GroupRef<'_>,
    password: &str,
    keyfile: Option<&[u8]>,
) -> Result<Vec<u8>, &'static str> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use sha2::{Digest, Sha256};
    let composite = match keyfile {
        None => kpdb::CompositeKey::from_password(password),
        Some(file) => {
            let xml = std::str::from_utf8(file)
                .ok()
                .and_then(|s| roxmltree::Document::parse(s).ok());
            let raw = if let Some(root) = xml
                .as_ref()
                .map(|xml| xml.root_element())
                .filter(|r| r.has_tag_name("KeyFile"))
            {
                fn child<'a, 'i>(
                    node: roxmltree::Node<'a, 'i>,
                    name: &str,
                ) -> Option<roxmltree::Node<'a, 'i>> {
                    node.children().find(|n| n.has_tag_name(name))
                }
                let data = child(root, "Key")
                    .and_then(|n| child(n, "Data"))
                    .ok_or("Некорректный ключевой файл")?;
                let value: String = data.text().unwrap_or_default().split_whitespace().collect();
                if child(root, "Meta")
                    .and_then(|n| child(n, "Version"))
                    .and_then(|n| n.text())
                    == Some("2.0")
                {
                    let decoded = hex::decode(value).map_err(|_| "Некорректный ключевой файл")?;
                    let hash = hex::encode_upper(&Sha256::digest(&decoded)[..4]);
                    if !data
                        .attribute("Hash")
                        .is_some_and(|h| h.eq_ignore_ascii_case(&hash))
                    {
                        return Err("Ошибка контрольной суммы ключевого файла");
                    }
                    decoded
                } else {
                    STANDARD
                        .decode(value)
                        .map_err(|_| "Некорректный ключевой файл")?
                }
            } else if file.len() == 32 {
                file.to_vec()
            } else if file.len() == 64 {
                hex::decode(file).unwrap_or_else(|_| Sha256::digest(file).to_vec())
            } else {
                Sha256::digest(file).to_vec()
            };
            let raw = zeroize::Zeroizing::new(raw);
            if raw.len() != 32 {
                return Err("Некорректная длина ключа");
            }
            let key = kpdb::KeyFile::open(&mut raw.as_slice())
                .map_err(|_| "Некорректный ключевой файл")?;
            kpdb::CompositeKey::from_both(password, key)
        }
    };
    let mut db = kpdb::Database::new(&composite);
    db.transform_rounds = kpdb::TransformRounds(1_000_000);
    // KDBX 3 timestamps use whole UTC seconds.
    let now = chrono::DateTime::from_timestamp(chrono::Utc::now().timestamp(), 0).unwrap();
    db.def_username_changed = now;
    db.description_changed = now;
    db.entry_templates_group_changed = now;
    db.master_key_changed = now;
    db.name_changed = now;
    db.recycle_bin_changed = now;
    db.root_group = group_v3(root, now);
    let mut bytes = Vec::new();
    db.save(&mut bytes)
        .map_err(|_| "Не удалось записать KDBX 3")?;
    Ok(bytes)
}

fn group_v3(source: GroupRef<'_>, now: chrono::DateTime<chrono::Utc>) -> kpdb::Group {
    let mut group = kpdb::Group::new(&source.name);
    group.custom_icon_uuid = Some(kpdb::CustomIconUuid(Uuid::nil()));
    group.creation_time = now;
    group.expiry_time = now;
    group.last_accessed = now;
    group.last_modified = now;
    group.location_changed = now;
    group.uuid = kpdb::GroupUuid(source.id().uuid());
    for item in source.entries() {
        let mut entry = kpdb::Entry::new();
        entry.custom_icon_uuid = Some(kpdb::CustomIconUuid(Uuid::nil()));
        entry.creation_time = now;
        entry.expiry_time = now;
        entry.last_accessed = now;
        entry.last_modified = now;
        entry.location_changed = now;
        entry.uuid = kpdb::EntryUuid(item.id().uuid());
        for (name, value) in &item.fields {
            let key = if KNOWN_FIELDS.contains(&name.as_str()) {
                kpdb::StringKey::from_string(name)
            } else {
                kpdb::StringKey::Other(name.clone())
            };
            entry.strings.insert(
                key,
                kpdb::StringValue::new(value.get().as_str(), value.is_protected()),
            );
        }
        group.add_entry(entry);
    }
    for child in source.groups() {
        group.add_group(group_v3(child, now));
    }
    group
}

fn write_group(
    vault: &Vault,
    id: &str,
    mut group: GroupMut<'_>,
    depth: usize,
) -> Result<(), &'static str> {
    if depth > 128 {
        return Err(TOO_DEEP);
    }
    for entry in vault.entries.iter().filter(|e| e.values.folder_id == id) {
        let uuid = Uuid::parse_str(&entry.id).unwrap_or_else(|_| Uuid::new_v4());
        let mut item = group.add_entry_with_id(uuid.into()).map_err(|_| INVALID)?;
        let v = &entry.values;
        for (name, value) in [
            (TITLE, &v.title),
            (USERNAME, &v.username),
            (URL, &v.website),
            (NOTES, &v.note),
        ] {
            item.set_unprotected(name, value.as_str());
        }
        item.set_protected(PASSWORD, v.password.as_str());
        let mut layout = Vec::new();
        for field in &v.custom_fields {
            if item.fields.contains_key(&field.name)
                || matches!(field.name.as_str(), HISTORY | ORDER | UPDATED)
            {
                return Err("Повторяющееся или зарезервированное имя поля KeePass");
            }
            match field.kind {
                FieldType::Text => item.set_unprotected(&field.name, &field.value),
                _ => item.set_protected(&field.name, &field.value),
            }
            layout.push((&field.name, &field.kind));
        }
        if !layout.is_empty() {
            item.set_protected(ORDER, serde_json::to_string(&layout).map_err(|_| INVALID)?);
        }
        if !entry.history.is_empty() {
            item.set_protected(
                HISTORY,
                serde_json::to_string(&entry.history).map_err(|_| INVALID)?,
            );
        }
        item.set_unprotected(UPDATED, &entry.updated_at);
    }
    for folder in vault
        .folders
        .iter()
        .filter(|f| f.id != "root" && f.parent_id == id)
    {
        let uuid = Uuid::parse_str(&folder.id).unwrap_or_else(|_| Uuid::new_v4());
        let mut child = group.add_group_with_id(uuid.into()).map_err(|_| INVALID)?;
        child.name.clone_from(&folder.name);
        write_group(vault, &folder.id, child, depth + 1)?;
    }
    Ok(())
}

pub fn import(
    mut bytes: &[u8],
    password: &str,
    keyfile: Option<&[u8]>,
) -> Result<Vault, &'static str> {
    let db = Database::open(&mut bytes, key(password, keyfile)?)
        .map_err(|_| "Проверьте базу KeePass, пароль и ключевой файл")?;
    let mut vault = Vault::from_android(None, None)?;
    read_group(db.root(), "root", &mut vault, 0)?;
    Ok(vault)
}

fn read_values(e: &db::Entry, parent: &str) -> Result<Values, &'static str> {
    let mut custom_fields = Vec::new();
    let layout: Vec<(String, FieldType)> = e
        .get(ORDER)
        .map(serde_json::from_str)
        .transpose()
        .map_err(|_| INVALID)?
        .unwrap_or_default();
    let mut names: Vec<_> = e
        .fields
        .keys()
        .filter(|k| {
            !KNOWN_FIELDS.contains(&k.as_str()) && !matches!(k.as_str(), ORDER | UPDATED | HISTORY)
        })
        .collect();
    names.sort_by_key(|k| {
        (
            layout
                .iter()
                .position(|(name, _)| name == *k)
                .unwrap_or(usize::MAX),
            k.as_str(),
        )
    });
    for name in names {
        let value = &e.fields[name];
        let kind = match layout.iter().find(|(n, _)| n == name).map(|(_, t)| t) {
            Some(FieldType::OneTimePassword) => FieldType::OneTimePassword,
            None if name.to_ascii_uppercase().contains("OTP") => FieldType::OneTimePassword,
            _ if value.is_protected() => FieldType::Protected,
            _ => FieldType::Text,
        };
        custom_fields.push(Field {
            name: name.clone(),
            value: value.get().clone(),
            kind,
        });
    }
    let field = |k| e.get(k).unwrap_or_default().to_owned();
    Ok(Values {
        title: field(TITLE),
        username: field(USERNAME),
        password: field(PASSWORD),
        website: field(URL),
        note: field(NOTES),
        folder_id: parent.into(),
        custom_fields,
    })
}

fn modified(e: &db::Entry) -> String {
    e.get(UPDATED)
        .map(str::to_owned)
        .or_else(|| e.times.last_modification.map(|t| t.and_utc().to_rfc3339()))
        .unwrap_or_default()
}

fn read_group(
    group: GroupRef<'_>,
    parent: &str,
    vault: &mut Vault,
    depth: usize,
) -> Result<(), &'static str> {
    if depth > 128 {
        return Err(TOO_DEEP);
    }
    for e in group.entries() {
        if e.attachments().next().is_some() {
            return Err("База содержит вложения. Импорт остановлен для сохранности данных.");
        }
        let mut history: Vec<Revision> = e
            .get(HISTORY)
            .map(serde_json::from_str)
            .transpose()
            .map_err(|_| INVALID)?
            .unwrap_or_default();
        if let Some(h) = &e.history {
            for old in h.get_entries() {
                history.push(Revision {
                    changed_at: modified(old),
                    values: Some(
                        serde_json::to_string(&read_values(old, parent)?).map_err(|_| INVALID)?,
                    ),
                    password: None,
                });
            }
        }
        vault.entries.push(Entry {
            id: e.id().uuid().to_string(),
            updated_at: modified(&e),
            values: read_values(&e, parent)?,
            history,
        });
    }
    for child in group.groups() {
        let id = child.id().uuid().to_string();
        vault.folders.push(Folder {
            id: id.clone(),
            name: child.name.clone(),
            parent_id: parent.into(),
        });
        read_group(child, &id, vault, depth + 1)?;
    }
    Ok(())
}
