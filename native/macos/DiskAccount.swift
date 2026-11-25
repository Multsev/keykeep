import Cocoa
import Security
import LocalAuthentication

private struct DiskAccountError: LocalizedError {
    let message:String
    var errorDescription:String? {message}
}

// This item also holds the short-lived PKCE verifier so the callback survives a relaunch.
final class DiskAccount {
    private let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"com.max.keykeep.yandex",kSecAttrAccount as String:"shared"]
    #if UI_TEST
    private var fixture:Data?
    #endif
    private(set) var message=""
    private var exchanging=false
    private func load(interactive:Bool=true) throws -> [String:Any] {
        #if UI_TEST
        guard let data=fixture else {return [:]}
        #else
        var lookup=query
        if !interactive {
            let context=LAContext()
            context.interactionNotAllowed=true
            lookup[kSecUseAuthenticationContext as String]=context
        }
        lookup[kSecReturnData as String]=true
        var raw:CFTypeRef?
        let status=SecItemCopyMatching(lookup as CFDictionary,&raw)
        if status==errSecItemNotFound {return [:]}
        guard status==errSecSuccess,let data=raw as? Data else {throw DiskAccountError(message:"Связка ключей недоступна")}
        #endif
        guard let item=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw PlatformFailure()}
        return item
    }
    private func store(_ item:[String:Any]) throws {
        let data=try JSONSerialization.data(withJSONObject:item)
        #if UI_TEST
        fixture=data
        #else
        let changes=[kSecValueData as String:data]
        let status=SecItemUpdate(query as CFDictionary,changes as CFDictionary)
        if status==errSecItemNotFound {
            var new=query
            new[kSecValueData as String]=data
            new[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(new as CFDictionary,nil)==errSecSuccess else {throw PlatformFailure()}
        } else if status != errSecSuccess {throw PlatformFailure()}
        #endif
    }
    func credentials() throws -> (binding:String,token:String) {
        let item=try load()
        return (item["binding"] as? String ?? "", item["token"] as? String ?? "")
    }
    func status() throws -> [String:Any] {
        let item=try load(interactive:false)
        return ["client":item["client"] as? String ?? "", "connected":!(item["token"] as? String ?? "").isEmpty,"message":message]
    }
    private static func oauth(_ request:[String:Any]) throws -> [String:Any] {
        let json=try JSONSerialization.data(withJSONObject:request)
        guard let string=String(data:json,encoding:.utf8),let ptr=kk_shared_oauth(string) else {throw PlatformFailure()}
        defer {kk_free_text(ptr)}
        let reply=try JSONSerialization.jsonObject(with:Data(String(cString:ptr).utf8)) as? [String:Any]
        guard let value=reply?["value"] as? [String:Any] else {throw DiskAccountError(message:reply?["error"] as? String ?? "Ошибка подключения")}
        return value
    }
    func configure(_ client:String, connect:Bool) throws {
        let id=client.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty else {throw DiskAccountError(message:"Введите публичный Client ID")}
        var item=try load()
        if item["client"] as? String != id {
            item=["client":id,"binding":UUID().uuidString]
        }
        if connect {
            let result=try Self.oauth(["op":"authorize","account":item])
            guard let account=result["account"] as? [String:Any],let raw=result["url"] as? String,
                  let url=URL(string:raw),url.scheme=="https",url.host=="oauth.yandex.ru" else {throw PlatformFailure()}
            item["pending"]=account["pending"]
            try store(item)
            #if !UI_TEST
            guard NSWorkspace.shared.open(url) else {throw DiskAccountError(message:"Не удалось открыть браузер")}
            #endif
            message="Завершите вход в браузере"
        } else {
            try store(item)
            message="Настройки сохранены"
        }
    }
    func disconnect() throws {
        let old=try load()
        try store(["client":old["client"] as? String ?? "", "binding":UUID().uuidString])
        message="Аккаунт отключён"
    }
    func callback(_ url:URL, completion:@escaping ()->Void) -> Bool {
        guard let item=try? load(),let pending=item["pending"] as? [String:Any] else {return false}
        guard !exchanging else {return true}
        exchanging=true
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result {try Self.oauth(["op":"callback","account":item,"callback":url.absoluteString])}
            DispatchQueue.main.async {
                defer {self.exchanging=false;completion()}
                do {
                    var current=try self.load()
                    guard let nonce=pending["state"] as? String,
                          (current["pending"] as? [String:Any])?["state"] as? String==nonce else {return}
                    let value=try result.get()
                    guard let account=value["account"] as? [String:Any],let token=account["token"] as? String,!token.isEmpty else {throw PlatformFailure()}
                    current.removeValue(forKey:"pending")
                    current["token"]=token
                    try self.store(current)
                    self.message="Яндекс.Диск подключён"
                } catch {self.message=error.localizedDescription}
            }
        }
        return true
    }
}
