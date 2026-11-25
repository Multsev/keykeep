import Cocoa
import UniformTypeIdentifiers
import LocalAuthentication
import Security
import WebKit

struct PlatformFailure: Error {}

func deviceKey(for path: URL) throws -> Data {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.max.keykeep.device",
        kSecAttrAccount as String: "local-v1"
    ]
    var lookup = query
    lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
    guard status == errSecItemNotFound, !FileManager.default.fileExists(atPath: path.path) else { throw PlatformFailure() }
    var data = Data(count: 32)
    let generated = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard generated == errSecSuccess else { throw PlatformFailure() }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PlatformFailure() }
    return data
}

final class Desktop: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    #if UI_TEST
    var testRoot: URL?
    var testStarted = false
    #endif
    var session: UnsafeMutableRawPointer?
    var fingerprint: Fingerprint!
    var prompt: LAContext?
    var oauthCallback: String?
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url=urls.first, url.scheme=="keykeep",url.host=="oauth",url.path=="/callback" else {return}
        oauthCallback=url.absoluteString
        web?.evaluateJavaScript("window.keykeepOAuthReady?.()")
    }
    var importURL: URL?
    var keyFileURL: URL?
    var web: WKWebView!
    var window: NSWindow!
    let index = Bundle.main.resourceURL!.appendingPathComponent("ui/index.html")
    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            #if UI_TEST
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            #else
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            #endif
            let dir = base.appendingPathComponent("KeyKeep")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fingerprint = Fingerprint(file: dir.appendingPathComponent("touch-id.credential"))
            let file = dir.appendingPathComponent("vault.kk")
            #if UI_TEST
            let key = Data(repeating: 61, count: 32)
            if let fixture = ProcessInfo.processInfo.environment["KEYKEEP_TEST_KDBX"] {
                importURL = URL(fileURLWithPath: fixture)
            }
            defer { testRoot = base }
            #else
            let key = try deviceKey(for: file)
            #endif
            session = key.withUnsafeBytes { kk_new(file.path, $0.bindMemory(to: UInt8.self).baseAddress) }
            guard session != nil else { throw PlatformFailure() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось открыть хранилище"
            alert.informativeText = "Проверьте доступ к связке ключей и закройте другие окна KeyKeep."
            alert.runModal(); NSApp.terminate(nil); return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "vault")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 900,height: 600), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyKeep"; window.contentMinSize = NSSize(width: 400,height: 350)
        window.contentView = web; window.center()
        window.makeKeyAndOrderFront(nil)
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lock), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func lock() {
        guard let session = session else { return }
        prompt?.invalidate(); prompt = nil
        kk_free_text(kk_call(session, "{\"op\":\"lock\"}"))
        web.isHidden = true
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.isHidden = false
        #if UI_TEST
        guard !testStarted else { return }
        testStarted = true
        do {
            let test = try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("smoke.js"))
            webView.callAsyncJavaScript(test, arguments: ["startupImport":importURL != nil], in: nil, in: .page) { result in
                if let root = self.testRoot { try? FileManager.default.removeItem(at: root) }
                switch result {
                case .success(let value):
                    print(value)
                    webView.takeSnapshot(with: nil) { image, _ in
                        guard let tiff = image?.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
                        let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("window.png")
                        do { try png.write(to: destination); exit(0) } catch { exit(1) }
                    }
                case .failure(let error): print(error.localizedDescription); exit(1)
                }
            }
        } catch { exit(1) }
        #endif
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url?.standardizedFileURL == index.standardizedFileURL ? .allow : .cancel)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == index.standardizedFileURL,
              let request = message.body as? String,
              let args = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String:Any],
              let op = args["op"] as? String else {
            replyHandler(nil,"Недоступно"); return
        }
        func reply(_ object: [String:Any]) {
            let data = try? JSONSerialization.data(withJSONObject: object)
            replyHandler(data.flatMap { String(data: $0, encoding: .utf8) }, nil)
        }
        func core(_ args: [String:Any]) -> [String:Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let query = String(data: data, encoding: .utf8),
                  let answer = kk_call(session, query) else { return ["error":"Ошибка операции"] }
            defer { kk_free_text(answer) }
            return (try? JSONSerialization.jsonObject(with: Data(String(cString:answer).utf8)) as? [String:Any]) ?? ["error":"Ошибка ответа"]
        }
        if op == "diskConnect" {
            let result=core(["op":"diskAuthorize"])
            guard let raw=result["value"] as? String, let url=URL(string:raw),url.scheme=="https",url.host=="oauth.yandex.ru" else {reply(result);return}
            reply(NSWorkspace.shared.open(url) ? ["value":NSNull()] : ["error":"Не удалось открыть браузер"]);return
        }
        if op == "consumeOAuth" {
            let state=core(["op":"status"])["value"] as? [String:Any]
            guard state?["open"] as? Bool == true,let raw=oauthCallback else {reply(["value":false]);return}
            oauthCallback=nil
            let result=core(["op":"diskCallback","callback":raw]);reply(result["error"]==nil ? ["value":true] : result);return
        }
        if op == "copyField" {
            guard let state = core(["op":"status"])["value"] as? [String:Any],
                  state["open"] as? Bool == true, let text = args["text"] as? String else {reply(["error":"Хранилище заблокировано"]);return}
            let board = NSPasteboard.general
            let item = NSPasteboardItem()
            item.setString(text, forType:.string)
            let sensitive = args["protected"] as? Bool == true
            if sensitive {
                item.setData(Data(), forType:NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                item.setData(Data(), forType:NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            }
            board.clearContents()
            guard board.writeObjects([item]) else {reply(["error":"Не удалось скопировать"]);return}
            if sensitive {
                let change = board.changeCount
                DispatchQueue.main.asyncAfter(deadline:.now()+30) {
                    if board.changeCount == change { board.clearContents() }
                }
            }
            reply(["value":NSNull()]);return
        }
        if op == "fileStatus" {
            reply(["value":["database":importURL?.lastPathComponent ?? "", "keyfile":keyFileURL?.lastPathComponent ?? ""]]); return
        }
        if op == "clearExchange" { importURL=nil; keyFileURL=nil; reply(["value":NSNull()]); return }
        if op == "pickDatabase" || op == "pickKeyfile" {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if op == "pickDatabase", let type = UTType(filenameExtension:"kdbx") { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let url = panel.url else {reply(["error":"Выбор отменён"]);return}
            if op == "pickDatabase" {importURL=url} else {keyFileURL=url}
            reply(["value":NSNull()]);return
        }
        if ["readDatabase", "writeDatabase", "createFromFile"].contains(op) {
            do {
                var query = args
                guard let state = core(["op":"status"])["value"] as? [String:Any], (op == "createFromFile" ? state["exists"] as? Bool == false : state["open"] as? Bool == true) else {reply(["error":"Проверьте состояние хранилища"]);return}
                if let keyFileURL { query["keyfile"] = try Data(contentsOf:keyFileURL).base64EncodedString() }
                if op != "writeDatabase" {
                    guard let importURL else {reply(["error":"Выберите файл KDBX"]);return}
                    query["op"] = op == "createFromFile" ? "createFromKdbx" : "importKdbx"
                    query["data"]=try Data(contentsOf:importURL).base64EncodedString()
                    let result=core(query)
                    if result["error"] == nil { self.importURL=nil; self.keyFileURL=nil }
                    reply(result);return
                }
                query["op"]="exportKdbx"
                let result=core(query)
                guard let encoded=result["value"] as? String, let data=Data(base64Encoded:encoded) else {reply(result);return}
                let panel=NSSavePanel()
                panel.nameFieldStringValue="keykeep-vault.kdbx"
                guard panel.runModal() == .OK, let url=panel.url else {reply(["error":"Сохранение отменено"]);return}
                try data.write(to:url,options:.atomic)
                self.keyFileURL=nil; reply(["value":NSNull()])
            } catch {reply(["error":"Ошибка чтения или записи файла"])}
            return
        }
        if op == "showPin" {
            guard prompt == nil else { reply(["error":"Подтверждение уже открыто"]); return }
            let ctx = LAContext()
            prompt = ctx
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Показать действующий мастер-PIN KeyKeep") { ok, _ in
                DispatchQueue.main.async {
                    let approved = self.prompt === ctx && ok
                    if self.prompt === ctx { self.prompt = nil }
                    ctx.invalidate()
                    guard approved, let pin = kk_authenticated_pin(self.session) else { reply(["error":"Просмотр PIN отменён"]); return }
                    defer { kk_free_text(pin) }
                    reply(["value":String(cString:pin)])
                }
            }
            return
        }
        if op == "bioStatus" {
            reply(["value":["available":fingerprint.available,"enabled":fingerprint.enabled,"autoPrompt":fingerprint.enabled && (UserDefaults.standard.object(forKey:"bioAutoPrompt") as? Bool ?? true)]])
            return
        }
        if op == "setBioAutoPrompt" {
            guard fingerprint.enabled, let value=args["enabled"] as? Bool,
                  let state=core(["op":"status"])["value"] as? [String:Any], state["open"] as? Bool == true else {
                reply(["error":"Откройте хранилище и включите Touch ID"]); return
            }
            UserDefaults.standard.set(value,forKey:"bioAutoPrompt")
            reply(["value":NSNull()]); return
        }
        if op == "lock" { prompt?.invalidate(); prompt = nil }
        if ["bioEnable","bioDisable","changePin"].contains(op) {
            let proof = core(["op":"verifyPin","currentPin":args["currentPin"] ?? ""])
            if proof["error"] != nil { reply(proof); return }
        }
        if op == "bioDisable" {
            do { try fingerprint.disable(); reply(["value":NSNull()]) }
            catch { reply(["error":"Не удалось отключить Touch ID"]) }
            return
        }
        if op == "bioEnable" || op == "bioUnlock" {
            guard prompt == nil, fingerprint.available else { reply(["error":"Touch ID недоступен"]); return }
            let ctx = LAContext()
            ctx.localizedFallbackTitle = ""
            prompt = ctx
            let reason = op == "bioEnable" ? "Включить вход в KeyKeep" : "Открыть KeyKeep"
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
                DispatchQueue.main.async {
                    guard self.prompt === ctx, ok else {
                        if self.prompt === ctx { self.prompt = nil }
                        reply(["error":"Подтверждение Touch ID отменено"]); return
                    }
                    defer { ctx.invalidate(); self.prompt = nil }
                    do {
                        if op == "bioEnable", let pin = args["currentPin"] as? String {
                            try self.fingerprint.enroll(pin: pin, context: ctx)
                            UserDefaults.standard.set(true,forKey:"bioAutoPrompt")
                            reply(["value":NSNull()])
                        } else {
                            let pin = try self.fingerprint.recover(context: ctx)
                            reply(core(["op":"unlock","pin":pin]))
                        }
                    } catch { reply(["error":"Touch ID не открыл ключ. Войдите по PIN и настройте отпечаток повторно."]) }
                }
            }
            return
        }
        if op == "changePin" && fingerprint.enabled {
            guard let next = args["newPin"] as? String, next.unicodeScalars.count >= 6 else {
                reply(["error":"Введите минимум 6 символов"]); return
            }
            do { try fingerprint.disable() } catch { reply(["error":"Не удалось обновить настройки Touch ID"]); return }
        }
        reply(core(args))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { kk_close(session); session = nil }
}

let app = NSApplication.shared
let delegate = Desktop()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Завершить KeyKeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appItem = NSMenuItem()
appItem.submenu = appMenu
menu.addItem(appItem)
let editMenu = NSMenu(title: "Правка")
for (title, action, key) in [("Вырезать","cut:","x"),("Скопировать","copy:","c"),("Вставить","paste:","v"),("Выделить всё","selectAll:","a")] {
    editMenu.addItem(withTitle: title,action: Selector(action),keyEquivalent: key)
}
let editItem = NSMenuItem()
editItem.submenu = editMenu
menu.addItem(editItem)
app.mainMenu = menu
app.run()
