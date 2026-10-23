import Foundation

public enum VocabularyCorrector {
    /// High-confidence phonetic variants commonly emitted by small Whisper
    /// models. Only apply an alias when its canonical spelling is in the user's
    /// vocabulary; ordinary phrases such as "word press" can otherwise be valid.
    private static let aliases: [(pattern: String, replacement: String)] = [
        (#"\bwisp(?:s)?\b"#, "Whisp"),
        (#"\bgo[\s-]*high[\s-]*level\b"#, "GoHighLevel"),
        (#"\bdeep[\s-]*(?:seek|seag)\b"#, "DeepSeek"),
        (#"\bn\s*(?:8|eight)\s*n\b"#, "n8n"),
        (#"\bdata\s+for\s+s\.?\s*e\.?\s*o\.?\b"#, "DataForSEO"),
        (#"\bsem\s*[- ]?rush\b"#, "Semrush"),
        (#"\bah\s*[- ]?refs\b"#, "Ahrefs"),
        (#"\bsmart\s*[- ]?lead\b"#, "Smartlead"),
        (#"\bsuper\s*[- ]?base\b"#, "Supabase"),
        (#"\bver\s*[- ]?sell\b|\bversel\b"#, "Vercel"),
        (#"\bword\s*[- ]?press\b"#, "WordPress"),
        (#"\bweb\s*[- ]?flow\b"#, "Webflow"),
        (#"\bmail\s*[- ]?chimp\b"#, "Mailchimp"),
        (#"\bactive\s*[- ]?campaign\b"#, "ActiveCampaign"),
        (#"\bwoo\s*[- ]?commerce\b"#, "WooCommerce"),
        (#"\btick\s*[- ]?tock\s+ads\b"#, "TikTok Ads"),
        (#"\bchat\s*g\.?\s*p\.?\s*t\.?\b"#, "ChatGPT"),
        (#"\bopen\s+a\.?\s*i\.?\b"#, "OpenAI"),
        (#"\bnext\s*j\.?\s*s\.?\b"#, "Next.js"),
        (#"\btype\s*[- ]?script\b"#, "TypeScript"),
        (#"\btailwind\s+c\.?\s*s\.?\s*s\.?\b"#, "Tailwind CSS"),
        (#"\bg\.?\s*a\.?\s*(?:4|four)\b"#, "GA4"),
    ]

    public static func correct(_ raw: String, vocabulary: [String]) -> String {
        var text = raw
        let known = Set(vocabulary.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        for alias in aliases where known.contains(alias.replacement.lowercased()) {
            text = replacing(alias.pattern, in: text, with: alias.replacement)
        }

        // Also restore canonical casing for exact dictionary matches: "crm"
        // becomes "CRM", "shopify" becomes "Shopify", and so on.
        for term in vocabulary.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(?i)(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
            text = replacing(pattern, in: text, with: term)
        }
        return text
    }

    private static func replacing(_ pattern: String, in input: String,
                                  with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else {
            return input
        }
        return regex.stringByReplacingMatches(
            in: input, range: NSRange(input.startIndex..., in: input),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
