import Cocoa
import UniformTypeIdentifiers
import LocalAuthentication
import Security
import WebKit

struct PlatformFailure: Error {}

private func deviceKeyQuery(_ account:String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.max.keykeep.device",
        kSecAttrAccount as String: account
    ] }
func deviceKey(for path: URL, account:String, replacing: Bool = false) throws -> Data {
    let query = deviceKeyQuery(account)
    var lookup = query
    lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
    guard status == errSecItemNotFound, replacing || !FileManager.default.fileExists(atPath: path.path) else { throw PlatformFailure() }
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
    let testClipboard=NSPasteboard.withUniqueName()
    var testRoot: URL?
    var testStarted = false
    #endif
    var session: UnsafeMutableRawPointer?
    var fingerprint: Fingerprint!
    var prompt: LAContext?
    #if UI_TEST
    var mcpEnabled=false
    #else
    var mcpEnabled:Bool {
        get {UserDefaults.standard.bool(forKey:"mcpEnabled")}
        set {UserDefaults.standard.set(newValue,forKey:"mcpEnabled")}
    }
    #endif
    let diskAccount=DiskAccount()
    var oauthCallback: String?
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url=urls.first, url.scheme=="keykeep",url.host=="oauth",url.path=="/callback" else {return}
        if diskAccount.callback(url,completion:{self.web?.evaluateJavaScript("window.sharedDiskChanged?.()")}) {return}
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
            catalog = VaultCatalog(base:base)
            var selected = try catalog.items().first?["id"] ?? VaultCatalog.empty
            #if !UI_TEST
            if let saved = UserDefaults.standard.string(forKey:"selectedVault"),
               try catalog.items().contains(where: { $0["id"] == saved }) { selected = saved }
            #endif
            if selected == VaultCatalog.empty, FileManager.default.fileExists(atPath:try catalog.directory(VaultCatalog.original).appendingPathComponent("vault.erasing").path) {selected=VaultCatalog.original}
            try activateVault(selected)
            #if UI_TEST
            if let fixture=ProcessInfo.processInfo.environment["KEYKEEP_TEST_KDBX"] {importURL=URL(fileURLWithPath:fixture)}
            testRoot=base
            #endif
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
        NotificationCenter.default.addObserver(self,selector:#selector(lock),name:NSWindow.didMiniaturizeNotification,object:window)
        window.contentView = web; window.center()
        window.makeKeyAndOrderFront(nil)
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lock), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private var parked = [String: UnsafeMutableRawPointer]()
    private var rememberActive = false
    private func forgetSessions() {
        rememberActive = false
        for handle in parked.values { kk_close(handle) }
        parked.removeAll()
    }
    var catalog: VaultCatalog!
    var activeID = VaultCatalog.original
    var bioPreference:String { activeID == VaultCatalog.original ? "bioAutoPrompt" : "bioAutoPrompt."+activeID }

    private func attachVault(_ input:URL, beforeSwitch:() throws -> Void) throws {
        let file=input.resolvingSymlinksInPath().standardizedFileURL
        guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {throw PlatformFailure()}
        let items=try catalog.items()
        if let existing=items.first(where:{URL(fileURLWithPath:$0["file"]!).resolvingSymlinksInPath().standardizedFileURL == file}) {
            try beforeSwitch()
            try activateVault(existing["id"]!)
            return
        }
        let handle=try FileHandle(forReadingFrom:file)
        defer {try? handle.close()}
        guard try handle.read(upToCount:4)==Data("KK01".utf8), try handle.seekToEnd()>=48 else {
            throw NSError(domain:"KeyKeep.Add",code:1,userInfo:[NSLocalizedDescriptionKey:"Файл не является хранилищем KeyKeep."])
        }
        var bytes=[UInt8](repeating:0,count:64)
        let length=getxattr(file.path,"com.max.keykeep.profile",&bytes,bytes.count,0,0)
        let tag=length>0 ? String(bytes:bytes.prefix(length),encoding:.utf8) : nil
        // Old snapshots have no locator. An exact local copy identifies the same device key.
        let account:String?
        if let tag, tag == VaultCatalog.original || UUID(uuidString:tag)?.uuidString == tag {account=tag}
        else {account=items.first(where:{FileManager.default.contentsEqual(atPath:$0["file"]!,andPath:file.path)})?["id"]}
        let missingKey=NSError(domain:"KeyKeep.Add",code:2,userInfo:[NSLocalizedDescriptionKey:"Не удалось найти ключ этого файла на Mac. На исходном устройстве экспортируйте хранилище в KeePass (.kdbx)."])
        guard let account else {throw missingKey}
        #if !UI_TEST
        var query=deviceKeyQuery(account)
        query[kSecReturnData as String]=true
        var value:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess, let key=value as? Data,key.count==32 else {throw missingKey}
        #endif
        let id=try catalog.register(file,title:file.deletingPathExtension().lastPathComponent)
        do {
            let dir=try catalog.directory(id)
            try Data("1".utf8).write(to:dir.appendingPathComponent("vault.created"),options:.atomic)
            #if !UI_TEST
            var item=deviceKeyQuery(id)
            item[kSecValueData as String]=key
            item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else {throw PlatformFailure()}
            #else
            if let source=try? catalog.directory(account),FileManager.default.fileExists(atPath:source.appendingPathComponent("test-key-rotated").path){
                try Data().write(to:dir.appendingPathComponent("test-key-rotated"))
            }
            #endif
            try beforeSwitch()
            try activateVault(id)
        } catch {
            if let dir=try? catalog.directory(id){try? FileManager.default.removeItem(at:dir)}
            #if !UI_TEST
            SecItemDelete(deviceKeyQuery(id) as CFDictionary)
            #endif
            throw error
        }
    }

    private func activateVault(_ id:String) throws {
        if session != nil && activeID == id {return}
        let dir = try catalog.directory(id)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = try catalog.file(id)
        let cached=parked.removeValue(forKey:id)
        guard let next=cached ?? kk_new_at(file.path,dir.appendingPathComponent("vault.kk").path) else {throw PlatformFailure()}
        let old=session, oldID=activeID, oldFingerprint=fingerprint
        session=next;activeID=id;fingerprint=Fingerprint(file:dir.appendingPathComponent("touch-id.credential"))
        do {
            if kk_erasing(next) {try finishErasure()}
            else if cached == nil {
                #if UI_TEST
                let rotated=FileManager.default.fileExists(atPath:dir.appendingPathComponent("test-key-rotated").path)
                let key=Data(repeating:rotated ? 72 : 61,count:32)
                #else
                let key = id == VaultCatalog.empty ? Data(repeating:0,count:32) : try deviceKey(for:file,account:id)
                #endif
                guard key.withUnsafeBytes({kk_initialize_device(next,$0.bindMemory(to:UInt8.self).baseAddress)}) else {throw PlatformFailure()}
            }
        } catch {
            kk_close(next);session=old;activeID=oldID;fingerprint=oldFingerprint;throw error
        }
        if let old {
            if rememberActive {parked[oldID]=old} else {kk_close(old)}
        }
        rememberActive=cached != nil
        prompt?.invalidate();prompt=nil;importURL=nil;keyFileURL=nil;oauthCallback=nil
        #if !UI_TEST
        UserDefaults.standard.set(id,forKey:"selectedVault")
        #endif
        window?.title = "KeyKeep"
    }
    private func finishErasure() throws {
        rememberActive=false
        prompt?.invalidate();prompt=nil;oauthCallback=nil;importURL=nil;keyFileURL=nil
        try fingerprint.disable()
        #if UI_TEST
        try Data().write(to:catalog.directory(activeID).appendingPathComponent("test-key-rotated"))
        let key=Data(repeating:72,count:32)
        #else
        UserDefaults.standard.removeObject(forKey:self.bioPreference)
        let status=SecItemDelete(deviceKeyQuery(activeID) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw PlatformFailure()}
        let key=try deviceKey(for:catalog.file(activeID),account:activeID,replacing:true)
        #endif
        guard key.withUnsafeBytes({ kk_finish_erasure(session,$0.bindMemory(to:UInt8.self).baseAddress) }) else {throw PlatformFailure()}
    }
    func applicationDidHide(_ notification: Notification) { lock() }
    @objc func lock() {
        web?.isHidden = true
        forgetSessions()
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
            webView.callAsyncJavaScript(test, arguments: ["benchCount":Int(ProcessInfo.processInfo.environment["KEYKEEP_MCP_BENCH_COUNT"] ?? "") ?? 0,"testAddFile":ProcessInfo.processInfo.environment["KEYKEEP_TEST_ADD_KK"] == "1","startupImport":importURL != nil,"checkFinder":ProcessInfo.processInfo.environment["KEYKEEP_TEST_FINDER"] == "1"], in: nil, in: .page) { result in
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
                case .failure(let error):
                    let info = (error as NSError).userInfo
                    print(info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                    exit(1)
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
        if ["accountStatus","accountSave","accountConnect","accountDisconnect"].contains(op) {
            do {
                switch op {
                case "accountSave","accountConnect": try diskAccount.configure(args["client"] as? String ?? "",connect:op=="accountConnect")
                case "accountDisconnect": try diskAccount.disconnect()
                default: break
                }
                reply(["value":try diskAccount.status()])
            } catch {reply(["error":error.localizedDescription])}
            return
        }
        if activeID == VaultCatalog.empty && ["create","createFromFile","createFromKdbx"].contains(op) {reply(["error":"Выберите имя и расположение файла"]);return}
        if let origin=args["vaultContext"] as? String, origin != activeID {reply(["error":"Выбрано другое хранилище"]);return}
        if op=="mcpWait" {
            guard let signal=kk_mcp_signal(session) else {reply(["value":false]);return}
            let address=UInt(bitPattern:signal)
            DispatchQueue.global(qos:.userInitiated).async {
                kk_wait_signal(UnsafeMutableRawPointer(bitPattern:address))
                DispatchQueue.main.async {reply(["value":true])}
            }
            return
        }
        if op=="metalPreference" {
            let defaults=UserDefaults.standard
            if let level=args["level"] as? String, ["off","minimal","standard","extended"].contains(level){defaults.set(level,forKey:"metalIntensity")}
            let level = defaults.string(forKey:"metalIntensity") ?? "standard"
            reply(["value":level])
            return
        }
        if op=="collapsedFolders" {
            let key="collapsedFolders."+activeID
            if let ids=args["ids"] as? [String] {UserDefaults.standard.set(ids,forKey:key)}
            reply(["value":UserDefaults.standard.stringArray(forKey:key) ?? []]);return
        }
        if op=="mcpPreference" {
            if let enabled=args["enabled"] as? Bool {
                let state=core(["op":"status"])["value"] as? [String:Any]
                if state?["open"] as? Bool == true {
                    let result=core(["op":enabled ? "mcpStart":"mcpStop"])
                    if result["error"] != nil {reply(result);return}
                }
                mcpEnabled=enabled
            }
            reply(["value":mcpEnabled]);return
        }
        if op=="trashList" || op=="trashRestore" {
            do {
                let trash=VaultTrash(catalog:catalog)
                if op=="trashList" {reply(["value":try trash.items()])}
                else {
                    guard let token=args["id"] as? String else {throw PlatformFailure()}
                    let id=try trash.restore(token)
                    reply(["value":id])
                }
            } catch {reply(["error":"Не удалось восстановить базу. Проверьте Корзину и свободно ли прежнее расположение файла."])}
            return
        }
        if op=="vaultRename" {
            do {
                guard let id=args["id"] as? String, let name=args["name"] as? String else {throw PlatformFailure()}
                try catalog.rename(id,to:name)
                reply(["value":NSNull()])
            } catch {reply(["error":"Не удалось сохранить название хранилища"])}
            return
        }
        if op=="vaultRevealFile" {
            do {
                let file=try catalog.file(activeID)
                let dir=file.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath:file.path) {
                    guard NSWorkspace.shared.selectFile(file.path,inFileViewerRootedAtPath:"") else {throw PlatformFailure()}
                } else if !NSWorkspace.shared.open(dir) {throw PlatformFailure()}
                reply(["value":NSNull()])
            } catch {reply(["error":"Не удалось показать хранилище в Finder"])}
            return
        }
        if op=="vaultRemember" {
            let state=core(["op":"status"])["value"] as? [String:Any]
            rememberActive=state?["open"] as? Bool == true && args["enabled"] as? Bool == true
            reply(["value":NSNull()]);return
        }
        if ["vaultCatalog","vaultSelect","vaultNew","vaultAddFile","vaultTrash"].contains(op) {
            if op == "vaultSelect" || (op == "vaultTrash" && args["id"] as? String == activeID) {
                let readiness=core(["op":"suspendServices"])
                if readiness["error"] != nil {reply(readiness);return}
            }
            do {
                var source:URL?
                if op == "vaultAddFile" {
                    #if UI_TEST
                    if let path=ProcessInfo.processInfo.environment["KEYKEEP_TEST_KDBX"] { source=URL(fileURLWithPath:path) }
                    else {
                        let copy=catalog.base.appendingPathComponent("Копия.kk")
                        if !FileManager.default.fileExists(atPath:copy.path){try FileManager.default.copyItem(at:catalog.file(activeID),to:copy)}
                        source=copy
                    }
                    #else
                    let picker=NSOpenPanel()
                    picker.title="Добавить хранилище"
                    picker.prompt="Добавить"
                    picker.canChooseDirectories=false
                    picker.allowedContentTypes=["kk","kdbx"].compactMap{UTType(filenameExtension:$0)}
                    guard picker.runModal() == .OK,let selected=picker.url else {reply(["value":["cancelled":true]]);return}
                    source=selected
                    #endif
                }
                if let file=source,file.pathExtension.lowercased()=="kk" {
                    let current=try catalog.file(activeID).resolvingSymlinksInPath().standardizedFileURL
                    if file.resolvingSymlinksInPath().standardizedFileURL==current {
                        reply(["value":["cancelled":true]]);return
                    }
                    try attachVault(file) {
                        if let message=core(["op":"suspendServices"])["error"] as? String {
                            throw NSError(domain:"KeyKeep.Add",code:3,userInfo:[NSLocalizedDescriptionKey:message])
                        }
                    }
                } else if op == "vaultNew" || op == "vaultAddFile" {
                    let suggested=source?.deletingPathExtension().lastPathComponent ?? (args["name"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Новое хранилище"
                    #if UI_TEST
                    let first=args["initial"] as? Bool == true
                    let folder=catalog.base.appendingPathComponent("Downloads")
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    let url=folder.appendingPathComponent((first ? "Основное" : "Проверка")+".kk")
                    #else
                    let panel=NSSavePanel()
                    panel.title=source == nil ? "Новое хранилище" : "Сохранить импортированное хранилище KeyKeep"
                    panel.prompt="Выбрать"
                    panel.nameFieldStringValue=suggested+".kk"
                    panel.allowedContentTypes=[UTType(filenameExtension:"kk") ?? .data]
                    panel.isExtensionHidden=false
                    panel.canCreateDirectories=true
                    panel.directoryURL=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first
                    guard panel.runModal() == .OK, let url=panel.url else {reply(["value":["cancelled":true]]);return}
                    #endif
                    guard !FileManager.default.fileExists(atPath:url.path) else {reply(["error":"Файл уже существует. Выберите другое имя."]);return}
                    let readiness=core(["op":"suspendServices"])
                    if readiness["error"] != nil {reply(readiness);return}
                    let id=try catalog.create(at:url)
                    do {try activateVault(id)} catch {
                        if let dir=try? catalog.directory(id){try? FileManager.default.removeItem(at:dir)}
                        throw error
                    }
                    importURL=source;keyFileURL=nil
                } else if op != "vaultCatalog" {
                    guard let id=args["id"] as? String,
                          try catalog.items().contains(where:{$0["id"]==id}) else {throw PlatformFailure()}
                    if op == "vaultSelect" {try activateVault(id)}
                    else {
                        guard args["confirmed"] as? Bool == true else {throw PlatformFailure()}
                        let dir=try catalog.directory(id)
                        let file=try catalog.file(id)
                        let needsLock = id != activeID && parked[id] == nil
                        let lock = needsLock ? kk_new_at(file.path,dir.appendingPathComponent("vault.kk").path) : nil
                        guard !needsLock || lock != nil else {throw PlatformFailure()}
                        defer { if let lock {kk_close(lock)} }
                        var targets=[dir]
                        if file != dir.appendingPathComponent("vault.kk"), FileManager.default.fileExists(atPath:file.path){targets.insert(file,at:0)}
                        guard let name=try catalog.items().first(where:{$0["id"]==id})?["name"] else {throw PlatformFailure()}
                        try VaultTrash(catalog:catalog).remove(id,name:name,targets:targets)
                        if let cached=parked.removeValue(forKey:id) {kk_close(cached)}
                        if activeID==id {
                            rememberActive=false;kk_close(session);session=nil
                            try activateVault(try catalog.items().first?["id"] ?? VaultCatalog.empty)
                        }
                    }
                }
                reply(["value":["items":try catalog.items(),"active":activeID,"remembered":rememberActive,"file":try catalog.file(activeID).path]])
            } catch let error as NSError where error.domain=="KeyKeep.Add" {reply(["error":error.localizedDescription])
            } catch {reply(["error":op=="vaultNew" ? "Выберите свободное имя файла и доступную для записи папку" : "Не удалось открыть или переместить хранилище. Проверьте доступ и закройте другие окна KeyKeep."])}
            return
        }
        #if UI_TEST
        if op == "testPointer" {
            guard let x=args["x"] as? Double, let y=args["y"] as? Double,
                  web.bounds.contains(NSPoint(x:x,y:y)) else {reply(["error":"Invalid test point"]);return}
            let point=web.convert(NSPoint(x:x,y:web.isFlipped ? y : web.bounds.height-y),to:nil)
            let right=args["right"] as? Bool == true
            for type:NSEvent.EventType in (right ? [.rightMouseDown,.rightMouseUp] : [.leftMouseDown,.leftMouseUp]) {
                if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) {
                    window.sendEvent(event)
                }
            }
            reply(["value":true]);return
        }
        if op=="testCopiedConnection" {
            let expected=core(["op":"mcpConnection"])["value"] as? String
            reply(["value":expected != nil && testClipboard.string(forType:.string)==expected]);return
        }
        if op == "testTouchPreflight" {
            reply(["value": ProcessInfo.processInfo.environment["KEYKEEP_TOUCH_PREFLIGHT"] == "1"]);return
        }
        if op == "testMcpPost" {
            guard let token=args["token"] as? String, let rpc=args["rpc"] as? [String:Any] else {reply(["error":"Invalid fixture"]);return}
            var request=URLRequest(url:URL(string:"http://127.0.0.1:18766/mcp")!)
            request.httpMethod="POST"
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try? JSONSerialization.data(withJSONObject:rpc)
            URLSession.shared.dataTask(with:request){ data, _, _ in
                DispatchQueue.main.async {
                    guard let data, let body=try? JSONSerialization.jsonObject(with:data) else {reply(["error":"Invalid MCP response"]);return}
                    reply(["value":body])
                }
            }.resume()
            return
        }
        #endif
        if op == "beginErase" {reply(["error":"Недоступно"]);return}
        if op == "eraseVault" {
            var request=args
            request["op"]="beginErase"
            let result=core(request)
            if result["error"] != nil {reply(result);return}
            do {try finishErasure();reply(["value":NSNull()])}
            catch {reply(["error":"Откройте KeyKeep повторно для завершения удаления"])}
            return
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
        if op == "openWebsite" {
            let state=core(["op":"status"])["value"] as? [String:Any]
            guard state?["open"] as? Bool == true else {reply(["error":"Хранилище заблокировано"]);return}
            guard let raw=args["url"] as? String, let url=URL(string:raw),
                  ["https","http"].contains(url.scheme ?? ""), !(url.host ?? "").isEmpty,
                  url.user==nil, url.password==nil else {reply(["error":"Некорректный адрес сайта"]);return}
            reply(NSWorkspace.shared.open(url) ? ["value":NSNull()] : ["error":"Не удалось открыть браузер"]);return
        }
        if op == "copyField" {
            guard let state = core(["op":"status"])["value"] as? [String:Any],
                  state["open"] as? Bool == true, let text = args["text"] as? String else {reply(["error":"Хранилище заблокировано"]);return}
            #if UI_TEST
            let board=testClipboard
            #else
            let board = NSPasteboard.general
            #endif
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
            reply(["value":["available":fingerprint.available,"enabled":fingerprint.enabled,"autoPrompt":fingerprint.enabled && (UserDefaults.standard.object(forKey:self.bioPreference) as? Bool ?? true)]])
            return
        }
        if op == "setBioAutoPrompt" {
            guard fingerprint.enabled, let value=args["enabled"] as? Bool,
                  let state=core(["op":"status"])["value"] as? [String:Any], state["open"] as? Bool == true else {
                reply(["error":"Откройте хранилище и включите Touch ID"]); return
            }
            UserDefaults.standard.set(value,forKey:self.bioPreference)
            reply(["value":NSNull()]); return
        }
        if op == "lock" { forgetSessions();prompt?.invalidate(); prompt = nil }
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
                            UserDefaults.standard.set(true,forKey:self.bioPreference)
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
            guard let next = args["newPin"] as? String, !next.isEmpty else {
                reply(["error":"Введите PIN"]); return
            }
            do { try fingerprint.disable() } catch { reply(["error":"Не удалось обновить настройки Touch ID"]); return }
        }
        if op.hasPrefix("disk") {
            var request=args
            request.removeValue(forKey:"accountToken")
            request.removeValue(forKey:"accountBinding")
            do {
                let account=try diskAccount.credentials()
                request["accountBinding"]=account.binding
                request["accountToken"]=account.token
                reply(core(request))
            } catch {reply(["error":"Не удалось прочитать подключение Яндекс.Диска"])}
            return
        }
        reply(core(args))
    }
    @objc func openPreferences(){web?.evaluateJavaScript("document.getElementById('generalSettings')?.click()")}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { forgetSessions();kk_close(session); session = nil }
}

let app = NSApplication.shared
let delegate = Desktop()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle:"Настройки…",action:#selector(Desktop.openPreferences),keyEquivalent:",").target=delegate
appMenu.addItem(.separator())
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
