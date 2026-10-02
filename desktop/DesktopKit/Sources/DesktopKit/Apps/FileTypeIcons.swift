import Foundation

/// File type icons from the icon pack, the way freedesktop file managers pick them: a MIME
/// type (shared-mime-info names) from the file name, then the Icon Naming Specification's
/// chain for it: the type's own icon ("text/x-python" → "text-x-python"), its alias
/// spellings, its shared-mime-info generic icon ("text-x-script"), "<media>-x-generic",
/// and "text-x-generic" last. The guest renders every name these produce (EXACT_ICONS in
/// themes/guest/ish-apply-style).
enum FileTypeIcons {
    static let directoryType = "inode/directory"
    static let executableType = "application/x-executable"
    static let unknownType = "application/octet-stream"

    /// MIME type by extension (lowercased, without the dot).
    static let typesByExtension: [String: String] = [
        "txt": "text/plain", "text": "text/plain", "rst": "text/plain", "lock": "text/plain",
        "log": "text/x-log", "md": "text/markdown", "markdown": "text/markdown",
        "csv": "text/csv", "patch": "text/x-patch", "diff": "text/x-patch",
        "html": "text/html", "htm": "text/html", "css": "text/css", "scss": "text/css", "less": "text/css",
        "xml": "application/xml", "json": "application/json", "yaml": "application/x-yaml",
        "yml": "application/x-yaml", "toml": "application/toml", "sql": "application/sql",
        "py": "text/x-python", "pyw": "text/x-python", "c": "text/x-csrc", "h": "text/x-chdr",
        "cpp": "text/x-c++src", "cc": "text/x-c++src", "cxx": "text/x-c++src", "hpp": "text/x-c++hdr",
        "java": "text/x-java", "rs": "text/x-rust", "go": "text/x-go", "rb": "text/x-ruby",
        "pl": "text/x-perl", "lua": "text/x-lua", "php": "application/x-php",
        "js": "application/javascript", "mjs": "application/javascript", "cjs": "application/javascript",
        "jsx": "application/javascript", "ts": "text/x-typescript", "tsx": "text/x-typescript",
        "swift": "text/x-script", "sh": "application/x-shellscript", "bash": "application/x-shellscript",
        "zsh": "application/x-shellscript", "desktop": "application/x-desktop",
        "so": "application/x-sharedlib", "o": "application/x-object", "a": "application/x-object",
        "pdf": "application/pdf", "zip": "application/zip", "tar": "application/x-tar",
        "tgz": "application/x-compressed-tar", "gz": "application/gzip", "xz": "application/x-xz",
        "bz2": "application/x-bzip", "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
        "deb": "application/vnd.debian.binary-package", "rpm": "application/x-rpm",
        "apk": "application/vnd.android.package-archive", "iso": "application/x-iso9660-image",
        "sqlite": "application/vnd.sqlite3", "sqlite3": "application/vnd.sqlite3", "db": "application/vnd.sqlite3",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff",
        "tiff": "image/tiff", "ico": "image/vnd.microsoft.icon", "heic": "image/heif", "heif": "image/heif",
        "mp3": "audio/mpeg", "wav": "audio/x-wav", "flac": "audio/flac", "ogg": "audio/ogg",
        "opus": "audio/ogg", "m4a": "audio/mp4", "aac": "audio/mp4",
        "mp4": "video/mp4", "m4v": "video/mp4", "mkv": "video/x-matroska", "webm": "video/webm",
        "mov": "video/quicktime", "avi": "video/x-msvideo",
        "ttf": "font/ttf", "otf": "font/otf",
        "odt": "application/vnd.oasis.opendocument.text", "rtf": "application/rtf", "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "ods": "application/vnd.oasis.opendocument.spreadsheet", "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "odp": "application/vnd.oasis.opendocument.presentation", "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]

    /// Whole file names that say what they are without an extension.
    static let typesByName: [String: String] = [
        "makefile": "text/x-makefile", "gnumakefile": "text/x-makefile",
        ".bashrc": "application/x-shellscript", ".profile": "application/x-shellscript",
        ".bash_profile": "application/x-shellscript", ".zshrc": "application/x-shellscript",
        ".ashrc": "application/x-shellscript",
    ]

    /// shared-mime-info's `generic-icon` for types whose icon a pack may lack.
    static let genericIcons: [String: String] = [
        "text/x-python": "text-x-script", "text/x-perl": "text-x-script", "text/x-ruby": "text-x-script",
        "text/x-lua": "text-x-script", "application/x-php": "text-x-script",
        "application/javascript": "text-x-script", "text/x-typescript": "text-x-script",
        "application/x-shellscript": "text-x-script", "text/x-csrc": "text-x-script",
        "text/x-chdr": "text-x-script", "text/x-c++src": "text-x-script", "text/x-c++hdr": "text-x-script",
        "text/x-java": "text-x-script", "text/x-rust": "text-x-script", "text/x-go": "text-x-script",
        "text/x-makefile": "text-x-script",
        "application/zip": "package-x-generic", "application/x-tar": "package-x-generic",
        "application/x-compressed-tar": "package-x-generic", "application/gzip": "package-x-generic",
        "application/x-xz": "package-x-generic", "application/x-bzip": "package-x-generic",
        "application/x-7z-compressed": "package-x-generic", "application/vnd.rar": "package-x-generic",
        "application/vnd.debian.binary-package": "package-x-generic", "application/x-rpm": "package-x-generic",
        "application/vnd.android.package-archive": "package-x-generic",
        "application/x-sharedlib": "application-x-executable", "application/x-object": "application-x-executable",
        "application/x-desktop": "application-x-executable",
        "application/pdf": "x-office-document", "application/vnd.oasis.opendocument.text": "x-office-document",
        "application/vnd.oasis.opendocument.spreadsheet": "x-office-spreadsheet",
        "application/vnd.oasis.opendocument.presentation": "x-office-presentation",
        "application/rtf": "x-office-document", "application/msword": "x-office-document",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "x-office-document",
        "application/vnd.ms-excel": "x-office-spreadsheet",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "x-office-spreadsheet",
        "application/vnd.ms-powerpoint": "x-office-presentation",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "x-office-presentation",
        "application/json": "text-x-script", "application/xml": "text-x-generic",
        "application/x-yaml": "text-x-generic", "application/toml": "text-x-generic",
        "application/sql": "text-x-generic", "application/vnd.sqlite3": "text-x-generic",
        "application/x-iso9660-image": "package-x-generic",
        "font/ttf": "font-x-generic", "font/otf": "font-x-generic",
    ]

    /// Other spellings packs use for the same type.
    static let aliases: [String: [String]] = [
        "text-markdown": ["text-x-markdown"],
        "application-javascript": ["text-javascript"],
        "application-vnd.sqlite3": ["application-x-sqlite3"],
        "application-x-shellscript": ["text-x-sh"],
        "text-x-typescript": ["application-javascript"],
        "application-octet-stream": ["application-x-generic"],
    ]

    /// Folders in a home directory that freedesktop packs draw with their own icon.
    static let homeFolders: [String: String] = [
        "Desktop": "user-desktop", "Documents": "folder-documents", "Downloads": "folder-download",
        "Music": "folder-music", "Pictures": "folder-pictures", "Videos": "folder-videos",
        "Public": "folder-publicshare", "Templates": "folder-templates",
    ]

    static func mimeType(forFileName name: String, isDirectory: Bool, isExecutable: Bool) -> String {
        if isDirectory { return directoryType }
        if let type = typesByName[name.lowercased()] { return type }
        let ext = AppPath.pathExtension(name)
        if let type = typesByExtension[ext] { return type }
        if isExecutable { return executableType }
        // Without an extension a file in a Linux home is nearly always text (configs, READMEs).
        return ext.isEmpty ? "text/plain" : unknownType
    }

    static func iconNames(forMIMEType type: String) -> [String] {
        if type == directoryType { return ["folder", "inode-directory"] }
        let own = type.replacingOccurrences(of: "/", with: "-")
        var names = [own] + (aliases[own] ?? [])
        if let generic = genericIcons[type] { names.append(generic) }
        let media = type.split(separator: "/").first.map(String.init) ?? "text"
        if ["image", "audio", "video", "font"].contains(media) { names.append("\(media)-x-generic") }
        names.append("text-x-generic")
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Icon names for a directory listing entry. `home` is the user's home directory, whose
    /// Desktop, Documents, … folders have their own icons.
    static func iconNames(for entry: FileEntry, home: String? = nil) -> [String] {
        if entry.isDirectory, let home, AppPath.parent(of: entry.path) == AppPath.normalize(home),
           let special = homeFolders[entry.name] {
            return [special, "folder", "inode-directory"]
        }
        let isExecutable = entry.permissions.count >= 4 && entry.permissions.dropFirst(3).first == "x"
        return iconNames(forMIMEType: mimeType(forFileName: entry.name, isDirectory: entry.isDirectory,
                                               isExecutable: isExecutable))
    }
}
