import Foundation

/// POSIX single-quote escaping for words spliced into `LinuxHost.run` commands.
enum ShellQuote {
    /// Inside '...' every byte is literal except the quote itself, which has to
    /// close the string, be escaped, and reopen it.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Alpine package names: a conservative subset so names never need quoting tricks
    /// and can never be mistaken for apk flags.
    static func isValidPackageName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil
    }
}
