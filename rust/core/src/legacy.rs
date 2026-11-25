use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

fn root() -> String {
    "root".into()
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub id: String,
    pub name: String,
    #[serde(default = "root")]
    pub parent_id: String,
}

#[derive(Deserialize, Serialize, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub enum FieldType {
    #[default]
    Text,
    Protected,
    OneTimePassword,
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
pub struct Field {
    pub name: String,
    pub value: String,
    #[serde(default, rename = "type")]
    pub kind: FieldType,
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Values {
    pub title: String,
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub website: String,
    #[serde(default)]
    pub note: String,
    #[serde(default = "root")]
    pub folder_id: String,
    #[serde(default)]
    pub custom_fields: Vec<Field>,
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Revision {
    pub changed_at: String,
    // Preserve both Dart history encodings verbatim for lossless export.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    #[serde(flatten)]
    pub values: Values,
    pub updated_at: String,
    #[serde(default)]
    pub history: Vec<Revision>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Vault {
    #[serde(default)]
    pub(crate) disk: crate::yandex::Account,
    pub folders: Vec<Folder>,
    pub entries: Vec<Entry>,
}

impl Vault {
    pub fn subtree(&self, id: &str) -> Result<HashSet<String>, &'static str> {
        if id == "root" || !self.folders.iter().any(|f| f.id == id) {
            return Err("Выберите пользовательскую папку");
        }
        let mut ids = HashSet::new();
        let mut pending = vec![id.to_owned()];
        while let Some(parent) = pending.pop() {
            if ids.insert(parent.clone()) {
                pending.extend(
                    self.folders
                        .iter()
                        .filter(|f| f.parent_id == parent)
                        .map(|f| f.id.clone()),
                );
            }
        }
        Ok(ids)
    }

    /// Parse both decrypted preference values together. Errors never include user data.
    pub fn from_android(
        folders: Option<&str>,
        entries: Option<&str>,
    ) -> Result<Self, &'static str> {
        let folders: Vec<Folder> = match folders {
            Some(raw) => serde_json::from_str(raw).map_err(|_| "Не удалось прочитать папки")?,
            None => vec![Folder {
                id: root(),
                name: "Все записи".into(),
                parent_id: root(),
            }],
        };
        let entries: Vec<Entry> = serde_json::from_str(entries.unwrap_or("[]"))
            .map_err(|_| "Не удалось прочитать записи")?;
        let parents: HashMap<_, _> = folders
            .iter()
            .map(|f| (f.id.as_str(), f.parent_id.as_str()))
            .collect();
        if parents.len() != folders.len() || parents.get("root") != Some(&"root") {
            return Err("Повреждён список папок");
        }
        for folder in &folders {
            let mut path = HashSet::new();
            let mut current = folder.id.as_str();
            while current != "root" {
                if !path.insert(current) {
                    return Err("Цикл в дереве папок");
                }
                current = parents
                    .get(current)
                    .ok_or("Отсутствует родительская папка")?;
            }
        }
        let mut ids = HashSet::new();
        for entry in &entries {
            if !ids.insert(&entry.id) || !parents.contains_key(entry.values.folder_id.as_str()) {
                return Err("Повреждена привязка записи");
            }
        }
        Ok(Self {
            folders,
            entries,
            disk: Default::default(),
        })
    }
}
