import Foundation

// Fetches the human-readable title for a URL by downloading the page and
// parsing the <meta property="og:title"> tag (preferred) or the <title>
// element. Results are cached in memory for the lifetime of the process so
// pasting the same link twice doesn't refetch.
enum LinkTitleFetcher {
    private static let cacheLock = NSLock()
    private static var cache: [URL: String] = [:]

    static func title(for url: URL) async -> String? {
        cacheLock.lock()
        let cached = cache[url]
        cacheLock.unlock()
        if let cached = cached { return cached }

        // Some sites (YouTube, Twitter, news sites) return very different
        // HTML — or block entirely — if no Safari-like User-Agent is set.
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) { return nil }

        let html: String
        if let s = String(data: data, encoding: .utf8) { html = s }
        else if let s = String(data: data, encoding: .isoLatin1) { html = s }
        else { return nil }

        // Search the full HTML. Heavy JS sites like YouTube push their
        // <meta og:title> hundreds of KB into the document, well past any
        // small prefix cap. NSRegularExpression handles megabyte-scale
        // strings in tens of milliseconds, so this is acceptable in a
        // background task.
        guard let raw = extractOGTitle(html) ?? extractTitleTag(html) else { return nil }
        let title = decodeBasicEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        cacheLock.lock()
        cache[url] = title
        cacheLock.unlock()
        return title
    }

    // MARK: – Extraction

    // <meta property="og:title" content="..."> — covers both attribute orders.
    private static func extractOGTitle(_ html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:title["']"#
        ]
        for pattern in patterns {
            if let m = firstCaptureGroup(pattern, in: html) { return m }
        }
        return nil
    }

    private static func extractTitleTag(_ html: String) -> String? {
        firstCaptureGroup(#"<title[^>]*>([\s\S]{1,500}?)</title>"#, in: html)
    }

    private static func firstCaptureGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // Manual decode of the entities titles actually carry. Avoids the
    // NSAttributedString(data: html:) main-thread requirement.
    private static func decodeBasicEntities(_ s: String) -> String {
        var r = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in named {
            r = r.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#1234; and &#x4D2;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let nsRange = NSRange(location: 0, length: (r as NSString).length)
            let matches = regex.matches(in: r, options: [], range: nsRange)
            for match in matches.reversed() {
                guard let full = Range(match.range, in: r),
                      let prefixRange = Range(match.range(at: 1), in: r),
                      let numberRange = Range(match.range(at: 2), in: r) else { continue }
                let isHex = !r[prefixRange].isEmpty
                let numStr = String(r[numberRange])
                let code: UInt32? = isHex ? UInt32(numStr, radix: 16) : UInt32(numStr, radix: 10)
                if let code = code, let scalar = Unicode.Scalar(code) {
                    r.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        return r
    }
}
