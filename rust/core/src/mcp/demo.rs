use super::{Result, Session, Vault, random_token};
use crate::legacy::{Folder, Values};
use uuid::Uuid;

pub(super) const TOOL: &str = "create_demo_dataset";
pub(super) const DESCRIPTION: &str =
    "Добавить 10 тестовых папок, по 3 подпапки и по 18 записей в каждой подпапке (540 записей).";
const SECTIONS: [&str; 10] = [
    "Разработка",
    "Дизайн",
    "Поддержка",
    "Обучение",
    "Аналитика",
    "Инфраструктура",
    "Документы",
    "Связь",
    "Проекты",
    "Лаборатория",
];
const GROUPS: [&str; 3] = ["Сервисы", "Команда", "Стенды"];

fn folder(vault: &mut Vault, parent: &str, name: String) -> String {
    let id = Uuid::new_v4().to_string();
    vault.folders.push(Folder {
        id: id.clone(),
        name,
        parent_id: parent.into(),
    });
    id
}

pub(super) fn populate(vault: &Vault) -> Result<Vault> {
    let names = SECTIONS.map(|section| format!("Демо · {section}"));
    if vault
        .folders
        .iter()
        .any(|f| f.parent_id == "root" && names.contains(&f.name))
    {
        return Err("Тестовая папка уже существует. Набор не добавлен");
    }
    let mut next = vault.clone();
    let time = chrono::Utc::now().to_rfc3339();
    for (i, name) in names.into_iter().enumerate() {
        let parent = folder(&mut next, "root", name);
        for (j, group) in GROUPS.iter().enumerate() {
            let child = folder(&mut next, &parent, group.to_string());
            for n in 1..=18 {
                let host = format!("demo-{}-{}-{n:02}.example.invalid", i + 1, j + 1);
                Session::save_entry(
                    &mut next,
                    "",
                    Values {
                        title: format!("{} · {group} {n:02}", SECTIONS[i]),
                        username: format!("user@{host}"),
                        password: random_token()?,
                        website: format!("https://{host}"),
                        folder_id: child.clone(),
                        note: String::new(),
                        custom_fields: vec![],
                    },
                    time.clone(),
                    false,
                )?;
            }
        }
    }
    Ok(next)
}
