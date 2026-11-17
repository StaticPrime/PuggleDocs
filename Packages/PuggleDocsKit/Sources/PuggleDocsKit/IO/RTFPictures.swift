import AppKit
import UniformTypeIdentifiers

/// Embedded pictures (`\pict` groups) in RTF, which AppKit's converter neither reads nor writes.
/// Pictures are swapped for plain-text tokens around the AppKit conversion.
enum RTFPictures {
    struct Picture {
        let data: Data
        let size: CGSize?
    }

    static func token(_ number: Int) -> String { "PUGGLEPICTURE\(number)TOKEN" }

    // MARK: Writing

    /// Replaces image attachments with tokens; returns the token → `\pict` group map.
    static func replaceAttachmentsWithTokens(in text: NSMutableAttributedString) -> [String: String] {
        var groups: [String: String] = [:]
        var number = 0
        var ranges: [(NSRange, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            if let attachment = value as? NSTextAttachment { ranges.append((range, attachment)) }
        }
        for (range, attachment) in ranges.reversed() {
            var replacement = ""
            if let info = ImageAttachments.info(attachment), let group = pictGroup(info) {
                number += 1
                replacement = token(number)
                groups[replacement] = group
            }
            var attributes = text.attributes(at: range.location, effectiveRange: nil)
            attributes[.attachment] = nil
            text.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
        }
        return groups
    }

    static func pictGroup(_ info: ImageAttachments.Info) -> String? {
        var data = info.data
        var type = info.type
        if !type.conforms(to: .png) && !type.conforms(to: .jpeg) {
            guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            data = png
            type = .png
        }
        let pixels = NSBitmapImageRep(data: data).map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? info.size
        let blip = type.conforms(to: .jpeg) ? "\\jpegblip" : "\\pngblip"
        var hex = ""
        hex.reserveCapacity(data.count * 2 + data.count / 64)
        for (index, byte) in data.enumerated() {
            if index > 0, index % 64 == 0 { hex += "\n" }
            hex += String(format: "%02x", byte)
        }
        return "{\\*\\shppict{\\pict\(blip)\\picw\(Int(pixels.width))\\pich\(Int(pixels.height))"
            + "\\picwgoal\(Int((info.size.width * 20).rounded()))\\pichgoal\(Int((info.size.height * 20).rounded()))\n\(hex)}}"
    }

    static func insertGroups(_ groups: [String: String], into rtf: Data) -> Data {
        guard !groups.isEmpty, var text = String(data: rtf, encoding: .isoLatin1) else { return rtf }
        for (token, group) in groups { text = text.replacingOccurrences(of: token, with: group) }
        return text.data(using: .isoLatin1) ?? rtf
    }

    // MARK: Reading

    /// Pulls `\pict` groups out of RTF source, leaving tokens behind. `unsupported` counts pictures
    /// in formats that cannot be shown (such as Windows metafiles).
    static func extract(from rtf: Data) -> (rtf: Data, pictures: [String: Picture], unsupported: Int) {
        guard let text = String(data: rtf, encoding: .isoLatin1), text.contains("\\pict") else { return (rtf, [:], 0) }
        let characters = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var pictures: [String: Picture] = [:]
        var unsupported = 0
        var index = 0
        func hasPrefix(_ prefix: String, at position: Int) -> Bool {
            let scalars = Array(prefix.unicodeScalars)
            guard position + scalars.count <= characters.count else { return false }
            return Array(characters[position..<(position + scalars.count)]) == scalars
        }
        while index < characters.count {
            let isShape = hasPrefix("{\\*\\shppict", at: index)
            let isAlternative = hasPrefix("{\\nonshppict", at: index)
            let isPicture = hasPrefix("{\\pict", at: index)
            guard isShape || isAlternative || isPicture, let end = closingBrace(characters, from: index) else {
                output.append(characters[index])
                index += 1
                continue
            }
            if !isAlternative {
                let group = Array(characters[index...end])
                let start = isShape ? firstPictureStart(group) : 0
                if let start, let picture = parsePicture(Array(group[start...])) {
                    let key = token(pictures.count + 1)
                    pictures[key] = picture
                    output.append(contentsOf: (" " + key + " ").unicodeScalars)
                } else {
                    unsupported += 1
                }
            }
            index = end + 1
        }
        let cleaned = String(output)
        return (cleaned.data(using: .isoLatin1) ?? rtf, pictures, unsupported)
    }

    /// Index of the brace closing the group that opens at `start`, honouring escapes.
    static func closingBrace(_ characters: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    static func firstPictureStart(_ group: [Unicode.Scalar]) -> Int? {
        let target = Array("{\\pict".unicodeScalars)
        guard group.count > target.count else { return nil }
        for index in 1..<(group.count - target.count) where Array(group[index..<(index + target.count)]) == target {
            return index
        }
        return nil
    }

    /// Parses `{\pict ... hexdata}`; only PNG and JPEG pictures are returned.
    static func parsePicture(_ group: [Unicode.Scalar]) -> Picture? {
        var index = 1
        var words: [String: Int] = [:]
        var flags = Set<String>()
        var hex = String.UnicodeScalarView()
        var binary: Data?
        while index < group.count - 1 {
            let character = group[index]
            if character == "\\" {
                index += 1
                var word = ""
                while index < group.count, group[index].properties.isAlphabetic { word.unicodeScalars.append(group[index]); index += 1 }
                var number = ""
                while index < group.count, group[index] == "-" || ("0"..."9").contains(group[index]) { number.unicodeScalars.append(group[index]); index += 1 }
                if index < group.count, group[index] == " " { index += 1 }
                if word == "bin", let count = Int(number), index + count <= group.count {
                    binary = Data(group[index..<(index + count)].map { UInt8(truncatingIfNeeded: $0.value) })
                    index += count
                    continue
                }
                if let value = Int(number) { words[word] = value } else { flags.insert(word) }
            } else if character == "{" {
                index = (closingBrace(group, from: index) ?? index) + 1
            } else {
                if character.properties.isASCIIHexDigit { hex.append(character) }
                index += 1
            }
        }
        guard flags.contains("pngblip") || flags.contains("jpegblip") else { return nil }
        let data = binary ?? Data(hexString: String(hex))
        guard let data, NSImage(data: data) != nil else { return nil }
        let scaleX = CGFloat(words["picscalex"] ?? 100) / 100
        let scaleY = CGFloat(words["picscaley"] ?? 100) / 100
        var size: CGSize?
        if let width = words["picwgoal"], let height = words["pichgoal"], width > 0, height > 0 {
            size = CGSize(width: CGFloat(width) / 20 * scaleX, height: CGFloat(height) / 20 * scaleY)
        } else if let width = words["picw"], let height = words["pich"], width > 0, height > 0 {
            size = CGSize(width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY)
        }
        return Picture(data: data, size: size)
    }

    /// Swaps tokens in imported text for image attachments.
    static func restore(_ pictures: [String: Picture], in text: NSMutableAttributedString) {
        guard !pictures.isEmpty else { return }
        for (key, picture) in pictures {
            let string = text.string as NSString
            var range = string.range(of: key)
            guard range.location != NSNotFound, let attachment = ImageAttachments.make(data: picture.data, size: picture.size) else { continue }
            // Remove the spaces added around the token while extracting.
            if range.location > 0, string.character(at: range.location - 1) == 0x20 { range.location -= 1; range.length += 1 }
            if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) == 0x20 { range.length += 1 }
            var attributes = text.attributes(at: range.location, effectiveRange: nil)
            attributes[.attachment] = attachment
            text.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
    }
}

extension Data {
    init?(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var high: UInt8?
        for scalar in hexString.unicodeScalars {
            guard let value = UInt8(String(scalar), radix: 16) else { continue }
            if let first = high {
                data.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        guard !data.isEmpty else { return nil }
        self = data
    }
}
