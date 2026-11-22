import Foundation

/// Decides an item type from a CapturePayload.
///
/// Priority: PDF > image > URL > HTML > plain text. URL wins over text because
/// browsers put both on the pasteboard for a dragged link. Plain text that is
/// only an http(s) URL (or a schemeless web address like www.x.com/…) becomes a link.
public enum TypeDetector {
    public static let maxTitleLength = 80

    public static func detect(_ payload: CapturePayload) throws -> DetectedCapture {
        if let pdf = payload.pdfData, !pdf.isEmpty {
            return DetectedCapture(
                type: .pdf, title: payload.suggestedName.map(stripExtension) ?? "PDF document",
                content: "", url: nil, data: pdf, fileExtension: "pdf", meta: [:])
        }
        if let image = payload.imageData, !image.isEmpty {
            let ext = DataSniffer.imageExtension(image) ?? "img"
            var meta: Meta = ["format": .string(ext)]
            if let source = payload.url, !source.isFileURL { meta["source_url"] = .string(source.absoluteString) }
            return DetectedCapture(
                type: .image, title: payload.suggestedName.map(stripExtension) ?? "Image",
                content: "", url: payload.url.flatMap { $0.isFileURL ? nil : $0.absoluteString },
                data: image, fileExtension: ext, meta: meta)
        }
        if let url = payload.url {
            guard !url.isFileURL else { throw MiniBrainError.unsupportedPayload }
            return link(url, title: payload.suggestedName ?? payload.plainText.flatMap(nonURLTitle))
        }
        if let html = payload.html, !html.isEmpty {
            let text = payload.plainText.flatMap { $0.isBlank ? nil : $0 } ?? HTMLText.plainText(from: html)
            if let source = HTMLText.sourceURL(in: html) {
                return DetectedCapture(
                    type: .text, title: title(fromText: text), content: text,
                    url: source.absoluteString, data: nil, fileExtension: nil,
                    meta: ["source": "html", "host": .string(source.host ?? "")])
            }
            if let onlyURL = singleURL(in: text) { return link(onlyURL, title: nil) }
            guard !text.isBlank else { throw MiniBrainError.emptyPayload }
            return DetectedCapture(
                type: .text, title: title(fromText: text), content: text, url: nil,
                data: nil, fileExtension: nil, meta: ["source": "html"])
        }
        if let text = payload.plainText {
            guard !text.isBlank else { throw MiniBrainError.emptyPayload }
            if let onlyURL = singleURL(in: text) { return link(onlyURL, title: nil) }
            return DetectedCapture(
                type: .text, title: title(fromText: text), content: text, url: nil,
                data: nil, fileExtension: nil, meta: [:])
        }
        throw payload.isEmpty ? MiniBrainError.emptyPayload : MiniBrainError.unsupportedPayload
    }

    static func link(_ url: URL, title: String?) -> DetectedCapture {
        let host = url.host ?? ""
        var fallback = host
        let path = url.path
        if !path.isEmpty, path != "/" { fallback += path }
        return DetectedCapture(
            type: .link, title: (title?.isBlank == false ? title! : fallback).truncated(maxTitleLength),
            content: "", url: url.absoluteString, data: nil, fileExtension: nil,
            meta: ["host": .string(host)])
    }

    /// Returns the URL when `text` is exactly one http(s) URL — or one
    /// web address typed without a scheme ("www.imdb.com/title/tt1"), which
    /// gets https://.
    public static func singleURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty {
            return url
        }
        return schemelessWebURL(trimmed)
    }

    /// Common web TLDs: a bare "name.tld" (no www., no path) only counts as a
    /// link for these, so file names like "notes.txt" / "README.md" stay text.
    static let commonWebTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov", "me", "info", "biz", "tv",
        "xyz", "sh", "gg", "fm", "ly", "us", "uk", "in", "de", "fr", "jp", "ca", "au", "nl", "eu", "ch",
        "se", "es", "it", "br", "kr", "tech", "site", "blog", "page", "news", "so", "to",
    ]

    /// "www.x.com/…", "x.com/path", or "x.<common tld>" → https URL; else nil.
    static func schemelessWebURL(_ text: String) -> URL? {
        guard !text.contains("://"), !text.contains("@"), let first = text.first, first.isLetter || first.isNumber
        else { return nil }
        let hostEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let host = text[..<hostEnd].lowercased()
        let hasPath = hostEnd != text.endIndex
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }), let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        guard host.hasPrefix("www.") || hasPath || commonWebTLDs.contains(String(tld)) else { return nil }
        guard let url = URL(string: "https://" + text), url.host != nil else { return nil }
        return url
    }

    static func nonURLTitle(_ text: String) -> String? {
        singleURL(in: text) == nil && !text.isBlank ? title(fromText: text) : nil
    }

    public static func title(fromText text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.truncated(maxTitleLength)
    }

    static func stripExtension(_ name: String) -> String {
        let ns = name as NSString
        return ns.pathExtension.isEmpty ? name : ns.deletingPathExtension
    }
}

/// Magic-number sniffing for stored blobs.
public enum DataSniffer {
    public static func imageExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: Array("GIF8".utf8)) { return "gif" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46][...], b[8..<12] == [0x57, 0x45, 0x42, 0x50][...] { return "webp" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }

    public static func isPDF(_ data: Data) -> Bool { data.prefix(4) == Data("%PDF".utf8) }
}

/// Lightweight HTML → text and source-URL extraction (no WebKit).
public enum HTMLText {
    public static func sourceURL(in html: String) -> URL? {
        let patterns = [
            #"(?m)^SourceURL:\s*(\S+)"#,
            #"<base\s+[^>]*href\s*=\s*["']([^"']+)["']"#,
            #"<link\s+[^>]*rel\s*=\s*["']canonical["'][^>]*href\s*=\s*["']([^"']+)["']"#,
            #"<meta\s+[^>]*property\s*=\s*["']og:url["'][^>]*content\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html),
                  let url = URL(string: decodeEntities(String(html[r]))),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            return url
        }
        return nil
    }

    public static func plainText(from html: String) -> String {
        var s = html
        // Drop CF_HTML header lines and non-content blocks.
        s = s.replacingOccurrences(of: #"(?m)^(Version|StartHTML|EndHTML|StartFragment|EndFragment|SourceURL):.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<!--.*?-->"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // Numeric entities.
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func truncated(_ max: Int) -> String {
        count <= max ? self : String(prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
