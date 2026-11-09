import Foundation

// Native Undo reverses only the user's own edits. An entry keeps the rows just
// before and after that edit and applies their difference to the CURRENT rows,
// by row ID, so session, agent and device changes saved since are preserved.
// A row both the entry and a later writer changed is a conflict: nothing is
// saved, and the newer change is never replaced by an old document.
enum ParkingLotUndo {
    struct Conflict: Error {
        var author: String?
        var deleted = false
        var structure = false
        func message(redo: Bool) -> String {
            let verb = redo ? "Can't redo: " : "Can't undo: "
            if structure { return verb + "the outline around this item changed since." }
            if deleted { return verb + (author ?? "another writer") + " deleted this item since." }
            return verb + (author ?? "another writer") + " changed this item since."
        }
    }
    /// `current` with the change from `base` to `target` applied.
    static func applying(from base: [ParkingLotRow], to target: [ParkingLotRow], onto current: [ParkingLotRow]) throws -> [ParkingLotRow] {
        let baseByID = byID(base), targetByID = byID(target), currentByID = byID(current)
        let oursContent = contentChanges(baseByID, targetByID), theirsContent = contentChanges(baseByID, currentByID)
        let oursMoved = moved(base, target, keeping: theirsContent)
        let theirsMoved = moved(base, current, keeping: oursContent.union(oursMoved))
        let ours = oursContent.union(oursMoved), theirs = theirsContent.union(theirsMoved)
        let overlap = ours.intersection(theirs).filter { id in
            // Both writers made the identical change: nothing to protect.
            targetByID[id] != currentByID[id] || oursMoved.contains(id) || theirsMoved.contains(id)
        }
        if let id = (target + base + current).map(\.id).first(where: overlap.contains) {
            throw conflict(id, base: baseByID, current: currentByID)
        }
        var merged = currentByID
        for id in oursContent { merged[id] = targetByID[id] }
        // Rows keep their current place unless this entry restores, reparents or moves them.
        let placing = Set(merged.keys.filter { id in
            currentByID[id] == nil || currentByID[id]?.parentID != merged[id]?.parentID || oursMoved.contains(id)
        })
        var lists: [UUID?: [UUID]] = [:]
        for row in current where merged[row.id] != nil && !placing.contains(row.id) { lists[row.parentID, default: []].append(row.id) }
        let targetLists = siblings(target)
        for row in target where placing.contains(row.id) {
            let order = targetLists[row.parentID] ?? [], at = order.firstIndex(of: row.id)!
            var list = lists[row.parentID] ?? []
            if let previous = order[..<at].last(where: list.contains), let index = list.firstIndex(of: previous) { list.insert(row.id, at: index + 1) }
            else if let next = order[(at + 1)...].first(where: list.contains), let index = list.firstIndex(of: next) { list.insert(row.id, at: index) }
            else { list.append(row.id) }
            lists[row.parentID] = list
        }
        var rows: [ParkingLotRow] = [], emitted = Set<UUID>()
        func emit(_ parent: UUID?) {
            for id in lists[parent] ?? [] where emitted.insert(id).inserted { rows.append(merged[id]!); emit(id) }
        }
        emit(nil)
        // A row whose parent is gone: an entry restored it under a deleted parent,
        // or another writer added it under a row this entry removes.
        if let orphan = (current + target).first(where: { merged[$0.id] != nil && !emitted.contains($0.id) }) {
            let parent = merged[orphan.id]?.parentID
            if currentByID[orphan.id] == nil, let parent, currentByID[parent] == nil { throw Conflict(deleted: true) }
            throw conflict(orphan.id, base: baseByID, current: currentByID)
        }
        guard (try? ParkingLotTree.normalized(rows)) == rows else { throw Conflict(structure: true) }
        return rows
    }
    /// The Edit menu name for a user edit that did not name itself.
    static func actionName(_ before: [ParkingLotRow], _ after: [ParkingLotRow]) -> String {
        let old = byID(before), new = byID(after)
        func textOnly(_ row: ParkingLotRow) -> Bool {
            guard var previous = old[row.id] else { return true }
            previous.text = row.text; return previous == row
        }
        if Set(old.keys).isSubset(of: new.keys) && after.allSatisfy(textOnly) {
            return after.contains { old[$0.id] == nil && !$0.text.isEmpty } || old.count == new.count ? "Typing" : "New Item"
        }
        if Set(new.keys).isSubset(of: old.keys) && after.allSatisfy({ old[$0.id] == $0 }) { return "Delete" }
        if Set(old.keys) == Set(new.keys) && after.allSatisfy({ var row = $0; row.parentID = old[$0.id]?.parentID; return old[$0.id] == row }) { return "Move" }
        return "Edit Parking Lot"
    }
    private static func byID(_ rows: [ParkingLotRow]) -> [UUID: ParkingLotRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private static func contentChanges(_ a: [UUID: ParkingLotRow], _ b: [UUID: ParkingLotRow]) -> Set<UUID> {
        Set(a.keys).symmetricDifference(b.keys).union(a.keys.filter { id in b[id].map { $0 != a[id] } ?? false })
    }
    private static func siblings(_ rows: [ParkingLotRow]) -> [UUID?: [UUID]] {
        rows.reduce(into: [:]) { lists, row in lists[row.parentID, default: []].append(row.id) }
    }
    /// Rows whose order among unchanged-parent siblings differs. Ties prefer
    /// keeping `keeping` in place, so an edit to one row never looks like a move.
    private static func moved(_ a: [ParkingLotRow], _ b: [ParkingLotRow], keeping: Set<UUID>) -> Set<UUID> {
        let parentsA = Dictionary(a.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        let parentsB = Dictionary(b.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        let listsB = siblings(b)
        var result = Set<UUID>()
        for (parent, list) in siblings(a) {
            let x = list.filter { parentsB[$0] == .some(parent) }
            let y = (listsB[parent] ?? []).filter { parentsA[$0] == .some(parent) }
            guard x != y else { continue }
            let weight = { (id: UUID) in keeping.contains(id) ? x.count + 1 : 1 }
            var table = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
            for i in stride(from: x.count - 1, through: 0, by: -1) {
                for j in stride(from: y.count - 1, through: 0, by: -1) {
                    table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + weight(x[i]) : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0, kept = Set<UUID>()
            while i < x.count && j < y.count {
                if x[i] == y[j] { kept.insert(x[i]); i += 1; j += 1 }
                else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
            }
            result.formUnion(Set(x).subtracting(kept))
        }
        return result
    }
    private static func conflict(_ id: UUID, base: [UUID: ParkingLotRow], current: [UUID: ParkingLotRow]) -> Conflict {
        guard let row = current[id] else { return Conflict(deleted: true) }
        let notes = row.notes ?? []
        if notes.count > (base[id]?.notes ?? []).count, let note = notes.last { return Conflict(author: note.author) }
        return Conflict(author: row.editedBy)
    }
}
