import AppKit

func lotPortableExportSelfTests(_ check: (Bool, String) -> Void) {
    do {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        if let bytes = bitmap.bitmapData { memset(bytes, 255, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        let png = bitmap.representation(using: .png, properties: [:])!
        let hash = DeviceBlob.sha256Hex(png)
        let heading = ParkingLotRow(heading: true, text: "Roadmap")
        let row = ParkingLotRow(heading: false, text: "Contact me@example.com", notes: [ParkingLotNote(author: "Test Person", text: "Keep this comment")], images: [hash], done: true, parentID: heading.id, tag: .purple)
        let snapshot = try LotSnapshot(globalID: "fixture", homeBoot: 1, leaseEpoch: 1, name: "Mobile lot", document: { var document = ParkingLotDocument(revision: 17, rows: [heading, row]); document.schemaVersion = 3; return document }())
        var none: ExportScrubber?
        let data = try LotPortableExport.encode(snapshot, includeImages: true, scrubber: &none, version: "test", build: "0", imageData: { _ in png })
        let imported = try ConverseExchange.decode(data)
        check(imported.document.parkingLots.first?.document == snapshot.document && imported.images[hash] != nil, "Mobile .converse export imports on Mac with hierarchy, tags, Done, comments and images intact")
        var scrubber: ExportScrubber? = ExportScrubber(context: .init(fullName: "Test Person"))
        let privateData = try LotPortableExport.encode(snapshot, includeImages: true, scrubber: &scrubber, version: "test", build: "0", imageData: { _ in png })
        let scrubbed = try ConverseExchange.decode(privateData)
        let scrubbedRow = scrubbed.document.parkingLots[0].document.rows[1]
        check(!scrubbedRow.text.contains("me@example.com") && scrubbedRow.notes?.first?.author != "Test Person" && scrubbed.document.scrub.applied && !scrubbed.document.scrub.counts.isEmpty,
              "Mobile export uses the existing optional secret and personal-information scrubber")
        let withoutImages = try LotPortableExport.encode(snapshot, includeImages: false, scrubber: &none, version: "test", build: "0", imageData: { _ in throw ParkingLotError.message("Images were not requested") })
        let textOnly = try ConverseExchange.decode(withoutImages)
        check(textOnly.images.isEmpty && textOnly.document.parkingLots[0].document.rows[1].images == nil && textOnly.document.parkingLots[0].document.rows[1].tag == .purple,
              "Explicit image exclusion preserves all other exported lot fields")
        do {
            _ = try LotPortableExport.encode(snapshot, includeImages: true, scrubber: &none, version: "test", build: "0", imageData: { _ in Data("wrong bytes".utf8) })
            check(false, "Export must reject incorrect image bytes")
        } catch { check(true, "Mobile export refuses a damaged image instead of silently omitting it") }
    } catch { check(false, "Mobile export fixture: " + error.localizedDescription) }
}
