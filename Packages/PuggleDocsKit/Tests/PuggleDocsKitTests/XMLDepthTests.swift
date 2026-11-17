import AppKit
import Testing
@testable import PuggleDocsKit

/// Files nested tens of thousands of levels deep are refused or read another way, never built into trees too deep to free.
struct XMLDepthTests {
    private static func nested(_ tag: String, _ depth: Int) -> String {
        String(repeating: "<\(tag)>", count: depth) + String(repeating: "</\(tag)>", count: depth)
    }

    @Test func wordPartsNestedTooDeeplyAreRefused() {
        #expect(throws: DocumentIOError.self) { try XMLTree.parse(Data(Self.nested("w:p", 50_000).utf8)) }
        #expect((try? XMLTree.parse(Data(Self.nested("w:p", 200).utf8))) != nil)
    }

    @Test func deeplyNestedXHTMLSkipsTheStrictTree() {
        let page = "<html><body>" + Self.nested("div", 50_000) + "</body></html>"
        #expect(ExactXMLTree.parse(page) == nil)
        #expect(ExactXMLTree.parse("<html><body><p>Hi</p></body></html>") != nil)
    }
}
