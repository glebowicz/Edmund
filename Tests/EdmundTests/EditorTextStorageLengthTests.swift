import Testing
import AppKit
@testable import EdmundCore

/// `EditorTextStorage.length` is answered from the backing store rather than
/// inherited from NSAttributedString (whose default routes through `string`,
/// bridging the whole document out of Objective-C on every call). These tests
/// pin the contract that overriding it changes nothing but the cost: the value
/// must stay the UTF-16 length of `string`, through edits and across the
/// character classes where UTF-16 and Character counts disagree.
@Suite("Editor text storage — length")
struct EditorTextStorageLengthTests {

    @MainActor private func storage(_ s: String) -> EditorTextStorage {
        let ts = EditorTextStorage()
        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: s)
        return ts
    }

    @MainActor
    @Test("length is the UTF-16 length of string", arguments: [
        "",
        "plain ascii",
        "line one\nline two\n",
        "café naïve",          // combining-capable Latin
        "日本語のテキスト",       // BMP, 3 bytes each in UTF-8
        "emoji 👩‍👩‍👧‍👦 zwj",     // surrogate pairs + ZWJ sequence
        "math 𝔘𝔫𝔦𝔠𝔬𝔡𝔢",        // astral plane, all surrogate pairs
        "mixed 👍 текст 中文 ok",
    ])
    func lengthMatchesStringLength(_ sample: String) {
        let ts = storage(sample)
        #expect(ts.length == (ts.string as NSString).length)
        #expect(ts.length == (sample as NSString).length)
    }

    @MainActor
    @Test("length tracks edits")
    func lengthTracksEdits() {
        let ts = storage("hello world")
        #expect(ts.length == 11)

        ts.replaceCharacters(in: NSRange(location: 5, length: 0), with: ",")
        #expect(ts.length == 12)
        #expect(ts.length == (ts.string as NSString).length)

        // Deleting a surrogate pair drops two UTF-16 units, not one Character.
        ts.replaceCharacters(in: NSRange(location: ts.length, length: 0), with: "🌍")
        #expect(ts.length == 14)
        ts.replaceCharacters(in: NSRange(location: 12, length: 2), with: "")
        #expect(ts.length == 12)
        #expect(ts.length == (ts.string as NSString).length)

        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: "")
        #expect(ts.length == 0)
        #expect(ts.string.isEmpty)
    }

    @MainActor
    @Test("string is invalidated by every character edit")
    func stringCacheFollowsEdits() {
        let ts = storage("hello world")
        #expect(ts.string == "hello world")     // primes the cache

        ts.replaceCharacters(in: NSRange(location: 5, length: 0), with: ",")
        #expect(ts.string == "hello, world")

        // The attributed-string overload invalidates too.
        ts.replaceCharacters(in: NSRange(location: 0, length: 5),
                             with: NSAttributedString(string: "HELLO"))
        #expect(ts.string == "HELLO, world")

        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: "")
        #expect(ts.string == "")

        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: "back 🌍")
        #expect(ts.string == "back 🌍")
        #expect(ts.length == (ts.string as NSString).length)
    }

    @MainActor
    @Test("attribute-only changes leave string intact")
    func attributeChangesDoNotDisturbString() {
        let ts = storage("styled text 🌍 here")
        let before = ts.string
        ts.setAttributes([.font: NSFont.systemFont(ofSize: 14)],
                         range: NSRange(location: 0, length: ts.length))
        ts.addAttribute(.foregroundColor, value: NSColor.red,
                        range: NSRange(location: 0, length: 6))
        // fixAttributes runs font substitution over the emoji — attributes only.
        ts.fixAttributes(in: NSRange(location: 0, length: ts.length))
        #expect(ts.string == before)
        #expect(ts.length == (before as NSString).length)
    }

    @MainActor
    @Test("repeated reads agree with the backing store after interleaved edits")
    func repeatedReadsStayConsistent() {
        let ts = storage("")
        var expected = ""
        for (i, piece) in ["alpha ", "βγδ ", "🌍🌎 ", "epsilon"].enumerated() {
            ts.replaceCharacters(in: NSRange(location: ts.length, length: 0), with: piece)
            expected += piece
            // Read twice: the second read is the cached one.
            #expect(ts.string == expected, "after append \(i)")
            #expect(ts.string == expected, "cached read after append \(i)")
            #expect(ts.length == (expected as NSString).length)
        }
    }

    @MainActor
    @Test("length agrees with attribute enumeration bounds")
    func lengthBoundsAttributeEnumeration() {
        let ts = storage("bold and plain 🌍 text")
        ts.setAttributes([.font: NSFont.systemFont(ofSize: 12)],
                         range: NSRange(location: 0, length: ts.length))
        var covered = 0
        ts.enumerateAttribute(.font, in: NSRange(location: 0, length: ts.length),
                              options: []) { _, range, _ in
            covered += range.length
        }
        #expect(covered == ts.length)
    }

    #if DEBUG
    @MainActor
    @Test("length and repeated string reads keep bridge work bounded")
    func stringBridgeWorkIsBounded() {
        let ts = storage(String(repeating: "markdown 🌍\n", count: 4_000))

        for _ in 0..<10_000 { _ = ts.length }
        #expect(ts.debugStringBridgeCount == 0)

        for _ in 0..<1_000 { _ = ts.string }
        #expect(ts.debugStringBridgeCount == 1)

        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        for _ in 0..<1_000 { _ = ts.string }
        #expect(ts.debugStringBridgeCount == 2)
    }
    #endif
}
