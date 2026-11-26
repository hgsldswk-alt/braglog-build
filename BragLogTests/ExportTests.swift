import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ExportTests: XCTestCase {
    func testFourFormatsUseOnlyEnteredFieldsAndStableOrder() throws {
        let day = try XCTUnwrap(LocalDay(raw: "2026-10-11"))
        let older = Win(day: day, createdAt: Date(timeIntervalSince1970: 10), action: "Earlier")
        let entry = Win(day: day, createdAt: Date(timeIntervalSince1970: 11), action: "Later\nSecond line",
                        result: "Fewer follow-ups", metric: "18 min → 7 min", project: "Private project",
                        tags: ["Confidential"], task: "Reduce back-and-forth")
        let review = ExportTemplate()
        XCTAssertTrue(review.text([older, entry]).hasPrefix("• Later\nSecond line"))
        XCTAssertTrue(review.text([older, entry]).hasSuffix("• Earlier"))
        XCTAssertTrue(review.text([entry]).contains(L.f("line.metric", entry.metric)))
        XCTAssertFalse(review.text([entry]).contains(entry.project))
        XCTAssertFalse(review.text([entry]).contains("Confidential"))
        let star = ExportTemplate(format: .star)
        XCTAssertTrue(star.text([entry]).hasPrefix(L.f("line.task", entry.task)))
        XCTAssertTrue(star.text([entry]).contains(L.f("line.starResult", entry.result + " · " + entry.metric)))
        XCTAssertEqual(star.missingSTAR([entry]), 1)
        XCTAssertEqual(ExportTemplate(format: .resume).text([entry]),
                       "• Later\nSecond line — Fewer follow-ups (18 min → 7 min)")
        XCTAssertEqual(ExportTemplate(format: .list).text([older]), "2026-10-11 ｜ Earlier")
        let extras = ExportTemplate(fields: [.date, .project], includeProject: true, includeDate: true)
        XCTAssertTrue(extras.text([entry]).hasSuffix(L.f("line.project", entry.project)))
    }

    func testTemplateCodeIsStrictAndCanonicalizesUnusedFields() throws {
        let template = ExportTemplate(fields: [.date, .project], includeProject: true, includeDate: true)
        let code = try TemplateCode.encode(template)
        XCTAssertTrue(code.hasPrefix("BLT1:"))
        XCTAssertEqual(try TemplateCode.decode(code), template)
        XCTAssertEqual(try TemplateCode.encode(ExportTemplate(format: .list, includeDate: true)),
                       try TemplateCode.encode(ExportTemplate(format: .list)))
        XCTAssertThrowsError(try TemplateCode.decode("BLT2:" + String(code.dropFirst(5))))
        XCTAssertThrowsError(try TemplateCode.decode(code + String(repeating: "x", count: 513)))
        let hostile = """
        {"version":1,"format":"review","fields":["date","project"],"includeDate":true,"includeProject":false,"notes":"private"}
        """
        XCTAssertThrowsError(try TemplateCode.decode(payload(hostile)))
        let duplicateField = """
        {"version":1,"format":"review","fields":["date","date"],"includeDate":true,"includeProject":false}
        """
        XCTAssertThrowsError(try TemplateCode.decode(payload(duplicateField)))
    }

    func testCSVQuotesFormulaPrefixRolesAndPhotosRoundTrip() throws {
        var original = Journal()
        let role = Role(title: "=Lead", organization: "A, \"B\"", start: LocalDay())
        let archived = Role(title: "Old role", archived: true)
        original.roles = [role, archived]
        original.makeCurrent(role.id)
        let metric = "  +18 min → 7 min"
        let time = Date(timeIntervalSince1970: 10_000)
        _ = try original.save(Win(action: "=SUM(A1)\nline, \"two\"", result: "'Original", metric: metric,
                                  project: "@private", tags: ["Comma, as tag", "Second"], roleID: role.id,
                                  photoID: UUID()), now: time)
        let csv = try JournalCSV.encode(original)
        XCTAssertTrue(csv.contains("'=SUM"))
        XCTAssertTrue(csv.contains("''Original"))
        let preview = try JournalCSV.preview(csv, existing: Journal())
        XCTAssertEqual(preview.validCount, 1)
        XCTAssertTrue(preview.badLines.isEmpty)
        var restored = Journal()
        XCTAssertEqual(preview.apply(to: &restored, keepDuplicates: false), 1)
        XCTAssertEqual(restored.roles, [role, archived])
        XCTAssertEqual(restored.currentRole, role.id)
        let saved = try XCTUnwrap(restored.wins.first)
        let first = try XCTUnwrap(original.wins.first)
        XCTAssertEqual(saved.id, first.id)
        XCTAssertEqual(saved.createdAt, time)
        XCTAssertEqual(saved.action, first.action)
        XCTAssertEqual(saved.result, first.result)
        XCTAssertEqual(saved.metric, metric)
        XCTAssertEqual(saved.tags, first.tags)
        XCTAssertNil(saved.photoID)
        XCTAssertEqual(restored.progress.saves, 0)
        let duplicate = try JournalCSV.preview(csv, existing: restored)
        XCTAssertEqual(duplicate.apply(to: &restored, keepDuplicates: true), 0)
    }

    func testCSVHeaderAliasesDuplicatesAndBadLineNumbers() throws {
        let source = "\u{FEFF}日期,成果標題,專案,任職\r\n2026/2/1,\"First\r\nsecond\",Ops,Lead\r\n"
            + "2026-02-01,\"First\r\nsecond\",Ops,Lead\r\n2026-02-30,Invalid,Ops,Lead\r\n"
            + "2026-02-02,\"broken\"junk,Ops,Lead\r\n2026-02-03,Good,Ops,Lead\r\n"
        let preview = try JournalCSV.preview(source, existing: Journal())
        XCTAssertEqual(preview.mapping.map(\.column), [.date, .action, .project, .role])
        XCTAssertEqual(preview.validCount, 2)
        XCTAssertEqual(preview.duplicates, 1)
        XCTAssertEqual(preview.badLines, [6, 7])
        var defaultImport = Journal()
        XCTAssertEqual(preview.apply(to: &defaultImport, keepDuplicates: false), 2)
        var keep = Journal()
        XCTAssertEqual(preview.apply(to: &keep, keepDuplicates: true), 3)
        XCTAssertEqual(keep.roles.count, 1)
        XCTAssertThrowsError(try JournalCSV.preview("name,other\nOne,Two", existing: keep))
    }

    func testCountArtIsPrivateAndQRCodeReadsAtTwoSizes() throws {
        var journal = Journal()
        let now = Calendar.journal.dateComponents([.year, .month], from: Date())
        let year = try XCTUnwrap(now.year)
        let quarter = (try XCTUnwrap(now.month) - 1) / 3 + 1
        _ = try journal.save(Win(action: "Secret title", metric: "91", project: "Secret project",
                                 tags: [PublicCategory.feedback.title, "Secret label"]))
        _ = try journal.save(Win(action: "Private", tags: ["Internal"]))
        let counts = SharePeriod.quarter(year, quarter).counts(in: journal)
        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(counts.buckets[.feedback], 1)
        XCTAssertEqual(counts.buckets[.other], 1)
        let encoded = String(decoding: try JSONEncoder().encode(counts), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Secret"))
        XCTAssertNil(ShareArt.appURL(id: ""))
        XCTAssertNil(ShareArt.appURL(id: "12345/path"))
        let art = ShareArt.render(counts: counts, period: .quarter(year, quarter), storeID: "1234567890")
        XCTAssertEqual(art.size, CGSize(width: 1080, height: 1350))
        let full = try XCTUnwrap(art.cgImage)
        let renderer = UIGraphicsImageRendererFormat()
        renderer.scale = 1
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 675), format: renderer)
            .image { _ in art.draw(in: CGRect(x: 0, y: 0, width: 540, height: 675)) }
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for image in [full, try XCTUnwrap(scaled.cgImage)] {
            let matches = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(matches.contains("https://apps.apple.com/app/id1234567890"))
        }
    }

    func testPhotoReencodingOmitsSensitiveMetadata() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let raw = NSMutableData()
        let out = try XCTUnwrap(CGImageDestinationCreateWithData(raw as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let gps = [kCGImagePropertyGPSLatitude as String: 30, kCGImagePropertyGPSLongitude as String: 70] as CFDictionary
        let exif = [kCGImagePropertyExifDateTimeOriginal as String: "2026:11:25 10:00:00",
                    kCGImagePropertyExifLensModel as String: "Private lens"] as CFDictionary
        CGImageDestinationAddImage(out, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary as String: gps, kCGImagePropertyExifDictionary as String: exif
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(out))
        let clean = try Evidence.jpeg(from: raw as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(metadata[kCGImagePropertyIPTCDictionary as String])
        let properties = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(properties?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil(properties?[kCGImagePropertyExifLensModel as String])
        XCTAssertNil(metadata[kCGImagePropertyTIFFDictionary as String].flatMap {
            ($0 as? [String: Any])?[kCGImagePropertyTIFFModel as String]
        })
    }

    private func payload(_ json: String) -> String {
        "BLT1:" + Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
