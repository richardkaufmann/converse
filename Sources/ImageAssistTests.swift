import AppKit

@MainActor func imageAssistSelfTests(_ check: (Bool, String) -> Void) {
    do {
        // Meta's published synthetic-image-chunking conformance vector, under SAM License.
        let payload = "!!!!!(QO(0lu8?"
        let expected: [UInt8] = [1,0,0,1,0,0,0,1,1,0,0,0,0,0,0,1,0,1,1,1,1,0,0,0,1]
        check(try SAMMask.decode(payload, width: 5, height: 5) == expected, "SAM decoder matches independent official conformance raster")
        check(try SAMMask.encode(expected, width: 5, height: 5) == payload, "SAM encoder matches official canonical payload")
        check((try? SAMMask.decode(payload + "!", width: 5, height: 5)) == nil && (try? SAMMask.decode(payload, width: 2049, height: 1)) == nil, "SAM rejects trailing payload bytes and excessive dimensions")
        let text = "<0f>18<|box;h=10;x2=6;y1=3;x1=2;w=20;y2=7|><|mask;y=0;data=5,5,\(payload);x=0|>"
        let wires = try ImageAssist.segments(text, label: "object", width: 20, height: 10)
        check(wires.count == 1 && wires[0].region.x == 2 && wires[0].region.y == 3, "SAM parser handles reordered fields and sparse object IDs")
        let box = "<|box;h=10;x2=6;y1=3;x1=2;w=20;y2=7|>"
        let mask = "<|mask;y=0;data=5,5,\(payload);x=0|>"
        for (variant, name) in [
            ("<0f>,18" + box + mask, "comma before first object"),
            ("<0f>18" + mask + box, "mask before box"),
            ("<0f>18" + box + mask + "42" + mask + box, "adjacent objects without commas"),
            ("<0f>,18" + box + mask + ",42" + mask + box, "commas between objects"),
            ("<0f;version=1>18<|future;value=anything|>" + mask + "<|extra|>" + box, "frame metadata and unknown tokens"),
            ("<0f>18" + box.replacingOccurrences(of: "h=10", with: " h = 10 ;;extension=a=b;c=invalid;c=0.5") + mask, "whitespace, empty fields and optional confidence"),
        ] {
            let parsed = try ImageAssist.segments(variant, label: "object", width: 20, height: 10)
            check(parsed.first == wires.first && !parsed.isEmpty, "SAM accepts " + name + " without changing the mask")
            if variant.contains("42") { check(parsed.count == 2, "SAM retains both comma-optional object records") }
        }
        var warnings: [String] = []
        _ = try ImageAssist.segments("<0f;extra=1>18<|future|>" + box + mask, label: "object", width: 20, height: 10) { warnings.append($0) }
        check(warnings.count == 2 && !warnings.joined().contains(payload), "SAM reports ignored extensions without exposing mask data")
        for (bad, reason) in [
            ("<0f>", "no object record"),
            ("<1f>18" + box + mask, "frame 0"),
            ("<0f>,,18" + box + mask, "object ID"),
            (text + ",18" + box + mask, "duplicate object ID"),
            (text + box, "duplicate box token"),
            (text + mask, "duplicate mask token"),
            ("<0f>18" + box, "missing a box or mask"),
            (text + "oops", "object ID"),
            (text.replacingOccurrences(of: "x1=2", with: "x1=+2"), "coordinates"),
            (text.replacingOccurrences(of: "w=20", with: "w=21"), "source image"),
            (text.replacingOccurrences(of: "data=5,5,", with: "data=4,5,"), "mask dimensions"),
            (text.replacingOccurrences(of: "x=0", with: "x=1"), "offsets"),
            (text.replacingOccurrences(of: "h=10", with: "h=10;future=1;future=2"), "duplicate box field"),
            (text.replacingOccurrences(of: payload, with: "~" + payload.dropFirst()), "lossless encoding"),
            (text.replacingOccurrences(of: payload, with: payload + "!"), "length prefix"),
        ] {
            do {
                _ = try ImageAssist.segments(bad, label: "object", width: 20, height: 10)
                check(false, "SAM should reject " + reason)
            } catch {
                check(error.localizedDescription.contains(reason) && !error.localizedDescription.contains(payload), "SAM explains " + reason + " without leaking the payload")
            }
        }
        let emptyPayload = try SAMMask.encode([UInt8](repeating: 0, count: 25), width: 5, height: 5)
        check((try? ImageAssist.segments(text.replacingOccurrences(of: payload, with: emptyPayload), label: "empty", width: 20, height: 10)) == nil, "SAM never substitutes a box for an empty mask")
        let tooMany = "<0f>" + (0..<33).map { String($0) + box + mask }.joined(separator: ",")
        check((try? ImageAssist.segments(tooMany, label: "bounded", width: 20, height: 10)) == nil, "SAM object limit survives flexible token parsing")
        check((try? ImageAssist.segments(text.replacingOccurrences(of: "x1=2", with: "x1=2;x1=3"), label: "object", width: 20, height: 10)) == nil, "SAM rejects duplicate required fields")
        check(try ImageAssist.segments("", label: "none", width: 20, height: 10).isEmpty, "SAM empty completed output is a normal no-match result")
        check(try ImageAssist.deduplicated(wires + wires).count == 1, "Discovery merges duplicate masks across object concepts")
        check(try ImageAssist.discoveryConcepts("[\"person\",\"Person\",\"red truck\"]") == ["person", "red truck"], "Discovery deduplicates a bounded noun list")
        check((try? ImageAssist.discoveryConcepts("Do something else")) == nil, "Discovery rejects prose instead of sending it as a SAM prompt")
        var source = [UInt8](repeating: 0, count: 20 * 10 * 4)
        for y in 0..<10 { for x in 0..<20 {
            let i = (y * 20 + x) * 4
            source[i] = UInt8(x * 5); source[i + 1] = UInt8(y * 10); source[i + 3] = 128
        } }
        let cg = try ImageSegment.rgbaImage(source, width: 20, height: 10)
        let prepared = try ImageSegment.prepare(wires)
        let ring: [UInt8] = [1,1,1, 1,0,1, 1,1,1]
        let ringSegment = try ImageSegment(DeviceImageSegment(region: DeviceImageRegion(x: 0, y: 0, width: 3, height: 3, imageWidth: 3, imageHeight: 3), label: "ring", mask: SAMMask.encode(ring, width: 3, height: 3)))
        let boundary = ringSegment.boundary!.copy(strokingWithWidth: 0.1, lineCap: .butt, lineJoin: .miter, miterLimit: 2)
        check(boundary.contains(CGPoint(x: 0, y: 1.5)) && boundary.contains(CGPoint(x: 1, y: 1.5)) && !boundary.contains(CGPoint(x: 1.5, y: 1.5)) && !boundary.contains(CGPoint(x: 0.5, y: 0.5)), "Segment outline follows outer edges and interior holes without outlining solid interiors")
        let union = try ImageSegment.export(cg, segments: prepared + prepared, crop: false)
        let bytes = Array(union.dataProvider!.data! as Data)
        check(union.width == 20 && union.height == 10 && bytes[(3 * 20 + 2) * 4 + 3] == 128 && bytes[0] == 0 && bytes[3] == 0, "Copy keeps original canvas, masks background, and does not double alpha for overlap")
        check(bytes[(3 * 20 + 2) * 4] == 10 && bytes[(3 * 20 + 2) * 4 + 1] == 30, "Masked export preserves source pixel orientation and color")
        let crop = try ImageSegment.export(cg, segments: prepared, crop: true)
        check(try crop.width == 5 && crop.height == 5 && ImageSegment.png(crop).starts(with: [137,80,78,71]), "Add produces tight PNG cutouts with alpha")
        let roundtrip = try JSONDecoder().decode(DeviceImageAssistResult.self, from: JSONEncoder().encode(DeviceImageAssistResult(segments: wires)))
        check(roundtrip.segments == wires, "Segmentation masks survive the remote result transport")
        let api = AgentAPI(); var calls: [String] = []; var binaryEncoding = true; var done = false; var result: DeviceImageAssistResult?; var failure: String?
        api.request = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let model = body["model"] as! String; calls.append(model)
            if model == "sam-3.1" { binaryEncoding = binaryEncoding && (body["metadata"] as? [String: String])?["mask_encoding"] == "one_bit" }
            let response: [String: Any] = ["status":"completed", "output":[["content":[["type":"output_text", "text": model == "sam-3.1" ? "<0f>,18" + mask + box : "[\"object\"]"]]]]]
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let png = try ImageSegment.png(cg)
        Task { @MainActor in
            do { result = try await api.assistImage(png, request: DeviceImageAssistRequest(hash: "test", operation: "segments", epoch: 0), key: "synthetic") }
            catch { failure = error.localizedDescription }; done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(done && failure == nil && result?.segments?.count == 1 && calls == ["muse-spark-1.3", "sam-3.1"], "Blank discovery runs Spark then SAM and returns real masks independently of session model")
        done = false; calls = []
        Task { @MainActor in
            do { result = try await api.assistImage(png, request: DeviceImageAssistRequest(hash: "test", operation: "segments", epoch: 0, concept: "object"), key: "synthetic") }
            catch { failure = error.localizedDescription }; done = true
        }
        let directDeadline = Date().addingTimeInterval(10)
        while !done && Date() < directDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(binaryEncoding, "SAM requests the supported binary mask encoding")
        check(done && failure == nil && result?.segments?.first == wires.first && calls == ["sam-3.1"], "A typed concept bypasses discovery and accepts comma-prefixed mask-first responses")
    } catch { check(false, "SAM regression: " + error.localizedDescription) }
}
