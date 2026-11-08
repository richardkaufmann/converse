import Foundation

/// Uses the existing .converse interchange format, including content-addressed images.
enum LotPortableExport {
    private struct App: Encodable { var version: String; var build: String; var platform: String }
    private struct Scrub: Encodable { var applied: Bool; var counts: [String: Int] }
    private struct Attachment: Encodable { var name: String; var mime: String; var data: Data }
    private struct Lot: Encodable { var exportID: UUID; var name: String; var document: ParkingLotDocument }
    private struct Envelope: Encodable {
        var format = "converse-export"
        var version = 1
        var exportedAt: String
        var app: App
        var scrub: Scrub
        var sessions: [String] = []
        var parkingLots: [Lot]
        var attachments: [String: Attachment]
    }
    static func encode(_ snapshot: LotSnapshot, includeImages: Bool, scrubber: inout ExportScrubber?,
                       version: String, build: String, imageData: (String) throws -> Data) throws -> Data {
        try snapshot.validate()
        var document = snapshot.document
        var attachments: [String: Attachment] = [:]
        var bytes = 0
        func clean(_ text: String) -> String { scrubber == nil ? text : scrubber!.scrub(text) }
        for index in document.rows.indices {
            document.rows[index].text = clean(document.rows[index].text)
            document.rows[index].editedBy = document.rows[index].editedBy.map(clean)
            document.rows[index].notes = document.rows[index].notes?.map { note in
                var note = note; note.author = clean(note.author); note.text = clean(note.text); return note
            }
            if includeImages {
                for hash in document.rows[index].images ?? [] where attachments[hash] == nil {
                    let data = try imageData(hash)
                    guard data.count <= 25_000_000, DeviceBlob.verify(data, sha256Hex: hash) else { throw ParkingLotError.message("An image could not be verified for export.") }
                    bytes += data.count
                    guard bytes <= 140_000_000 else { throw ParkingLotError.message("The images exceed the export size limit. Export without images or use a smaller lot.") }
                    attachments[hash] = Attachment(name: "image-" + hash.prefix(12) + ".png", mime: "image/png", data: data)
                }
            } else { document.rows[index].images = nil }
        }
        document.schemaVersion = ParkingLotDocument.schemaVersion(for: document.rows)
        let name = clean(snapshot.name)
        let envelope = Envelope(exportedAt: ISO8601DateFormatter().string(from: Date()),
                                app: App(version: version, build: build, platform: "iOS"),
                                scrub: Scrub(applied: scrubber != nil, counts: scrubber?.counts ?? [:]),
                                parkingLots: [Lot(exportID: UUID(), name: name, document: document)], attachments: attachments)
        let data = try LotEditing.encoded(envelope)
        guard data.count <= 200_000_000 else { throw ParkingLotError.message("The export exceeds the file size limit.") }
        return data
    }
}
