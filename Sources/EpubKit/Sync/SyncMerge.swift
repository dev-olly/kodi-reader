import Foundation

enum SyncMerge {
    static func newer(_ a: SyncEntity, _ b: SyncEntity) -> SyncEntity {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        return a.deviceID > b.deviceID ? a : b
    }

    static func resolve(local: SyncEntity, remote: SyncEntity, ancestor: SyncEntity?) throws -> [SyncEntity] {
        if local.body == remote.body, local.deleted == remote.deleted { return [newer(local, remote)] }
        if let ancestor {
            if local.body == ancestor.body, local.deleted == ancestor.deleted {
                return [try preservingBookMetadata(remote, local: local, remote: remote)]
            }
            if remote.body == ancestor.body, remote.deleted == ancestor.deleted {
                return [try preservingBookMetadata(local, local: local, remote: remote)]
            }
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
        case .reminder:
            if let ancestor {
                var a = try object(local.value(ResearchReminder.self))
                var b = try object(remote.value(ResearchReminder.self))
                var base = try object(ancestor.value(ResearchReminder.self))
                // Concurrent completion toggles use the same deterministic clock
                // tie-break as reading positions; unrelated title edits still merge.
                let completionA = a.removeValue(forKey: "completedAt")
                let completionB = b.removeValue(forKey: "completedAt")
                let completionBase = base.removeValue(forKey: "completedAt")
                var conflict = false
                var merged = mergeFields(a, b, base, conflict: &conflict)
                if !conflict {
                    let completion: Any?
                    if equal(completionA, completionB) || equal(completionA, completionBase) { completion = completionB }
                    else if equal(completionB, completionBase) { completion = completionA }
                    else { completion = newer(local, remote) == local ? completionA : completionB }
                    merged["completedAt"] = completion
                    var entity = newer(local, remote)
                    merged["modifiedAt"] = entity == local ? a["modifiedAt"] : b["modifiedAt"]
                    entity.body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
                    return [entity]
                }
            }
            let winner = newer(local, remote)
            let other = winner == local ? remote : local
            let a = try local.value(ResearchReminder.self), b = try remote.value(ResearchReminder.self)
            if a.title == b.title { return [winner] }
            return [winner, try recovered(other)]
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
            return [try preservingBookMetadata(newer(local, remote), local: local, remote: remote)]
        default: return [newer(local, remote)]
        }
    }

    private static func preservingBookMetadata(_ selected: SyncEntity, local: SyncEntity, remote: SyncEntity) throws -> SyncEntity {
        guard selected.kind == .book, !local.deleted, !remote.deleted else { return selected }
        var winner = selected
        var book = try winner.value(SyncedBook.self)
        let a = try local.value(SyncedBook.self), b = try remote.value(SyncedBook.self)
        // Preserve durable metadata when an older or metadata-only client omits it.
        book.file = book.file ?? a.file ?? b.file
        book.addedAt = [a.addedAt, b.addedAt].compactMap { $0 }.min()
        winner.body = try SyncCoding.encode(book)
        return winner
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
        case .reminder:
            var value = try source.value(ResearchReminder.self)
            value.id = id
            value.title = "Recovered version: " + value.title
            copy.body = try SyncCoding.encode(value)
        case .annotation:
            var value = try source.value(SyncedAnnotation.self)
            value.annotation.recoveredFrom = value.annotation.id
            value.annotation.id = id
            // Recovered drawings are independent copies, including when both
            // versions are exported together from the same book.
            let remapping = Dictionary(uniqueKeysWithValues: value.annotation.sketches.map {
                ($0.id, SyncCoding.uuid("recovered-sketch:\(id):\($0.id)"))
            })
            value.annotation.note = value.annotation.note.map { note in
                SketchReference.replacing(in: note) { reference in
                    SketchReference.markdown(id: remapping[reference.id] ?? reference.id, title: reference.title)
                }
            }
            for index in value.annotation.sketches.indices {
                let oldID = value.annotation.sketches[index].id
                value.annotation.sketches[index].id = remapping[oldID] ?? oldID
            }
            if var assets = value.sketches {
                for index in assets.indices { assets[index].id = remapping[assets[index].id] ?? assets[index].id }
                value.sketches = assets
            }
            let audioRemapping = Dictionary(uniqueKeysWithValues: value.annotation.audioRecordings.map {
                ($0.id, SyncCoding.uuid("recovered-audio:\(id):\($0.id)"))
            })
            value.annotation.note = value.annotation.note.map { note in
                AudioReference.replacing(in: note) { reference in
                    AudioReference.markdown(id: audioRemapping[reference.id] ?? reference.id, title: reference.title)
                }
            }
            for index in value.annotation.audioRecordings.indices {
                let oldID = value.annotation.audioRecordings[index].id
                value.annotation.audioRecordings[index].id = audioRemapping[oldID] ?? oldID
            }
            if var assets = value.audioRecordings {
                for index in assets.indices { assets[index].id = audioRemapping[assets[index].id] ?? assets[index].id }
                value.audioRecordings = assets
            }
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
