use serde_json::{Value, json};

pub(super) fn tools() -> Value {
    fn tool(name: &str, description: &str, fields: &[&str], required: &[&str]) -> Value {
        let properties=fields.iter().map(|&field|{
            let schema=if field=="customFields"{json!({"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"string"},"type":{"enum":["text","protected","oneTimePassword"]}},"required":["name","value"],"additionalProperties":false}})}else{json!({"type":"string"})};
            (field.into(),schema)
        }).collect::<serde_json::Map<_,_>>();
        json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false}})
    }
    let entry = [
        "title",
        "username",
        "password",
        "folderId",
        "website",
        "note",
        "customFields",
    ];
    let with_id = [&["id"][..], &entry].concat();
    let mut list = vec![
        tool(
            "list_vault_structure",
            "Папки и записи открытого хранилища без паролей.",
            &[],
            &[],
        ),
        tool(
            "get_password_entry",
            "Прочитать запись после подтверждения.",
            &["id"],
            &["id"],
        ),
        tool(
            "create_folder",
            "Создать папку. Для подпапки укажите parentId.",
            &["name", "parentId"],
            &["name"],
        ),
        tool(
            "update_folder",
            "Переименовать или переместить папку.",
            &["id", "name", "parentId"],
            &["id"],
        ),
        tool(
            "delete_folder",
            "Переместить папку со всем содержимым в корзину.",
            &["id"],
            &["id"],
        ),
        tool(
            "create_password_entry",
            "Создать запись с полями.",
            &entry,
            &["title", "username", "password"],
        ),
        tool(
            "update_password_entry",
            "Изменить указанные поля записи. customFields заменяет список дополнительных полей.",
            &with_id,
            &["id"],
        ),
        tool(
            "upsert_password_entry",
            "Создать или обновить запись по идентификатору.",
            &with_id,
            &["title", "username", "password"],
        ),
        tool(
            "delete_password_entry",
            "Переместить запись в корзину.",
            &["id"],
            &["id"],
        ),
        tool(
            "list_trash",
            "Показать объекты в корзине и исходные папки.",
            &[],
            &[],
        ),
        tool(
            "restore_trash_item",
            "Восстановить объект и его расположение по идентификатору из корзины.",
            &["id"],
            &["id"],
        ),
    ];
    if cfg!(target_os = "macos") {
        list.extend([
            tool("create_vault","Начать создание хранилища на Mac. Владелец выбирает файл и задаёт PIN в приложении.",&["name"],&["name"]),
            tool("rename_vault","Запросить переименование активного хранилища на Mac.",&["name"],&["name"]),
            tool("delete_vault","Запросить перенос активного хранилища в Корзину Mac.",&[],&[]),
        ]);
    }
    json!({"tools":list})
}
