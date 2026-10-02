import UIKit

enum SyntaxLanguage: String, CaseIterable {
    case plain = "Plain Text"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case tsx = "TSX"
    case json = "JSON"
    case css = "CSS"
    case html = "HTML"
    case shell = "Shell"
    case python = "Python"
    case markdown = "Markdown"

    init(path: String?) {
        guard let path else {
            self = .plain
            return
        }
        let name = AppPath.lastComponent(path)
        switch AppPath.pathExtension(name) {
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "json", "jsonc", "webmanifest": self = .json
        case "css", "scss", "less": self = .css
        case "html", "htm", "xml", "svg", "vue", "svelte": self = .html
        case "sh", "bash", "ash", "zsh": self = .shell
        case "py", "pyw": self = .python
        case "md", "markdown": self = .markdown
        default:
            let shellDotfiles: Set<String> = [".profile", ".ashrc", ".bashrc", ".zshrc", ".bash_profile", ".envrc"]
            self = shellDotfiles.contains(name) ? .shell : .plain
        }
    }
}

enum SyntaxToken {
    case keyword, string, comment, number, type, function, heading
}

struct SyntaxPalette: Equatable {
    var text: UIColor
    var keyword = UIColor(red: 0.78, green: 0.47, blue: 0.87, alpha: 1)
    var string = UIColor(red: 0.6, green: 0.77, blue: 0.47, alpha: 1)
    var comment = UIColor(red: 0.5, green: 0.53, blue: 0.58, alpha: 1)
    var number = UIColor(red: 0.82, green: 0.6, blue: 0.4, alpha: 1)
    var type = UIColor(red: 0.9, green: 0.75, blue: 0.48, alpha: 1)
    var function = UIColor(red: 0.38, green: 0.69, blue: 0.94, alpha: 1)
    var heading: UIColor

    func color(for token: SyntaxToken) -> UIColor {
        switch token {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .function: return function
        case .heading: return heading
        }
    }
}

/// One regex; each capture group (or the whole match when there are none) gets a token style.
private struct HighlightRule {
    let regex: NSRegularExpression
    let tokens: [SyntaxToken]
}

/// Regex highlighting applied straight to an NSTextStorage. Rules run in order and later
/// rules win, so every language ends with one combined comments-or-strings rule: a single
/// left-to-right scan is what keeps `"http://x"` a string and `// it's` a comment.
@MainActor
final class SyntaxHighlighter {
    let language: SyntaxLanguage
    let font: UIFont
    let palette: SyntaxPalette
    private let boldFont: UIFont
    private let rules: [HighlightRule]

    init(language: SyntaxLanguage, font: UIFont, palette: SyntaxPalette) {
        self.language = language
        self.font = font
        self.palette = palette
        boldFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        rules = SyntaxRules.rules(for: language)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: palette.text]
    }

    func highlightAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        highlight(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Callers inside `didProcessEditing` must not wrap this in begin/endEditing.
    func highlight(_ storage: NSTextStorage, in requested: NSRange) {
        let range = NSIntersectionRange(requested, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        storage.setAttributes(baseAttributes, range: range)
        guard !rules.isEmpty else { return }
        let string = storage.string
        for rule in rules {
            rule.regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                guard let match else { return }
                if match.numberOfRanges == 1 {
                    apply(rule.tokens[0], to: match.range, in: storage)
                    return
                }
                for group in 1..<match.numberOfRanges where group - 1 < rule.tokens.count {
                    let groupRange = match.range(at: group)
                    if groupRange.location != NSNotFound {
                        apply(rule.tokens[group - 1], to: groupRange, in: storage)
                    }
                }
            }
        }
    }

    private func apply(_ token: SyntaxToken, to range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: palette.color(for: token), range: range)
        if token == .heading {
            storage.addAttribute(.font, value: boldFont, range: range)
        }
    }
}

@MainActor
private enum SyntaxRules {
    private static var cache: [SyntaxLanguage: [HighlightRule]] = [:]

    static func rules(for language: SyntaxLanguage) -> [HighlightRule] {
        if let cached = cache[language] { return cached }
        let compiled = definitions(for: language).compactMap { pattern, tokens in
            compile(pattern).map { HighlightRule(regex: $0, tokens: tokens) }
        }
        cache[language] = compiled
        return compiled
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            assertionFailure("Invalid highlight pattern \(pattern): \(error)")
            return nil
        }
    }

    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?n?)\b"#
    private static let doubleQuoted = #""(?:[^"\\\n]|\\.)*""#
    private static let singleQuoted = #"'(?:[^'\\\n]|\\.)*'"#
    private static let cStyleComment = #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static let jsKeywords = """
        break case catch class const continue debugger default delete do else export extends finally \
        for from function if import in instanceof let new of return super switch this throw try typeof \
        var void while with yield async await static get set null undefined true false
        """
    private static let tsKeywords = """
        interface type enum implements private public protected readonly declare namespace abstract as \
        keyof never unknown any string number boolean satisfies infer is
        """

    private static func definitions(for language: SyntaxLanguage) -> [(String, [SyntaxToken])] {
        switch language {
        case .plain:
            return []
        case .javascript, .typescript, .tsx:
            var keywordList = jsKeywords
            if language != .javascript { keywordList += " " + tsKeywords }
            var rules: [(String, [SyntaxToken])] = [
                (#"\b[A-Z][A-Za-z0-9_]*\b"#, [.type]),
                (#"\b([a-zA-Z_$][\w$]*)(?=\s*\()"#, [.function]),
                (words(keywordList), [.keyword]),
                (number, [.number]),
            ]
            if language != .typescript {
                rules.append((#"</?([A-Za-z][\w.:-]*)"#, [.type]))
            }
            rules.append((
                "(\(cStyleComment))|(\(doubleQuoted)|\(singleQuoted)|`(?:[^`\\\\]|\\\\.)*`)",
                [.comment, .string]))
            return rules
        case .json:
            return [
                (number, [.number]),
                (words("true false null"), [.keyword]),
                ("(\(doubleQuoted))(?=\\s*:)|(\(doubleQuoted))|(//[^\\n]*)", [.function, .string, .comment]),
            ]
        case .css:
            return [
                (#"[.#][A-Za-z_][\w-]*"#, [.type]),
                (#"^\s+([a-zA-Z-]+)(?=\s*:)"#, [.function]),
                (#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|fr|ch)?\b"#, [.number]),
                (#"#[0-9a-fA-F]{3,8}\b"#, [.number]),
                (#"@[\w-]+|!important"#, [.keyword]),
                (#"(/\*[\s\S]*?(?:\*/|\z))|("# + doubleQuoted + "|" + singleQuoted + ")", [.comment, .string]),
            ]
        case .html:
            return [
                (#"</?([A-Za-z][\w:-]*)|/?>"#, [.keyword]),
                (#"\s([\w:@.-]+)(?==)"#, [.function]),
                (#"&[#\w]+;"#, [.number]),
                (#"(<!--[\s\S]*?(?:-->|\z))|=\s*("[^"\n]*"|'[^'\n]*')"#, [.comment, .string]),
            ]
        case .shell:
            return [
                (words("""
                    if then else elif fi for while until do done case esac in function return local \
                    export readonly unset shift exit break continue source alias set trap eval exec
                    """), [.keyword]),
                (#"\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@#?*!$-])"#, [.function]),
                (#"\b\d+\b"#, [.number]),
                (#"((?<![\w$\\])#[^\n]*)|("# + doubleQuoted + #"|'[^'\n]*')"#, [.comment, .string]),
            ]
        case .python:
            return [
                (words("""
                    False None True and as assert async await break class continue def del elif else \
                    except finally for from global if import in is lambda nonlocal not or pass raise \
                    return try while with yield match case self
                    """), [.keyword]),
                (words("print len range str int float list dict set tuple open super isinstance enumerate zip"),
                 [.function]),
                (#"\b(?:def|class)\s+([A-Za-z_]\w*)"#, [.type]),
                (#"@[\w.]+"#, [.type]),
                (number, [.number]),
                (#"(#[^\n]*)|([rRbBuUfF]{0,2}(?:"""[\s\S]*?(?:"""|\z)|'''[\s\S]*?(?:'''|\z)|"#
                    + doubleQuoted + "|" + singleQuoted + "))", [.comment, .string]),
            ]
        case .markdown:
            return [
                (#"^#{1,6}[ \t].*$"#, [.heading]),
                (#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, [.keyword]),
                (#"^\s*(?:[-*+]|\d+\.)(?=\s)"#, [.number]),
                (#"^>.*$"#, [.comment]),
                (#"\[[^\]\n]*\]\([^)\n]*\)"#, [.function]),
                (#"(```[^\n]*|`[^`\n]+`)"#, [.string]),
            ]
        }
    }
}
