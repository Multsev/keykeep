import Foundation

struct VaultTrash {
    let catalog: VaultCatalog
    private let fm = FileManager.default
    private var receipts: URL { catalog.base.appendingPathComponent("KeyKeep Recovery") }
    private var trash: URL {
        #if UI_TEST
        return catalog.base.appendingPathComponent("Trash")
        #else
        return fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        #endif
    }
    private struct Move: Codable {
        let source: URL
        let trashed: URL
    }
    private struct Receipt: Codable {
        let vault: String
        let name: String
        var moves: [Move]
    }
    private func records() throws -> [String:Receipt] {
        var result = [String:Receipt]()
        if fm.fileExists(atPath:receipts.path) {
            for url in try fm.contentsOfDirectory(at:receipts,includingPropertiesForKeys:nil) {
                guard UUID(uuidString:url.lastPathComponent) != nil,
                      let r = try? JSONDecoder().decode(Receipt.self,from:Data(contentsOf:url)),
                      r.moves.contains(where:{fm.fileExists(atPath:$0.trashed.path)}) else {continue}
                result[url.lastPathComponent] = r
            }
        }
        // Older releases trashed the original profile as a single KeyKeep directory.
        let old = trash.appendingPathComponent("KeyKeep")
        if fm.fileExists(atPath:old.appendingPathComponent("vault.kk").path),
           !result.values.contains(where:{$0.moves.contains(where:{$0.trashed.standardizedFileURL==old.standardizedFileURL})}) {
            result["legacy"] = Receipt(vault:VaultCatalog.original,name:"Основное",moves:[Move(source:try catalog.directory(VaultCatalog.original),trashed:old)])
        }
        return result
    }
    func items() throws -> [[String:String]] {
        try records().map { ["id":$0.key,"name":$0.value.name,"path":$0.value.moves.first?.source.path ?? ""] }
            .sorted { $0["name"]! < $1["name"]! }
    }
    func remove(_ id:String, name:String, targets:[URL]) throws {
        try fm.createDirectory(at:receipts,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let receipt=receipts.appendingPathComponent(UUID().uuidString)
        var record=Receipt(vault:id,name:name,moves:[])
        do {
            for source in targets {
                #if UI_TEST
                try fm.createDirectory(at:trash,withIntermediateDirectories:true)
                let dest=trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at:source,to:dest)
                #else
                var result:NSURL?
                try fm.trashItem(at:source,resultingItemURL:&result)
                guard let dest=result as URL? else {throw PlatformFailure()}
                #endif
                record.moves.append(Move(source:source,trashed:dest))
                try JSONEncoder().encode(record).write(to:receipt,options:.atomic)
            }
        } catch {
            for move in record.moves.reversed(){try? fm.moveItem(at:move.trashed,to:move.source)}
            throw error
        }
    }
    func restore(_ token:String) throws -> String {
        guard let r=try records()[token] else {throw PlatformFailure()}
        let legacy=try catalog.directory(VaultCatalog.original)
        var stub:URL?
        var restored=[Move]()
        do {
            for move in r.moves {
                if !fm.fileExists(atPath:move.trashed.path) {throw PlatformFailure()}
                if move.source.standardizedFileURL.path == legacy.standardizedFileURL.path && fm.fileExists(atPath:legacy.path) {
                    // The previous version recreated an empty lock directory after deleting the last vault.
                    let names=try fm.contentsOfDirectory(atPath:legacy.path)
                    guard Set(names).isSubset(of:["vault.lock",".DS_Store"]) else {throw PlatformFailure()}
                    let parked=catalog.base.appendingPathComponent("KeyKeep Empty-"+UUID().uuidString)
                    try fm.moveItem(at:legacy,to:parked)
                    stub=parked
                }
                try fm.moveItem(at:move.trashed,to:move.source)
                restored.append(move)
            }
        } catch {
            for move in restored.reversed(){try? fm.moveItem(at:move.source,to:move.trashed)}
            if let stub {try? fm.moveItem(at:stub,to:legacy)}
            throw error
        }
        if let stub {try? fm.removeItem(at:stub)}
        if token != "legacy" {try? fm.removeItem(at:receipts.appendingPathComponent(token))}
        return r.vault
    }
}
