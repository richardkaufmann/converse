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
    var isDone: Bool { done == true }
}
struct ParkingLotDocument: Codable, Equatable {
    static let currentSchemaVersion = 3
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
        var path: [UUID] = []
        var section: UUID?
        for row in rows {
            guard result[row.id] == nil else { throw ParkingLotError.message("Parking Lot has duplicate row IDs.") }
            if row.heading {
                guard row.parentID == nil else { throw ParkingLotError.message("A Parking Lot heading must be at the top level.") }
                result[row.id] = Node(parentID: nil, depth: 0)
                path = [row.id]; section = row.id
                continue
            }
            let parentID = row.parentID ?? section
            if let parentID {
                guard let position = path.firstIndex(of: parentID) else {
                    throw ParkingLotError.message("A Parking Lot item must follow its parent and stay inside its section.")
                }
                path = Array(path.prefix(position + 1))
                guard path.count <= maximumDepth else { throw ParkingLotError.message("Parking Lot nesting is limited to eight levels.") }
                result[row.id] = Node(parentID: parentID, depth: path.count)
                path.append(row.id)
            } else {
                result[row.id] = Node(parentID: nil, depth: 0)
                path = [row.id]
            }
        }
        return result
    }
    static func normalized(_ rows: [ParkingLotRow]) throws -> [ParkingLotRow] {
        let hierarchy = try nodes(rows)
        return rows.map { row in
            var copy = row
            if !copy.heading { copy.parentID = hierarchy[row.id]?.parentID }
            return copy
        }
    }
    static func range(_ id: UUID, in rows: [ParkingLotRow]) -> Range<Int>? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let hierarchy = try? nodes(rows), let depth = hierarchy[id]?.depth else { return nil }
        var end = index + 1
        while end < rows.count, (hierarchy[rows[end].id]?.depth ?? 0) > depth { end += 1 }
        return index..<end
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
    static func canIndent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].heading,
              let hierarchy = try? nodes(rows), let node = hierarchy[id], node.depth < maximumDepth else { return false }
        return rows[..<index].last(where: { !$0.heading && hierarchy[$0.id]?.parentID == node.parentID }) != nil
    }
    static func canOutdent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool {
        guard let hierarchy = try? nodes(rows), let parent = hierarchy[id]?.parentID,
              let row = rows.first(where: { $0.id == parent }) else { return false }
        return !row.heading
    }
    static func changingIndent(_ id: UUID, in rows: [ParkingLotRow], deeper: Bool) -> [ParkingLotRow]? {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].heading,
              let hierarchy = try? nodes(rows), let node = hierarchy[id] else { return nil }
        var result = rows
        if deeper {
            guard canIndent(id, in: rows),
                  let previous = rows[..<index].last(where: { !$0.heading && hierarchy[$0.id]?.parentID == node.parentID }) else { return nil }
            result[index].parentID = previous.id
        } else {
            // Outliner outdent: the row stays put and adopts its following
            // siblings after its own children. No row moves.
            guard canOutdent(id, in: rows), let parent = node.parentID else { return nil }
            result[index].parentID = hierarchy[parent]?.parentID
            for later in result.indices where later > index && hierarchy[rows[later].id]?.parentID == parent { result[later].parentID = id }
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
            var parent = previous?.id, level = previousDepth
            while level >= wanted, let current = parent { parent = tree[current]?.parentID; level -= 1 }
            moving[0].parentID = parent
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
