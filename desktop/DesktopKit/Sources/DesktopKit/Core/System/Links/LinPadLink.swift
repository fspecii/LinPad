import Foundation

/// `linpad://` links: shareable actions that open LinPad and ask before doing anything.
///
///   linpad://theme/install?url=<git URL>              install a colour theme repository (ish-colors)
///   linpad://theme/import?name=<name>&colors=<b64>    a theme's colors.toml inline (base64url)
///   linpad://look/<b64>                               a Look (style, colour theme, styling) as base64url JSON
///   linpad://app/install?id=<catalog id>              an optional app from Settings › Apps
///   linpad://                                         just opens LinPad (e.g. back from LocalDevVPN)
///
/// Everything in a link is untrusted: parsing validates and clamps it, and the desktop
/// shows a confirmation before acting on it.
enum LinPadLink: Equatable, Sendable {
    case installTheme(gitURL: String)
    case importTheme(name: String, colorsToml: String)
    case applyLook(DesktopLook)
    case installApp(id: String)
    case open

    static let scheme = "linpad"
    static let maxPayloadBytes = 16 * 1024

    // MARK: Parsing

    static func parse(_ url: URL) -> LinPadLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard url.absoluteString.utf8.count <= maxPayloadBytes * 2 else { return nil }
        let host = components.host?.lowercased() ?? ""
        let path = components.path.split(separator: "/").map(String.init)
        func query(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }

        switch (host, path.first) {
        case ("", nil), ("open", nil):
            return .open
        case ("theme", "install"):
            guard let git = query("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  git.utf8.count <= 512, ColorThemeStore.isAcceptableGitURL(git) else { return nil }
            return .installTheme(gitURL: git)
        case ("theme", "import"):
            guard let encoded = query("colors"), let data = Base64URL.decode(encoded), data.count <= maxPayloadBytes,
                  let toml = String(data: data, encoding: .utf8) else { return nil }
            let name = sanitizedName(query("name") ?? "") ?? "Shared Theme"
            guard ColorsToml.read(toml, id: ColorsToml.id(forName: name), name: name) != nil else { return nil }
            return .importTheme(name: name, colorsToml: toml)
        case ("look", let encoded?):
            guard path.count == 1, let data = Base64URL.decode(encoded), data.count <= maxPayloadBytes,
                  let look = try? JSONDecoder().decode(DesktopLook.self, from: data) else { return nil }
            return sanitized(look).map(LinPadLink.applyLook)
        case ("app", "install"):
            guard let id = query("id"), isCatalogID(id) else { return nil }
            return .installApp(id: id)
        default:
            return nil
        }
    }

    // MARK: Building

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .open:
            components.host = "open"
        case .installTheme(let git):
            components.host = "theme"
            components.path = "/install"
            components.queryItems = [URLQueryItem(name: "url", value: git)]
        case .importTheme(let name, let toml):
            components.host = "theme"
            components.path = "/import"
            components.queryItems = [URLQueryItem(name: "name", value: name),
                                     URLQueryItem(name: "colors", value: Base64URL.encode(Data(toml.utf8)))]
        case .applyLook(let look):
            var shared = look
            shared.isBuiltIn = false
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            components.host = "look"
            components.path = "/" + Base64URL.encode((try? encoder.encode(shared)) ?? Data())
        case .installApp(let id):
            components.host = "app"
            components.path = "/install"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        // URLComponents leaves "+" and "&" alone inside values; encode them for the query.
        components.percentEncodedQueryItems = components.queryItems?.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed))
        }
        return components.url!
    }

    /// The link for sharing a theme: its git repository when it came from one, else its
    /// colours inline.
    static func share(_ theme: ColorTheme) -> LinPadLink {
        if let source = theme.source, ColorThemeStore.isAcceptableGitURL(source) {
            return .installTheme(gitURL: source)
        }
        return .importTheme(name: theme.name, colorsToml: ColorsToml.write(theme))
    }

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()

    // MARK: Validation

    static func isCatalogID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{0,40}$"#, options: .regularExpression) != nil
    }

    static func isThemeID(_ id: String) -> Bool {
        id.isEmpty || id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    static func sanitizedName(_ name: String) -> String? {
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(60))
    }

    /// A Look from a link: a fresh id, known fonts only, values within the editor's ranges.
    static func sanitized(_ look: DesktopLook) -> DesktopLook? {
        guard isThemeID(look.colorThemeID), let name = sanitizedName(look.name) else { return nil }
        var result = look
        let hash = name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        result.id = "shared-" + String(hash, radix: 16)
        result.name = name
        result.isBuiltIn = false
        result.styleID = DesktopStyle.stored(look.styleID).rawValue
        if let appearance = look.appearanceID, DesktopAppearance(rawValue: appearance) == nil { result.appearanceID = nil }
        result.wallpaperQuery = look.wallpaperQuery.flatMap { query in
            let cleaned = String(query.filter { $0.isLetter || $0.isNumber || $0 == " " }.prefix(60))
            return cleaned.isEmpty ? nil : cleaned
        }
        var styling = look.styling
        func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.map { min(max($0, range.lowerBound), range.upperBound) }
        }
        styling.cornerRadius = clamp(styling.cornerRadius, 0...40)
        styling.borderWidth = clamp(styling.borderWidth, 0...8)
        styling.innerGap = clamp(styling.innerGap, 0...64)
        styling.outerGap = clamp(styling.outerGap, 0...64)
        styling.panelOpacity = clamp(styling.panelOpacity, 0.3...1)
        styling.monoFontSize = clamp(styling.monoFontSize, 8...24)
        styling.fontScale = min(max(styling.fontScale, 0.9), 1.2)
        if let font = styling.linuxUIFont, !DesktopStyling.linuxUIFonts.contains(font) { styling.linuxUIFont = nil }
        if let font = styling.linuxMonoFont, !DesktopStyling.linuxMonoFonts.contains(font) { styling.linuxMonoFont = nil }
        if let size = styling.cursorSize, !DesktopStyling.cursorSizes.contains(size) { styling.cursorSize = nil }
        result.styling = styling
        return result
    }
}

/// RFC 4648 §5 base64 without padding, which survives URLs and chat apps.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard base64.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
