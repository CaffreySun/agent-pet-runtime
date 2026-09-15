import Foundation

/// A verbatim block of TOML — optional comment lines, a table header, and its
/// keys — that the runtime appends to and removes from a file it shares with
/// its owner (Grok's `config.toml`).
///
/// There is no TOML parser here on purpose. The only edits this type knows how
/// to make are "append exactly these bytes at the end" and "remove exactly
/// these bytes again". Inserting a key into a table someone else wrote would
/// need a parser to be safe, so it is refused instead.
public struct TOMLBlock: Equatable, Sendable {
    /// The table header, brackets included, e.g. `[compat.claude]`.
    public let header: String
    /// The key lines, at top level of that table.
    public let lines: [String]
    /// Comment lines placed before the header, `#` included.
    public let comments: [String]

    public init(header: String, lines: [String], comments: [String] = []) {
        self.header = header
        self.lines = lines
        self.comments = comments
    }

    /// The table name without brackets, e.g. `compat.claude`.
    public var section: String {
        header.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// The exact text of the block, newline-terminated.
    public var text: String {
        (comments + [header] + lines).joined(separator: "\n") + "\n"
    }
}

public enum TOMLEditError: Error, Equatable, Sendable {
    /// The table already exists and is not our block. Editing around someone
    /// else's content needs a parser; refusing beats guessing.
    case sectionExists(String)
    /// The recorded bytes are no longer in the file, so there is nothing that
    /// is ours to remove.
    case blockMissing
}

public enum TOMLSectionEdit {

    /// Appends `block` at the end of `text`, returning the new content and the
    /// exact bytes that were added. The caller records those bytes and hands
    /// them back for a byte-exact removal later.
    public static func appended(
        _ block: TOMLBlock,
        to text: String
    ) throws -> (result: String, added: String) {
        if containsHeader(block.header, in: text) {
            throw TOMLEditError.sectionExists(block.section)
        }
        if text.isEmpty {
            return (block.text, block.text)
        }
        var prefix = text
        // The block gets its own line and one blank line before it, so a file
        // whose last line lacked a newline cannot swallow the header.
        if !prefix.hasSuffix("\n") { prefix += "\n" }
        if !prefix.hasSuffix("\n\n") { prefix += "\n" }

        let result = prefix + block.text
        return (result, String(result.dropFirst(text.count)))
    }

    /// Removes exactly the bytes a previous `appended` added.
    public static func removing(_ added: String, from text: String) throws -> String {
        guard text.contains(added) else {
            throw TOMLEditError.blockMissing
        }
        return text.replacingOccurrences(of: added, with: "")
    }

    /// Whether the block's table — or a dotted key for anything under it —
    /// already appears. Both would collide with the block we append: a second
    /// `[compat.claude]` header is a parse error, and a dotted `compat.claude.*`
    /// key defines the table in a way a later header cannot reopen.
    public static func containsHeader(_ header: String, in text: String) -> Bool {
        let section = header.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == header { return true }
            if line.hasPrefix("[\(section)]") || line.hasPrefix("[[\(section)]]") { return true }
            if line.hasPrefix(section + ".") { return true }
        }
        return false
    }
}
