import AppKit

/// Computes the marker text ("1.", "b.", "●") of every list paragraph.
/// Items sharing a list id are numbered together, even when other paragraphs sit between them.
public enum ListNumbering {
    public struct Entry: Equatable {
        public let paragraphRange: NSRange
        public let item: ListItem
        public let marker: String

        public init(paragraphRange: NSRange, item: ListItem, marker: String) {
            self.paragraphRange = paragraphRange
            self.item = item
            self.marker = marker
        }
    }

    public static func entries(in storage: NSAttributedString) -> [Entry] {
        guard storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var counters: [String: [Int]] = [:]
        var result: [Entry] = []
        storage.enumerateAttribute(.pdListItem, in: NSRange(location: 0, length: storage.length), options: []) { value, run, _ in
            guard let item = value as? ListItem else { return }
            var location = run.location
            while location < NSMaxRange(run) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                // Only count a paragraph once: at the run that contains its first character.
                if paragraph.location >= run.location {
                    var levels = counters[item.listID] ?? Array(repeating: 0, count: ListItem.maxLevel + 1)
                    levels[item.level] += 1
                    for deeper in (item.level + 1)..<levels.count { levels[deeper] = 0 }
                    counters[item.listID] = levels
                    result.append(Entry(paragraphRange: paragraph, item: item, marker: item.preset.marker(level: item.level, counters: levels)))
                }
                location = NSMaxRange(paragraph)
            }
        }
        return result
    }

    /// Marker for an item appended after everything in `storage` (the empty last paragraph).
    public static func trailingMarker(for item: ListItem, in storage: NSAttributedString) -> String {
        var levels = Array(repeating: 0, count: ListItem.maxLevel + 1)
        for entry in entries(in: storage) where entry.item.listID == item.listID {
            levels[entry.item.level] += 1
            for deeper in (entry.item.level + 1)..<levels.count { levels[deeper] = 0 }
        }
        levels[item.level] += 1
        return item.preset.marker(level: item.level, counters: levels)
    }
}
