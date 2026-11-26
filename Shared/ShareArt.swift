import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum SharePeriod: Equatable, Sendable {
    case year(Int)
    case quarter(Int, Int)
    case milestone(Int)

    var caption: String {
        switch self {
        case .year(let year): return L.f("card.yearLabel", year)
        case .quarter(let year, let quarter): return L.f("card.quarterLabel", year, quarter)
        case .milestone: return L.t("card.milestones")
        }
    }

    var headline: String {
        switch self {
        case .year(let year):
            let current = Calendar.journal.component(.year, from: Date())
            return L.t(year == current ? "card.yearLine" : "card.pastYearLine")
        case .quarter: return L.t("card.quarterLine")
        case .milestone: return L.t("card.milestoneLine")
        }
    }

    func counts(in journal: Journal) -> Counts {
        switch self {
        case .milestone(let level): return journal.progress.cards[level] ?? Counts()
        case .year(let year):
            let key = String(format: "%04d-", year)
            return Counts(journal.wins.filter { $0.day.raw.hasPrefix(key) })
        case .quarter(let year, let quarter):
            guard (1...4).contains(quarter), let month = LocalDay(
                raw: String(format: "%04d-%02d-01", year, (quarter - 1) * 3 + 1)) else { return Counts() }
            let range = Period.quarter.span(now: month.date(calendar: .utcJournal), calendar: .utcJournal)
            return Counts(journal.wins.filter { range.contains($0.day) })
        }
    }
}

enum ShareArt {
    static let size = CGSize(width: 1080, height: 1350)
    static let hashtags = "#bragdoc #careerwins"

    static func appURL(id: String) -> URL? {
        guard (5...20).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + id)
    }

    static func render(counts: Counts, period: SharePeriod, storeID: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let ink = UIColor(red: 31/255, green: 42/255, blue: 51/255, alpha: 1)
        let indigo = UIColor(red: 53/255, green: 61/255, blue: 139/255, alpha: 1)
        let paper = UIColor(red: 247/255, green: 245/255, blue: 240/255, alpha: 1)
        let amber = UIColor(red: 177/255, green: 107/255, blue: 26/255, alpha: 1)
        let rule = UIColor(red: 222/255, green: 219/255, blue: 211/255, alpha: 1)
        let qr = appURL(id: storeID).flatMap(qrImage)
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            let context = output.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            context.setFillColor(paper.cgColor)
            context.fill(bounds)
            let border = UIBezierPath(roundedRect: CGRect(x: 38, y: 38, width: 1004, height: 1274), cornerRadius: 35)
            UIColor.white.setFill()
            border.fill()
            indigo.withAlphaComponent(0.21).setStroke()
            border.lineWidth = 2
            border.stroke()
            let bookmark = UIBezierPath()
            bookmark.move(to: CGPoint(x: 88, y: 39))
            bookmark.addLine(to: CGPoint(x: 139, y: 39))
            bookmark.addLine(to: CGPoint(x: 139, y: 142))
            bookmark.addLine(to: CGPoint(x: 113.5, y: 121))
            bookmark.addLine(to: CGPoint(x: 88, y: 142))
            bookmark.close()
            indigo.setFill()
            bookmark.fill()
            draw(L.t("app.name") + "  ·  " + period.caption, x: 167, y: 97, width: 770, height: 65,
                 size: 33, color: indigo, weight: .semibold)
            let total = counts.total.formatted()
            let tallySize = min(216, 1180 / CGFloat(max(1, total.count)))
            draw(total, x: 88, y: 166, width: 895, height: 260,
                 size: tallySize, color: amber, weight: .bold, serif: true)
            draw(period.headline, x: 92, y: 436, width: 910, height: 123,
                 size: 61, color: ink, weight: .semibold, serif: true)
            context.setFillColor(indigo.cgColor)
            context.fill(CGRect(x: 92, y: 574, width: 896, height: 3))
            var y: CGFloat = 616
            for cat in PublicCategory.allCases {
                let count = counts.buckets[cat, default: 0]
                guard count > 0 else { continue }
                draw(cat.title, x: 94, y: y, width: 690, height: 55,
                     size: 38, color: ink, weight: .medium)
                draw(count.formatted(), x: 787, y: y, width: 200, height: 55,
                     size: 38, color: indigo, weight: .semibold, alignment: .right)
                context.setFillColor(rule.cgColor)
                context.fill(CGRect(x: 94, y: y + 62, width: 892, height: 2))
                y += 80
            }
            let box = CGRect(x: 791, y: 1056, width: 187, height: 187)
            draw(hashtags, x: 93, y: 1163, width: 640, height: 64, size: 35, color: indigo, weight: .semibold)
            if let qr {
                context.interpolationQuality = .none
                let module = floor(box.width / CGFloat(qr.width + 8))
                let side = CGFloat(qr.width) * module
                context.setFillColor(UIColor.white.cgColor)
                context.fill(box)
                UIImage(cgImage: qr).draw(in: CGRect(x: floor(box.midX - side / 2),
                    y: floor(box.midY - side / 2), width: side, height: side))
            } else {
                let placeholder = UIBezierPath(roundedRect: box, cornerRadius: 14)
                indigo.withAlphaComponent(0.06).setFill()
                placeholder.fill()
                indigo.withAlphaComponent(0.34).setStroke()
                placeholder.setLineDash([6, 5], count: 2, phase: 0)
                placeholder.lineWidth = 2
                placeholder.stroke()
                draw(L.t("card.qrPlaceholder"), x: 806, y: 1120, width: 157, height: 80,
                     size: 27, color: indigo, weight: .medium, alignment: .center)
            }
        }
    }

    private static func qrImage(_ url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }

    private static func draw(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                             size: CGFloat, color: UIColor, weight: UIFont.Weight, serif: Bool = false,
                             alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let face = serif ? font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? font : font
        (text as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: face, .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
}
