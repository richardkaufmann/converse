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
            let response: [String: Any] = ["status":"completed", "output":[["content":[["type":"output_text", "text": model == "sam-3.1" ? text : "[\"object\"]"]]]]]
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
        check(done && calls == ["sam-3.1"], "A typed concept bypasses discovery")
    } catch { check(false, "SAM regression: " + error.localizedDescription) }
}
