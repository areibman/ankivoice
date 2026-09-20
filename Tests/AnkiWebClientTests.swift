import XCTest
@testable import AnkiVoice

final class ProtobufWriterTests: XCTestCase {

    func testStringFieldsRoundTrip() throws {
        var data = Data()
        ProtobufWriter.appendString("hello", field: 1, to: &data)
        ProtobufWriter.appendString("wörld — 日本語", field: 2, to: &data)
        let message = try ProtobufMessage(data: data)
        XCTAssertEqual(message.string(1), "hello")
        XCTAssertEqual(message.string(2), "wörld — 日本語")
        XCTAssertNil(message.string(3))
    }

    func testVarintEncodingUsesContinuationBits() throws {
        var data = Data()
        ProtobufWriter.appendVarint(300, field: 1, to: &data)
        XCTAssertEqual([UInt8](data), [0x08, 0xAC, 0x02])
        XCTAssertEqual(try ProtobufMessage(data: data).int(1), 300)
    }

    // MARK: Hostile input (must throw, never trap)

    func testLengthDelimitedFieldLongerThanBufferIsTruncated() {
        // field 1, wire type 2, length 100 — but only 3 bytes follow.
        let data = Data([0x0A, 0x64, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try ProtobufMessage(data: data)) { error in
            XCTAssertEqual(error as? ProtobufMessage.DecodeError, .truncated)
        }
    }

    func testHugeLengthDoesNotOverflowIndexMath() {
        // Length varint = UInt64.max (10 bytes of 0xFF then 0x01).
        var data = Data([0x0A])
        data.append(contentsOf: [UInt8](repeating: 0xFF, count: 9))
        data.append(0x01)
        XCTAssertThrowsError(try ProtobufMessage(data: data)) { error in
            XCTAssertEqual(error as? ProtobufMessage.DecodeError, .truncated)
        }
        // Length 2^63 fits in UInt64 but not comfortably in Int math.
        let big = Data([0x0A, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
        XCTAssertThrowsError(try ProtobufMessage(data: big))
    }

    func testUnterminatedVarintIsTruncated() {
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x08, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? ProtobufMessage.DecodeError, .truncated)
        }
        // A varint that never terminates within 64 bits.
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x08] + [UInt8](repeating: 0xFF, count: 11))))
    }

    func testFixedWidthFieldsAreBoundsChecked() {
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x09, 0x01, 0x02])))       // fixed64, 2 bytes
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x0D, 0x01, 0x02, 0x03]))) // fixed32, 3 bytes
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x0B]))) { error in         // start-group
            XCTAssertEqual(error as? ProtobufMessage.DecodeError, .unsupportedWireType(3))
        }
    }

    func testRandomBytesNeverTrap() throws {
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<500 {
            let count = Int(state % 64)
            let bytes = (0..<count).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 56)
            }
            // Either decodes or throws; a trap would fail the whole suite.
            _ = try? ProtobufMessage(data: Data(bytes))
            _ = try? AnkiWebClient.itemInfo(id: 1, from: Data(bytes))
        }
    }

    func testNestedMessagesRoundTrip() throws {
        var inner = Data()
        ProtobufWriter.appendString("Front", field: 1, to: &inner)
        ProtobufWriter.appendString("する", field: 2, to: &inner)
        var outer = Data()
        ProtobufWriter.appendMessage(inner, field: 4, to: &outer)
        ProtobufWriter.appendMessage(inner, field: 4, to: &outer)

        let message = try ProtobufMessage(data: outer)
        XCTAssertEqual(message.messages(4).count, 2)
        XCTAssertEqual(message.messages(4).first?.string(2), "する")
    }
}

final class AnkiWebClientTests: XCTestCase {

    // MARK: Reference parsing

    func testSharedIDParsing() {
        XCTAssertEqual(AnkiWebClient.sharedID(from: "https://ankiweb.net/shared/info/2055492159"), 2_055_492_159)
        XCTAssertEqual(AnkiWebClient.sharedID(from: "ankiweb.net/shared/download/588482904?t=abc"), 588_482_904)
        XCTAssertEqual(AnkiWebClient.sharedID(from: "  588482904\n"), 588_482_904)
        XCTAssertNil(AnkiWebClient.sharedID(from: "Japanese"))
        XCTAssertNil(AnkiWebClient.sharedID(from: "https://ankiweb.net/decks"))
        XCTAssertNil(AnkiWebClient.sharedID(from: "-5"))
        XCTAssertNil(AnkiWebClient.sharedID(from: ""))
    }

    // MARK: Search rows

    func testListRowDecoding() throws {
        var row = Data()
        ProtobufWriter.appendVarint(588_482_904, field: 1, to: &row)
        ProtobufWriter.appendString("Japanese Core 1000", field: 2, to: &row)
        ProtobufWriter.appendVarint(187, field: 3, to: &row)
        ProtobufWriter.appendVarint(4, field: 4, to: &row)
        ProtobufWriter.appendVarint(1_700_000_000, field: 5, to: &row)
        ProtobufWriter.appendVarint(2_387, field: 6, to: &row)
        ProtobufWriter.appendVarint(12, field: 7, to: &row)

        let summary = try XCTUnwrap(AnkiWebClient.summary(try ProtobufMessage(data: row)))
        XCTAssertEqual(summary.id, 588_482_904)
        XCTAssertEqual(summary.title, "Japanese Core 1000")
        XCTAssertEqual(summary.thumbsUp, 187)
        XCTAssertEqual(summary.thumbsDown, 4)
        XCTAssertEqual(summary.notes, 2_387)
        XCTAssertEqual(summary.audio, 12)
        XCTAssertEqual(summary.images, 0)
        XCTAssertEqual(summary.modified?.timeIntervalSince1970, 1_700_000_000)
    }

    func testListRowWithoutTitleIsDropped() throws {
        var row = Data()
        ProtobufWriter.appendVarint(1, field: 1, to: &row)
        XCTAssertNil(AnkiWebClient.summary(try ProtobufMessage(data: row)))
    }

    // MARK: Item info

    private func deckInfoMessage(includeDeck: Bool = true) -> Data {
        var sampleField1 = Data()
        ProtobufWriter.appendString("Front", field: 1, to: &sampleField1)
        ProtobufWriter.appendString("する", field: 2, to: &sampleField1)
        var sampleField2 = Data()
        ProtobufWriter.appendString("Back", field: 1, to: &sampleField2)
        ProtobufWriter.appendString("do, make[sound:0.mp3]", field: 2, to: &sampleField2)
        var sampleField3 = Data()
        ProtobufWriter.appendString("Notes", field: 1, to: &sampleField3)
        var sample = Data()
        ProtobufWriter.appendMessage(sampleField1, field: 1, to: &sample)
        ProtobufWriter.appendMessage(sampleField2, field: 1, to: &sample)
        ProtobufWriter.appendMessage(sampleField3, field: 1, to: &sample)

        var deck = Data()
        ProtobufWriter.appendVarint(10, field: 1, to: &deck)
        ProtobufWriter.appendVarint(3, field: 2, to: &deck)
        ProtobufWriter.appendVarint(0, field: 3, to: &deck)
        ProtobufWriter.appendMessage(sample, field: 4, to: &deck)
        ProtobufWriter.appendString("download-key", field: 5, to: &deck)

        var available = Data()
        ProtobufWriter.appendString("Japanese Core 1000: Step 1", field: 5, to: &available)
        ProtobufWriter.appendString("japanese  core vocab", field: 6, to: &available)
        ProtobufWriter.appendVarint(274_000, field: 7, to: &available)
        ProtobufWriter.appendVarint(1_461_200_000, field: 8, to: &available)
        ProtobufWriter.appendString("<b>Based on</b> iKnow.<br>Enjoy&nbsp;it.", field: 9, to: &available)
        if includeDeck {
            ProtobufWriter.appendMessage(deck, field: 10, to: &available)
        }
        ProtobufWriter.appendVarint(2, field: 18, to: &available)
        ProtobufWriter.appendVarint(1, field: 19, to: &available)
        ProtobufWriter.appendString("Core 1000 Step 1", field: 20, to: &available)

        var top = Data()
        ProtobufWriter.appendMessage(available, field: 1, to: &top)
        return top
    }

    func testItemInfoDecodesDeck() throws {
        guard case .deck(let deck) = try AnkiWebClient.itemInfo(id: 588_482_904, from: deckInfoMessage()) else {
            return XCTFail("expected a deck")
        }
        XCTAssertEqual(deck.id, 588_482_904)
        XCTAssertEqual(deck.title, "Japanese Core 1000: Step 1")
        XCTAssertEqual(deck.tags, ["japanese", "core", "vocab"])
        XCTAssertEqual(deck.size, 274_000)
        XCTAssertEqual(deck.lastUpdated?.timeIntervalSince1970, 1_461_200_000)
        XCTAssertEqual(deck.descriptionText, "Based on iKnow.\nEnjoy it.")
        XCTAssertEqual(deck.notes, 10)
        XCTAssertEqual(deck.audio, 3)
        XCTAssertEqual(deck.images, 0)
        XCTAssertEqual(deck.thumbsUp, 2)
        XCTAssertEqual(deck.thumbsDown, 1)
        XCTAssertEqual(deck.downloadKey, "download-key")
        XCTAssertEqual(deck.originalDeckName, "Core 1000 Step 1")
        XCTAssertEqual(deck.pageURL.absoluteString, "https://ankiweb.net/shared/info/588482904")

        let sample = try XCTUnwrap(deck.sampleNotes.first)
        XCTAssertEqual(sample.fields.map(\.name), ["Front", "Back", "Notes"])
        XCTAssertEqual(sample.values, ["する", "do, make[sound:0.mp3]"], "empty trailing field is dropped")
        XCTAssertEqual(HTMLText.plain(sample.values[1]), "do, make")
    }

    func testItemInfoWithoutDeckPayloadIsAnAddon() throws {
        guard case .addon(let title) = try AnkiWebClient.itemInfo(id: 1, from: deckInfoMessage(includeDeck: false)) else {
            return XCTFail("expected an add-on")
        }
        XCTAssertEqual(title, "Japanese Core 1000: Step 1")
    }

    func testItemInfoMissingAndDenied() throws {
        var missing = Data()
        ProtobufWriter.appendVarint(1, field: 2, to: &missing)
        guard case .missing = try AnkiWebClient.itemInfo(id: 1, from: missing) else {
            return XCTFail("expected .missing")
        }

        var denied = Data()
        ProtobufWriter.appendVarint(1, field: 3, to: &denied)
        guard case .accessDenied = try AnkiWebClient.itemInfo(id: 1, from: denied) else {
            return XCTFail("expected .accessDenied")
        }
    }

    func testItemInfoRejectsGarbage() {
        XCTAssertThrowsError(try AnkiWebClient.itemInfo(id: 1, from: Data([0xFF, 0xFF, 0xFF])))
    }

    // MARK: Errors

    func testErrorMapping() {
        let loginBody = Data("Please log in to download more decks.".utf8)
        XCTAssertEqual(
            AnkiWebClient.error(status: 429, body: loginBody, signedIn: false),
            .downloadLimitReached(signedIn: false)
        )
        XCTAssertEqual(
            AnkiWebClient.error(status: 429, body: loginBody, signedIn: true),
            .downloadLimitReached(signedIn: true)
        )
        // Live body observed from GET /svc/shared/list-decks when anonymous.
        let searchBody = Data("Please log in to perform more searches.".utf8)
        XCTAssertEqual(
            AnkiWebClient.error(status: 429, body: searchBody, signedIn: false),
            .searchLimitReached(signedIn: false)
        )
        XCTAssertEqual(AnkiWebClient.error(status: 429, body: nil, signedIn: false), .rateLimited)
        XCTAssertEqual(
            AnkiWebClient.error(status: 400, body: Data("Too many matches".utf8), signedIn: false),
            .tooManyMatches
        )
        XCTAssertEqual(AnkiWebClient.error(status: 500, body: nil, signedIn: false), .badStatus(500))
    }

    func testErrorMessagesAreUserFacing() {
        XCTAssertTrue(AnkiWebClient.ClientError.downloadLimitReached(signedIn: false).localizedDescription.contains("Sign in"))
        XCTAssertFalse(AnkiWebClient.ClientError.downloadLimitReached(signedIn: true).localizedDescription.contains("Sign in"))
        let searchLimit = AnkiWebClient.ClientError.searchLimitReached(signedIn: false).localizedDescription
        XCTAssertTrue(searchLimit.contains("search"), "search cap must not be described as a download cap")
        XCTAssertFalse(searchLimit.contains("download"))
        XCTAssertFalse(AnkiWebClient.ClientError.notADeck("AnkiConnect").localizedDescription.isEmpty)
    }

    // MARK: HTML

    func testPlainTextStripsMarkupEntitiesAndSoundTags() {
        let html = "<div>Hello&nbsp;<b>there</b></div><p>Second&amp;third</p>[sound:a.mp3]<img src=\"x.png\">"
        XCTAssertEqual(HTMLText.plain(html), "Hello there\nSecond&third")
    }
}

@MainActor
final class FlashcardPreviewTests: XCTestCase {
    private typealias Field = AnkiWebClient.SampleNote.Field

    func testSkipsIndexAndMediaFieldsForTheFront() {
        // Layout seen in popular Japanese decks: index first, media last.
        let note = AnkiWebClient.SampleNote(fields: [
            Field(name: "Index", value: "14"),
            Field(name: "Expression", value: "食べる"),
            Field(name: "Reading", value: "たべる"),
            Field(name: "Meaning", value: "to eat"),
            Field(name: "Sentence", value: "毎日<b>食べる</b>。"),
            Field(name: "Audio", value: "[sound:tabe.mp3]"),
            Field(name: "Image", value: "<img src=\"food.jpg\">"),
        ])
        let cards = FlashcardPreview.cards(from: [note])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].front.text, "食べる")
        XCTAssertEqual(cards[0].back.map(\.text), ["to eat", "たべる", "毎日食べる。"])
        XCTAssertEqual(cards[0].back.map(\.label), ["Meaning", "Reading", "Sentence"])
        XCTAssertEqual(cards[0].frontLanguage, "ja-JP")
    }

    func testFallsBackToFirstFieldWhenEverythingLooksLikeHousekeeping() {
        let note = AnkiWebClient.SampleNote(fields: [
            Field(name: "ID", value: "1001"),
            Field(name: "Rank", value: "7"),
        ])
        let cards = FlashcardPreview.cards(from: [note])
        XCTAssertEqual(cards[0].front.text, "1001")
        XCTAssertEqual(cards[0].back.map(\.text), ["7"])
    }

    /// Real layout from AnkiWeb deck 911122782 (Jlab): the prompt is buried
    /// after bookkeeping fields, with a dozen generated helper variants.
    func testJlabStyleNotePicksSentenceAndHidesGeneratedVariants() {
        let note = AnkiWebClient.SampleNote(fields: [
            Field(name: "Version", value: "14"),
            Field(name: "Sequence", value: "1600436800000"),
            Field(name: "Source", value: "Angel Beats! (JP Eng)"),
            Field(name: "Audio", value: "[sound:0.mp3]"),
            Field(name: "Image", value: "[image:1.jpg]"),
            Field(name: "RemarksFront", value: ""),
            Field(name: "RemarksBack", value: "What did you do! During class [I mean]."),
            Field(name: "QuestionLink", value: "link"),
            Field(name: "Other-Front", value: " 何[なに]\u{205F}やってた\u{205F}の\u{205F}よ\u{205F} 授[じゅ] 業[ぎょう] 中[ちゅう]\u{205F}に"),
            Field(name: "Jlab-Kanji", value: "何やってたのよ授業中に"),
            Field(name: "Jlab-KanjiSpaced", value: "何 やってた の よ 授業中 に"),
            Field(name: "Jlab-Hiragana", value: "なに やってた の よ じゅぎょうちゅう に"),
            Field(name: "Jlab-KanjiCloze", value: "何 やってた の よ 授業中 に"),
            Field(name: "Jlab-Lemma", value: "何 やる の よ 授業中 に"),
            Field(name: "Jlab-ListeningFront", value: "nani yatteta no yo jugyouchuu ni"),
            Field(name: "Jlab-ClozeBack", value: "nani yatteta no yo jugyouchuu ni"),
        ])
        let cards = FlashcardPreview.cards(from: [note])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].front.text, "何やってたのよ授業中に", "furigana and separators stripped")
        XCTAssertEqual(cards[0].back.map(\.label), ["Jlab-Hiragana", "RemarksBack"])
        XCTAssertEqual(cards[0].back[0].text, "なにやってたのよじゅぎょうちゅうに")
        XCTAssertEqual(cards[0].frontLanguage, "ja-JP")
    }

    func testFieldNameTokenizerSplitsCamelCaseAndSeparators() {
        XCTAssertEqual(FlashcardPreview.FieldRole.tokens(in: "Jlab-KanjiSpaced"), ["jlab", "kanji", "spaced"])
        XCTAssertEqual(FlashcardPreview.FieldRole.tokens(in: "RemarksBack"), ["remarks", "back"])
        XCTAssertEqual(FlashcardPreview.FieldRole.tokens(in: "Other_Front"), ["other", "front"])
        XCTAssertEqual(FlashcardPreview.FieldRole.tokens(in: "Core-Index"), ["core", "index"])
    }

    func testPreviewTextStripsFuriganaAndMediaTags() {
        XCTAssertEqual(FlashcardPreview.previewText(" 食[た]べる[image:x.jpg]"), "食べる")
        XCTAssertEqual(FlashcardPreview.previewText("class [I mean] during"), "class [I mean] during")
        XCTAssertEqual(FlashcardPreview.previewText("<b>hello</b> world"), "hello world")
    }

    func testEmptyNotesAreDroppedAndLimitApplies() {
        let empty = AnkiWebClient.SampleNote(fields: [Field(name: "Front", value: "<br>")])
        let real = (1...8).map { AnkiWebClient.SampleNote(fields: [Field(name: "Front", value: "Q\($0)"), Field(name: "Back", value: "A\($0)")]) }
        let cards = FlashcardPreview.cards(from: [empty] + real)
        XCTAssertEqual(cards.count, 6)
        XCTAssertEqual(cards.first?.front.text, "Q1")
        XCTAssertEqual(cards.map(\.id), Array(0..<6))
    }

    func testCardWithoutAnswerFieldStillPreviews() {
        let note = AnkiWebClient.SampleNote(fields: [Field(name: "Front", value: "Only side")])
        let cards = FlashcardPreview.cards(from: [note])
        XCTAssertEqual(cards[0].front.text, "Only side")
        XCTAssertEqual(cards[0].back.count, 1)
    }

    /// Core 2000 and Kaishi name the gloss "Vocabulary-English" / "Word Meaning".
    /// Those must be the back of the preview, not another prompt, and a part
    /// of speech like "nf" must not crowd out the translation.
    func testLanguageDeckFieldsPutTheWordInFrontAndTheGlossOnTheBack() {
        let core = AnkiWebClient.SampleNote(fields: [
            Field(name: "Optimized-Voc-Index", value: "1888"),
            Field(name: "Vocabulary-Kanji", value: "寂しい"),
            Field(name: "Vocabulary-Furigana", value: "寂[さび]しい"),
            Field(name: "Vocabulary-Kana", value: "さびしい"),
            Field(name: "Vocabulary-English", value: "lonely, desolate, sad"),
            Field(name: "Vocabulary-Audio", value: "[sound:0.mp3]"),
            Field(name: "Vocabulary-Pos", value: "Adjective"),
            Field(name: "Expression", value: "これは寂しい曲ですね。"),
            Field(name: "Reading", value: "これは 寂[さび]しい 曲[きょく]ですね。"),
        ])
        let card = try? XCTUnwrap(FlashcardPreview.cards(from: [core]).first)
        XCTAssertEqual(card?.front.text, "寂しい")
        XCTAssertEqual(card?.back.first?.text, "lonely, desolate, sad")

        let spanish = AnkiWebClient.SampleNote(fields: [
            Field(name: "Ranking", value: "4,201"),
            Field(name: "Spanish", value: "salsa"),
            Field(name: "Word Type", value: "nf"),
            Field(name: "English", value: "sauce, salsa"),
            Field(name: "Spanish Examples", value: "Me gusta la salsa."),
            Field(name: "Audio", value: "[sound:0.mp3]"),
        ])
        let preview = try? XCTUnwrap(FlashcardPreview.cards(from: [spanish]).first)
        XCTAssertEqual(preview?.front.text, "salsa")
        XCTAssertEqual(preview?.back.first?.text, "sauce, salsa")
        XCTAssertFalse(preview?.back.map(\.text).contains("nf") ?? true)
        XCTAssertFalse(preview?.back.map(\.text).contains("4,201") ?? true)
    }

    func testPreviewSkipsTheDeckReadmeAndKeepsTheCard() {
        let readme = AnkiWebClient.SampleNote(fields: [
            Field(name: "Front", value: String(repeating: "Please read this before you study. How to use this deck: download the audio, then start with the tutorial. ", count: 6)),
        ])
        let card = AnkiWebClient.SampleNote(fields: [
            Field(name: "Expression", value: "猫"),
            Field(name: "Meaning", value: "cat"),
        ])
        let cards = FlashcardPreview.cards(from: [readme, card])
        XCTAssertEqual(cards.first?.front.text, "猫")
    }

    func testKanjiOnlyFrontUsesJapaneseWhenTheCardHasKana() throws {
        let note = AnkiWebClient.SampleNote(fields: [
            Field(name: "Expression", value: "授業"),
            Field(name: "Reading", value: "じゅぎょう"),
            Field(name: "Meaning", value: "class"),
        ])
        let card = try XCTUnwrap(FlashcardPreview.cards(from: [note]).first)
        XCTAssertEqual(card.front.text, "授業")
        XCTAssertEqual(card.frontLanguage, "ja-JP")
        let runs = LanguageGuess.previewRuns(in: card.back.map(\.text).joined(separator: " "), cardHasKana: true)
        XCTAssertTrue(runs.map(\.locale).contains("ja-JP"))
        XCTAssertTrue(runs.map(\.locale).contains("en-US"))
    }

    func testPreviewDeckUsesOneJapaneseVoiceEvenWhenGlossesAreEnglish() {
        let mixed = [
            "授業", "class",
            "たべる", "to eat",
            "水", "water",
        ]
        XCTAssertEqual(LanguageGuess.previewDeckLocale(mixed), "ja-JP")
    }

    func testLanguageGuessMapsToRegionalTags() {
        XCTAssertEqual(LanguageGuess.locale(for: "こんにちは、元気ですか"), "ja-JP")
        XCTAssertEqual(LanguageGuess.locale(for: "Guten Morgen, wie geht es dir heute?"), "de-DE")
        XCTAssertEqual(LanguageGuess.locale(for: ""), "en-US")
        XCTAssertEqual(LanguageGuess.regionalTag(for: "ko", fallback: "en-US"), "ko-KR")
        XCTAssertEqual(LanguageGuess.regionalTag(for: "en", fallback: "en-GB"), "en-GB")
    }
}
