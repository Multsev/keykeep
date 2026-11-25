import Foundation

struct VaultCatalog {
    static let original = "local-v1"
    let base: URL
    private var profiles: URL { base.appendingPathComponent("KeyKeep Vaults") }

    func directory(_ id: String) throws -> URL {
        if id == Self.original { return base.appendingPathComponent("KeyKeep") }
        guard UUID(uuidString: id)?.uuidString == id else { throw PlatformFailure() }
        let dir = profiles.appendingPathComponent(id)
        let info = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw PlatformFailure() }
        return dir
    }

    func items() throws -> [[String:String]] {
        let fm = FileManager.default
        var result = [[String:String]]()
        if fm.fileExists(atPath: try directory(Self.original).appendingPathComponent("vault.kk").path) {
            result.append(["id":Self.original, "name":"Основное"])
        }
        if fm.fileExists(atPath: profiles.path) {
            let dirs = try fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys:nil)
            for dir in dirs {
                let id = dir.lastPathComponent
                if let checked = try? directory(id),
                   let name = try? String(contentsOf: checked.appendingPathComponent("name"), encoding:.utf8) {
                    result.append(["id":id,"name":name])
                }
            }
        }
        return result.sorted { $0["name"]!.localizedStandardCompare($1["name"]!) == .orderedAscending }
    }

    func create(name: String) throws -> String {
        let title = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, title.rangeOfCharacter(from:.controlCharacters) == nil,
              title.localizedCaseInsensitiveCompare("Основное") != .orderedSame,
              try !items().contains(where: { $0["name"]!.localizedCaseInsensitiveCompare(title) == .orderedSame })
        else { throw PlatformFailure() }
        let id = UUID().uuidString
        let dir = profiles.appendingPathComponent(id)
        try FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        try title.write(to:dir.appendingPathComponent("name"), atomically:true, encoding:.utf8)
        return id
    }
}
