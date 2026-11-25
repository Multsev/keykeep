use crate::legacy::{Entry, Folder, Vault};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
pub struct TrashItem {
    pub id: String,
    pub name: String,
    pub kind: String,
    ancestors: Vec<Folder>,
    folders: Vec<Folder>,
    entries: Vec<Entry>,
}

impl Vault {
    pub(crate) fn trash_item(&mut self, id: &str, folder: bool) -> Result<String, &'static str> {
        let (name, mut parent, folders, entries) = if folder {
            let ids = self.subtree(id)?;
            let root = self
                .folders
                .iter()
                .find(|f| f.id == id)
                .ok_or("Папка отсутствует")?;
            let result = (
                root.name.clone(),
                root.parent_id.clone(),
                self.folders
                    .iter()
                    .filter(|f| ids.contains(&f.id))
                    .cloned()
                    .collect(),
                self.entries
                    .iter()
                    .filter(|e| ids.contains(&e.values.folder_id))
                    .cloned()
                    .collect(),
            );
            self.folders.retain(|f| !ids.contains(&f.id));
            self.entries.retain(|e| !ids.contains(&e.values.folder_id));
            result
        } else {
            let i = self
                .entries
                .iter()
                .position(|e| e.id == id)
                .ok_or("Запись отсутствует")?;
            let e = self.entries.remove(i);
            (
                e.values.title.clone(),
                e.values.folder_id.clone(),
                vec![],
                vec![e],
            )
        };
        let mut ancestors = vec![];
        while parent != "root" {
            let f = self
                .folders
                .iter()
                .find(|f| f.id == parent)
                .ok_or("Папка отсутствует")?;
            ancestors.push(f.clone());
            parent = f.parent_id.clone();
        }
        ancestors.reverse();
        let token = Uuid::new_v4().to_string();
        self.trash.push(TrashItem {
            id: token.clone(),
            name,
            kind: if folder { "folder" } else { "entry" }.into(),
            ancestors,
            folders,
            entries,
        });
        Ok(token)
    }
    pub(crate) fn trash_list(&self) -> Value {
        json!(self.trash.iter().rev().map(|t|json!({"id":t.id,"name":t.name,"kind":t.kind,"path":t.ancestors.iter().map(|f| &f.name).collect::<Vec<_>>()})).collect::<Vec<_>>())
    }
    pub(crate) fn restore_item(&mut self, id: &str) -> Result<(), &'static str> {
        let i = self
            .trash
            .iter()
            .position(|t| t.id == id)
            .ok_or("Объект отсутствует в корзине")?;
        let item = self.trash.remove(i);
        if item
            .entries
            .iter()
            .any(|e| self.entries.iter().any(|a| a.id == e.id))
        {
            return Err("Запись с этим идентификатором уже существует");
        }
        for f in item.ancestors.into_iter().chain(item.folders) {
            if !self.folders.iter().any(|a| a.id == f.id) {
                self.folders.push(f);
            }
        }
        self.entries.extend(item.entries);
        self.validate()
    }
}
