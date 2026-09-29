import Foundation

enum SyncMerge {
    static func newer(_ a: SyncEntity, _ b: SyncEntity) -> SyncEntity {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        return a.deviceID > b.deviceID ? a : b
    }

    static func resolve(local: SyncEntity, remote: SyncEntity, ancestor: SyncEntity?) throws -> [SyncEntity] {
        if local.body == remote.body, local.deleted == remote.deleted { return [newer(local, remote)] }
        if let ancestor {
            if local.body == ancestor.body, local.deleted == ancestor.deleted { return [remote] }
            if remote.body == ancestor.body, remote.deleted == ancestor.deleted { return [local] }
        }
        if local.kind == .position { return [newer(local, remote)] }
        if local.deleted || remote.deleted {
            let deleted = local.deleted ? local : remote
            let surviving = local.deleted ? remote : local
            if !surviving.deleted, [.annotation, .chat].contains(surviving.kind) {
                return [deleted, try recovered(surviving)]
            }
            return [deleted]
        }
        switch local.kind {
        case .annotation:
            let a = try local.value(SyncedAnnotation.self), b = try remote.value(SyncedAnnotation.self)
            if let ancestor {
                let base = try ancestor.value(SyncedAnnotation.self)
                let ad = try object(a), bd = try object(b), cd = try object(base)
                var conflict = false
                let merged = mergeFields(ad, bd, cd, conflict: &conflict)
                if !conflict {
                    var entity = newer(local, remote)
                    entity.body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
                    return [entity]
                }
            }
            return [remote, try recovered(local)]
        case .chat:
            let a = try local.value(ChatThread.self), b = try remote.value(ChatThread.self)
            if a.messages.starts(with: b.messages) { return [local] }
            if b.messages.starts(with: a.messages) { return [remote] }
            return [remote, try recovered(local)]
        case .book:
            var winner = newer(local, remote)
            var book = try winner.value(SyncedBook.self)
            // A metadata-only client must never clear an already-published book file.
            let localFile = try local.value(SyncedBook.self).file
            let remoteFile = try remote.value(SyncedBook.self).file
            book.file = book.file ?? localFile ?? remoteFile
            winner.body = try SyncCoding.encode(book)
            return [winner]
        default: return [newer(local, remote)]
        }
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: SyncCoding.encode(value)) as! [String: Any]
    }

    private static func mergeFields(_ a: [String: Any], _ b: [String: Any], _ base: [String: Any], conflict: inout Bool) -> [String: Any] {
        var output = b
        for key in Set(a.keys).union(b.keys).union(base.keys) {
            if key == "modifiedAt" || key == "anchorStatus" { continue }
            let av = a[key], bv = b[key], cv = base[key]
            if let aa = av as? [String: Any], let bb = bv as? [String: Any], let cc = cv as? [String: Any] {
                output[key] = mergeFields(aa, bb, cc, conflict: &conflict)
            } else if equal(av, bv) || equal(av, cv) { output[key] = bv }
            else if equal(bv, cv) { output[key] = av }
            else { conflict = true }
        }
        return output
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil, b == nil { return true }
        guard let a, let b else { return false }
        return (a as? NSObject)?.isEqual(b) == true
    }

    static func recovered(_ source: SyncEntity) throws -> SyncEntity {
        let id = SyncCoding.uuid("recovered:\(source.id):\(SyncCoding.hash(source.body))")
        var copy = source
        switch source.kind {
        case .annotation:
            var value = try source.value(SyncedAnnotation.self)
            value.annotation.recoveredFrom = value.annotation.id
            value.annotation.id = id
            copy.body = try SyncCoding.encode(value)
        case .chat:
            var value = try source.value(ChatThread.self)
            value.recoveredFrom = value.id; value.id = id
            value.title = "Recovered version: " + value.title
            copy.body = try SyncCoding.encode(value)
        default: return copy
        }
        copy.id = "\(copy.kind.rawValue):\(copy.bookID):\(id.uuidString)"
        copy.deleted = false
        return copy
    }
}
