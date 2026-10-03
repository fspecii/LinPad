import Foundation

/// Instant, typo-tolerant search over the Store index: by name, package, keywords,
/// summary and description. Every word of the query has to match somewhere; names
/// outrank packages, which outrank keywords and text.
enum StoreSearch {
    struct Hit: Equatable {
        let app: StoreApp
        let score: Int
    }

    static func results(_ query: String, in apps: [StoreApp], featured: Set<String> = [], limit: Int = 200) -> [StoreApp] {
        hits(query, in: apps, featured: featured, limit: limit).map(\.app)
    }

    static func hits(_ query: String, in apps: [StoreApp], featured: Set<String> = [], limit: Int = 200) -> [Hit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [Hit] = []
        for app in apps {
            guard var score = score(app, tokens: tokens) else { continue }
            if featured.contains(app.id) { score += 40 }
            if app.isBarePackage { score -= 80 }
            if app.screenshots != nil { score += 10 }
            hits.append(Hit(app: app, score: score))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        return Array(hits.prefix(limit))
    }

    static func tokenize(_ text: String) -> [String] {
        normalize(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" }).map(String.init)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// nil when some token matches nothing.
    static func score(_ app: StoreApp, tokens: [String]) -> Int? {
        let name = normalize(app.name)
        let nameWords = tokenize(app.name)
        let packages = ([app.mainPackage].compactMap { $0 } + (app.packages ?? [])).map(normalize)
        let keywords = (app.keywords ?? []).map(normalize)
        let summaryWords = tokenize(app.summary ?? "")
        let description = normalize(app.description ?? "")
        let category = normalize(app.category)
        var total = 0
        if tokens.count > 1, name == tokens.joined(separator: " ") { total += 400 }
        for token in tokens {
            var best = 0
            if name == token { best = 1000 }
            else if name.hasPrefix(token) { best = 650 }
            else if nameWords.contains(where: { $0.hasPrefix(token) }) { best = 480 }
            else if name.contains(token) { best = 320 }
            if packages.contains(token) { best = max(best, 420) }
            else if packages.contains(where: { $0.hasPrefix(token) }) { best = max(best, 260) }
            else if packages.contains(where: { $0.contains(token) }) { best = max(best, 140) }
            if keywords.contains(where: { $0 == token || $0.hasPrefix(token) }) { best = max(best, 220) }
            if category.contains(token) { best = max(best, 150) }
            if summaryWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 130) }
            if best == 0, token.count >= 3, description.contains(token) { best = 45 }
            if best == 0, token.count >= 4, nameWords.contains(where: { isTypo(token, of: $0) }) { best = 260 }
            if best == 0, token.count >= 4, packages.contains(where: { isTypo(token, of: $0) }) { best = 180 }
            if best == 0 { return nil }
            total += best
        }
        return total
    }

    /// One edit (insertion, deletion, substitution or adjacent swap) away, also against the
    /// word's prefix of the same length so "filezil" + typo still finds FileZilla.
    static func isTypo(_ token: String, of word: String) -> Bool {
        guard abs(word.count - token.count) <= 1 || word.count > token.count else { return false }
        let a = Array(token)
        let candidates = [Array(word), Array(word.prefix(token.count)), Array(word.prefix(token.count + 1))]
        return candidates.contains { withinOneEdit(a, $0) }
    }

    private static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            let diffs = a.indices.filter { a[$0] != b[$0] }
            if diffs.count == 1 { return true }
            if diffs.count == 2, diffs[1] == diffs[0] + 1, a[diffs[0]] == b[diffs[1]], a[diffs[1]] == b[diffs[0]] { return true }
            return false
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        var i = 0, j = 0, skipped = false
        while i < short.count, j < long.count {
            if short[i] == long[j] { i += 1; j += 1; continue }
            if skipped { return false }
            skipped = true
            j += 1
        }
        return true
    }
}
