import Foundation

enum ParkingLotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ParkingLotTag: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple
    var lightHex: String {
        switch self {
        case .red: return "#B42332"
        case .orange: return "#A34600"
        case .yellow: return "#806000"
        case .green: return "#16733D"
        case .blue: return "#1762B8"
        case .purple: return "#8045B5"
        }
    }
    var darkHex: String {
        switch self {
        case .red: return "#FF8890"
        case .orange: return "#FFB56B"
        case .yellow: return "#E9CB65"
        case .green: return "#79D99C"
        case .blue: return "#83BBFF"
        case .purple: return "#C7A0F5"
        }
    }
}

struct ParkingLotNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var author: String
    var text: String
}
struct ParkingLotRow: Codable, Equatable, Identifiable {
    var id = UUID()
    var heading: Bool
    var text: String
    var editedBy: String? = nil
    var notes: [ParkingLotNote]? = nil
    var images: [String]? = nil
    var done: Bool? = nil
    // Nil in an old document means the nearest preceding heading. Rows stay
    // in preorder; this ID gives nested items a stable parent across edits.
    var parentID: UUID? = nil
    var tag: ParkingLotTag? = nil
    // Extra outline levels beyond one below the parent, for an item shown deeper
    // than the row before it allows. Nil on every row that does not need it.
    var indent: Int? = nil
    var isDone: Bool { done == true }
}
struct ParkingLotDocument: Codable, Equatable {
    static let currentSchemaVersion = 4
    /// The lowest version that keeps every field in `rows`: older builds refuse
    /// a newer document rather than silently dropping tags or flexible indents.
    static func schemaVersion(for rows: [ParkingLotRow]) -> Int {
        rows.contains { ($0.indent ?? 0) > 0 } ? 4 : rows.contains { $0.tag != nil } ? 3 : 2
    }
    var schemaVersion: Int = currentSchemaVersion
    var revision: Int = 0
    var rows: [ParkingLotRow] = []
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, rows }
    init(revision: Int = 0, rows: [ParkingLotRow] = []) {
        self.revision = revision; self.rows = rows
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "This Parking Lot was saved by a newer version of Converse.")
        }
        revision = try container.decode(Int.self, forKey: .revision)
        rows = try container.decode([ParkingLotRow].self, forKey: .rows)
    }
}
// All rows remain one ordered array, so old lots and existing export packages
// can be read without a structural migration. Children follow their parent.
enum ParkingLotTree {
    struct Node { let parentID: UUID?; let depth: Int }
    static let maximumDepth = 8
    /// Outline labels by level: 1, 2, 3 → a, b, c → i, ii, iii, then repeat.
    static func label(_ number: Int, depth: Int) -> String {
        let n = max(1, number)
        switch (max(1, depth) - 1) % 3 {
        case 1: return letters(n)
        case 2: return roman(n)
        default: return String(n)
        }
    }
    /// a…z, then aa, ab… (like spreadsheet columns).
    static func letters(_ number: Int) -> String {
        var n = number, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(UInt8(97 + n % 26))) + result; n /= 26 }
        return result
    }
    static func roman(_ number: Int) -> String {
        guard number < 4000 else { return String(number) }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = number, result = ""
        for (value, symbol) in table { while n >= value { result += symbol; n -= value } }
        return result
    }
    static func nodes(_ rows: [ParkingLotRow]) throws -> [UUID: Node] {
        var result: [UUID: Node] = [:]
        var path: [(id: UUID, depth: Int)] = []
        var section: UUID?
        for row in rows {
            guard result[row.id] == nil else { throw ParkingLotError.message("Parking Lot has duplicate row IDs.") }
            let indent = row.indent ?? 0
            guard indent >= 0, indent < maximumDepth, !row.heading || indent == 0 else {
                throw ParkingLotError.message("A Parking Lot row has an invalid indent.")
            }
            if row.heading {
                guard row.parentID == nil else { throw ParkingLotError.message("A Parking Lot heading must be at the top level.") }
                result[row.id] = Node(parentID: nil, depth: 0)
                path = [(row.id, 0)]; section = row.id
                continue
            }
            let parentID = row.parentID ?? section
            if let parentID {
                guard let position = path.firstIndex(where: { $0.id == parentID }) else {
                    throw ParkingLotError.message("A Parking Lot item must follow its parent and stay inside its section.")
                }
                let depth = path[position].depth + 1 + indent
                guard depth <= maximumDepth else { throw ParkingLotError.message("Parking Lot nesting is limited to eight levels.") }
                path = Array(path.prefix(position + 1))
                result[row.id] = Node(parentID: parentID, depth: depth)
                path.append((row.id, depth))
            } else {
                result[row.id] = Node(parentID: nil, depth: indent)
                path = [(row.id, indent)]
            }
        }
        return result
    }
    static func normalized(_ rows: [ParkingLotRow]) throws -> [ParkingLotRow] {
        let hierarchy = try nodes(rows)
        return rows.map { row in
            var copy = row
            if !copy.heading { copy.parentID = hierarchy[row.id]?.parentID }
            if copy.indent == 0 { copy.indent = nil }
            return copy
        }
    }
    /// The row and its descendants. Depth alone cannot decide this: a later row
    /// can be indented deeper without being nested under this one.
    static func range(_ id: UUID, in rows: [ParkingLotRow]) -> Range<Int>? {
        guard let index = rows.firstIndex(where: { $0.id == id }), let hierarchy = try? nodes(rows) else { return nil }
        var members: Set<UUID> = [id], end = index + 1
        while end < rows.count, let parent = hierarchy[rows[end].id]?.parentID, members.contains(parent) {
            members.insert(rows[end].id); end += 1
        }
        return index..<end
    }
    /// Each item's number among its siblings at the same depth. A shallower
    /// sibling ends a deeper run, so that run restarts if it resumes.
    static func numbers(_ rows: [ParkingLotRow]) -> [UUID: Int] {
        guard let hierarchy = try? nodes(rows) else { return [:] }
        var counters: [UUID?: [Int: Int]] = [:], result: [UUID: Int] = [:]
        for row in rows where !row.heading {
            guard let node = hierarchy[row.id] else { continue }
            var counts = (counters[node.parentID] ?? [:]).filter { $0.key <= node.depth }
            counts[node.depth, default: 0] += 1
            counters[node.parentID] = counts
            result[row.id] = counts[node.depth]
        }
        return result
    }
    /// The deepest row on the path before `index` that can parent an item at
    /// `depth`, with the extra levels the item needs to reach that depth.
    static func placement(at index: Int, depth: Int, in rows: [ParkingLotRow], hierarchy: [UUID: Node]) -> (parent: UUID?, indent: Int?) {
        var candidate = index > 0 ? rows[index - 1].id : nil
        while let id = candidate, (hierarchy[id]?.depth ?? 0) >= depth { candidate = hierarchy[id]?.parentID }
        let extra = depth - (candidate.flatMap { hierarchy[$0]?.depth }.map { $0 + 1 } ?? 0)
        return (candidate, extra > 0 ? extra : nil)
    }
    static func parentForInsertion(at index: Int, in rows: [ParkingLotRow], heading: Bool) -> UUID? {
        guard !heading else { return nil }
        if index < rows.count, !rows[index].heading {
            return (try? nodes(rows))?[rows[index].id]?.parentID
        }
        return rows.prefix(index).last(where: \.heading)?.id
    }
    static func depth(of id: UUID, in rows: [ParkingLotRow]) -> Int {
        (try? nodes(rows))?[id]?.depth ?? 0
    }
    static func canIndent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool { changingIndent(id, in: rows, deeper: true) != nil }
    /// Every item can outdent: a top-level item becomes a heading.
    static func canOutdent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool { rows.contains { $0.id == id && !$0.heading } }
    static func changingIndent(_ id: UUID, in rows: [ParkingLotRow], deeper: Bool) -> [ParkingLotRow]? {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].heading,
              let hierarchy = try? nodes(rows), let node = hierarchy[id] else { return nil }
        var result = rows
        if deeper {
            // The item goes one level deeper under whatever precedes it; with no
            // row at the level above, it keeps its parent and records the gap.
            let target = placement(at: index, depth: node.depth + 1, in: rows, hierarchy: hierarchy)
            result[index].parentID = target.parent; result[index].indent = target.indent
        } else if (rows[index].indent ?? 0) > 0 {
            result[index].indent = rows[index].indent == 1 ? nil : rows[index].indent! - 1
        } else {
            // Outliner outdent: the row stays put and adopts its following
            // siblings after its own children. No row moves.
            let parent = node.parentID, topLevel = parent.map { id in rows.contains { $0.id == id && $0.heading } } ?? true
            if topLevel {
                result[index].heading = true; result[index].parentID = nil; result[index].indent = nil
            } else {
                let target = placement(at: index, depth: node.depth - 1, in: rows, hierarchy: hierarchy)
                result[index].parentID = target.parent; result[index].indent = target.indent
            }
            for later in (index + 1)..<rows.count {
                if rows[later].heading { break }
                if hierarchy[rows[later].id]?.parentID == parent { result[later].parentID = id }
            }
        }
        return (try? nodes(result)) == nil ? nil : result
    }
    /// Moves an item's subtree before `destination` (nil: the end) at an outline
    /// depth. Like an outliner drop, it may nest under the row before the drop
    /// point or anything back out to the next row's level; nil keeps the row
    /// before's level. Headings move whole sections between sections only.
    static func moving(_ id: UUID, before destination: UUID?, depth: Int? = nil, in rows: [ParkingLotRow]) -> [ParkingLotRow]? {
        guard let range = range(id, in: rows), let hierarchy = try? nodes(rows) else { return nil }
        var moving = Array(rows[range]), remaining = rows
        remaining.removeSubrange(range)
        let index: Int
        if destination == id { index = range.lowerBound }
        else if let destination {
            guard let found = remaining.firstIndex(where: { $0.id == destination }) else { return nil }
            index = found
        } else { index = remaining.count }
        if moving[0].heading {
            guard index == remaining.count || remaining[index].heading else { return nil }
        } else {
            guard let tree = try? nodes(remaining) else { return nil }
            let previous = index > 0 ? remaining[index - 1] : nil
            let previousDepth = previous.map { $0.heading ? 0 : tree[$0.id]?.depth ?? 1 } ?? 0
            let base = hierarchy[id]?.depth ?? 1
            let height = moving.map { (hierarchy[$0.id]?.depth ?? base) - base }.max() ?? 0
            let next = index < remaining.count && !remaining[index].heading ? tree[remaining[index].id]?.depth ?? 1 : 1
            let deepest = min(previousDepth + 1, maximumDepth - height)
            guard next <= deepest else { return nil }
            let wanted = min(max(depth ?? max(1, previousDepth), next), deepest)
            let target = placement(at: index, depth: wanted, in: remaining, hierarchy: tree)
            moving[0].parentID = target.parent; moving[0].indent = target.indent
        }
        remaining.insert(contentsOf: moving, at: index)
        return (try? nodes(remaining)) == nil ? nil : remaining
    }
    /// Selected descendants travel with their selected ancestor exactly once.
    /// Reverse outdents so each item adopts only the siblings after it that
    /// are not themselves selected; selected siblings stay siblings.
    static func changingIndent(_ ids: Set<UUID>, in rows: [ParkingLotRow], deeper: Bool) -> [ParkingLotRow]? {
        guard !ids.isEmpty, let hierarchy = try? nodes(rows),
              ids.allSatisfy({ id in rows.contains { $0.id == id && !$0.heading } }) else { return nil }
        let roots = rows.filter { row in
            guard ids.contains(row.id) else { return false }
            var parent = hierarchy[row.id]?.parentID
            while let id = parent {
                if ids.contains(id) { return false }
                parent = hierarchy[id]?.parentID
            }
            return true
        }.map(\.id)
        var result = rows
        for id in deeper ? roots : Array(roots.reversed()) {
            guard let next = changingIndent(id, in: result, deeper: deeper) else { return nil }
            result = next
        }
        return result
    }
}
struct ParkingLotEdits: Codable {
    struct Operation: Codable {
        var action: String
        var id: UUID?
        var text: String?
        var heading: Bool?
        var before: UUID?
        var done: Bool? = nil
        var parentID: UUID? = nil
        var tag: String? = nil
    }
    var revision: Int
    var operations: [Operation]
    var lotID: UUID? = nil
}
