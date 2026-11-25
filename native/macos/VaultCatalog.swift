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
            result.append(["id":Self.original, "name":"Основное","file":try file(Self.original).path])
        }
        if fm.fileExists(atPath: profiles.path) {
            let dirs = try fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys:nil)
            for dir in dirs {
                let id = dir.lastPathComponent
                if let checked = try? directory(id),
                   let name = try? String(contentsOf: checked.appendingPathComponent("name"), encoding:.utf8) {
                    result.append(["id":id,"name":name,"file":try file(id).path])
                }
            }
        }
        return result.sorted { $0["name"]!.localizedStandardCompare($1["name"]!) == .orderedAscending }
    }

    func file(_ id:String) throws -> URL {
        let dir=try directory(id)
        let ref=dir.appendingPathComponent("location")
        if FileManager.default.fileExists(atPath:ref.path) {
            let path=try String(contentsOf:ref,encoding:.utf8)
            guard path.hasPrefix("/"), URL(fileURLWithPath:path).pathExtension.lowercased()=="kk" else {throw PlatformFailure()}
            return URL(fileURLWithPath:path)
        }
        return dir.appendingPathComponent("vault.kk")
    }

    func create(at file:URL) throws -> String {
        let title=file.deletingPathExtension().lastPathComponent
        guard file.pathExtension.lowercased()=="kk", !FileManager.default.fileExists(atPath:file.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath:file.path)) == nil,
              try !items().contains(where:{try self.file($0["id"]!).standardizedFileURL == file.standardizedFileURL})
        else {throw PlatformFailure()}
        guard !title.isEmpty, title.rangeOfCharacter(from:.controlCharacters) == nil
        else { throw PlatformFailure() }
        let id = UUID().uuidString
        let dir = profiles.appendingPathComponent(id)
        try FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        try file.path.write(to:dir.appendingPathComponent("location"),atomically:true,encoding:.utf8)
        try title.write(to:dir.appendingPathComponent("name"), atomically:true, encoding:.utf8)
        return id
    }
}
