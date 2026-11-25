import Foundation

final class VaultCatalog {
    init(base:URL){self.base=base}
    private var identities=[String:UInt64]()
    static let original = "local-v1"
    static let empty = "empty"
    let base: URL
    private var profiles: URL { base.appendingPathComponent("KeyKeep Vaults") }

    func directory(_ id: String) throws -> URL {
        if id == Self.empty {return base.appendingPathComponent("KeyKeep Empty")}
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
            let nameFile=try directory(Self.original).appendingPathComponent("name")
            let name=(try? String(contentsOf:nameFile,encoding:.utf8)) ?? "Основное"
            result.append(["id":Self.original, "name":name,"file":try file(Self.original).path])
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
            let url=URL(fileURLWithPath:path)
            if FileManager.default.fileExists(atPath:path){return url}
            let mark=dir.appendingPathComponent("bookmark")
            var stale=false
            if let data=try? Data(contentsOf:mark),
               let moved=try? URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),
               moved.pathExtension.lowercased()=="kk",FileManager.default.fileExists(atPath:moved.path) {
                try moved.path.write(to:ref,atomically:true,encoding:.utf8)
                identities.removeValue(forKey:id)
                return moved
            }
            return url
        }
        return dir.appendingPathComponent("vault.kk")
    }

    func remember(_ file:URL, for id:String){
        var info=stat()
        guard id != Self.empty, id != Self.original,stat(file.path,&info)==0,identities[id] != info.st_ino,
              let dir=try? directory(id)
        else{return}
        if let data=try? URL(fileURLWithPath:file.path).bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil){
            try? data.write(to:dir.appendingPathComponent("bookmark"),options:.atomic)
        }
        if let signature=header(file) {
            try? signature.write(to:dir.appendingPathComponent("fileHeader"),options:.atomic)
        }
        identities[id]=info.st_ino
    }
    private func header(_ file:URL)->Data? {
        guard let handle=try? FileHandle(forReadingFrom:file) else{return nil}
        defer{try? handle.close()}
        guard let bytes=try? handle.read(upToCount:48),bytes.count==48,bytes.starts(with:Data("KK01".utf8)) else{return nil}
        return bytes
    }
    func relink(_ file:URL,id:String) throws {
        guard id != Self.original,id != Self.empty, !FileManager.default.fileExists(atPath:try self.file(id).path),
              file.pathExtension.lowercased()=="kk" else {throw PlatformFailure()}
        var bytes=[UInt8](repeating:0,count:64)
        let n=getxattr(file.path,"com.max.keykeep.profile",&bytes,bytes.count,0,0)
        let tagged=n>0 && String(bytes:bytes.prefix(n),encoding:.utf8)==id
        let known=try? Data(contentsOf:directory(id).appendingPathComponent("fileHeader"))
        guard tagged || (known != nil && header(file)==known) else {throw PlatformFailure()}
        try file.path.write(to:directory(id).appendingPathComponent("location"),atomically:true,encoding:.utf8)
        remember(file,for:id)
    }

    func rename(_ id:String, to value:String) throws {
        let title=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty, title.count<=255, title.rangeOfCharacter(from:.controlCharacters)==nil,
              try items().contains(where:{$0["id"]==id}) else {throw PlatformFailure()}
        try title.write(to:directory(id).appendingPathComponent("name"),atomically:true,encoding:.utf8)
    }

    func suggestedFile(name:String,in folder:URL) throws ->URL {
        let reserved=Set(try items().compactMap{$0["file"]})
        var url=folder.appendingPathComponent(name+".kk"),n=2
        while reserved.contains(url.path) || FileManager.default.fileExists(atPath:url.path) {
            url=folder.appendingPathComponent(name+" ("+String(n)+").kk");n+=1
        }
        return url
    }
    func moveDraft(_ id:String,to url:URL)throws{
        let old=try file(id)
        if url.standardizedFileURL==old.standardizedFileURL{return}
        let dir=try directory(id)
        guard UUID(uuidString:id) != nil, url.pathExtension.lowercased()=="kk",
              !FileManager.default.fileExists(atPath:dir.appendingPathComponent("vault.created").path),
              !FileManager.default.fileExists(atPath:old.path),!FileManager.default.fileExists(atPath:url.path),
              try !items().contains(where:{$0["file"]==url.path}) else{throw PlatformFailure()}
        let location=dir.appendingPathComponent("location")
        try url.path.write(to:location,atomically:true,encoding:.utf8)
        do{try rename(id,to:url.deletingPathExtension().lastPathComponent)}
        catch{try old.path.write(to:location,atomically:true,encoding:.utf8);throw error}
    }
    func create(at file:URL) throws -> String {
        let title=file.deletingPathExtension().lastPathComponent
        guard file.pathExtension.lowercased()=="kk", !FileManager.default.fileExists(atPath:file.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath:file.path)) == nil,
              try !items().contains(where:{try self.file($0["id"]!).standardizedFileURL == file.standardizedFileURL})
        else {throw PlatformFailure()}
        return try register(file, title:title)
    }

    func register(_ file:URL, title:String) throws -> String {
        guard !title.isEmpty, title.rangeOfCharacter(from:.controlCharacters) == nil
        else { throw PlatformFailure() }
        let id = UUID().uuidString
        let dir = profiles.appendingPathComponent(id)
        try FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        var complete=false
        defer {if !complete {try? FileManager.default.removeItem(at:dir)}}
        try file.path.write(to:dir.appendingPathComponent("location"),atomically:true,encoding:.utf8)
        try title.write(to:dir.appendingPathComponent("name"), atomically:true, encoding:.utf8)
        complete=true
        return id
    }
}
