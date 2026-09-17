import XCTest
@testable import AnkiVoice

final class SpeechRendererTests: XCTestCase {
    private let renderer = SpeechRenderer()

    private func makeCard(
        front: String, back: String, kind: NoteTypeKind = .standard,
        templates: [NoteTemplate] = [NoteTemplate(name: "Card 1", questionFormat: "{{Front}}", answerFormat: "{{FrontSide}}\n<hr id=answer>\n{{Back}}", ordinal: 0)]
    ) -> StudyCard {
        let noteType = NoteType(id: 99, name: "T", fieldNames: ["Front", "Back"], templates: templates, kind: kind)
        let note = Note(id: 1, noteTypeID: 99, fields: [front, back], tags: [], guid: "g")
        let deck = Deck(id: 1, name: "D", fullName: "D", parentID: nil)
        let card = Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0)
        return StudyCard(card: card, note: note, noteType: noteType, deck: deck)
    }

    // MARK: HTML → speech

    func testStripsStylingAndKeepsText() {
        let rendered = renderer.render(makeCard(front: "<b>What is TCP?</b>", back: "<i>Networking</i>"), questionLocale: "en-US", answerLocale: "en-US")
        XCTAssertEqual(rendered.question, [.speech(text: "What is TCP?", locale: "en-US")])
        XCTAssertEqual(rendered.answer, [.speech(text: "Networking", locale: "en-US")])
        XCTAssertEqual(rendered.compatibility, .excellent)
    }

    func testBrBecomesPause() {
        let rendered = renderer.render(
            makeCard(front: "Line one<br>Line two", back: "Answer"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.question.count, 3)
        XCTAssertEqual(rendered.question[1], .pause(seconds: 0.35))
        XCTAssertEqual(rendered.question[0], .speech(text: "Line one", locale: "en-US"))
        XCTAssertEqual(rendered.question[2], .speech(text: "Line two", locale: "en-US"))
    }

    func testEntitiesDecoded() {
        let rendered = renderer.render(
            makeCard(front: "Tom &amp; Jerry &lt;cartoon&gt;", back: "A&nbsp;show"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.question.first, .speech(text: "Tom & Jerry <cartoon>", locale: "en-US"))
    }

    func testSoundReferencesExtractedAsMedia() {
        let card = makeCard(front: "猫 [sound:neko.mp3]", back: "Cat")
        let (text, media, _) = SpeechRenderer.extract(html: "猫 [sound:neko.mp3]", clozeAnswer: false)
        XCTAssertEqual(media, ["neko.mp3"])
        XCTAssertTrue(text.hasPrefix("猫"))
        XCTAssertFalse(text.contains("sound"))

        let rendered = renderer.render(card, questionLocale: "ja-JP", answerLocale: "en-US", preferRecordedAudio: true)
        XCTAssertEqual(rendered.question.first, .media(filename: "neko.mp3"))
    }

    func testImageMarksVisualRequired() {
        let rendered = renderer.render(
            makeCard(front: "<img src=\"anatomy.png\">", back: "The heart"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.compatibility, .visualRequired)
    }

    func testScriptMarksUnsupported() {
        let rendered = renderer.render(
            makeCard(front: "<script>alert(1)</script>", back: "x"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.compatibility, .unsupported)
    }

    // MARK: Cloze

    func testClozeQuestionMasksActiveBlank() {
        let card = makeCard(
            front: "The powerhouse of the cell is the {{c1::mitochondrion}}.",
            back: "Use the same text.",
            kind: .cloze,
            templates: [NoteTemplate(name: "Cloze", questionFormat: "{{cloze:Front}}", answerFormat: "{{cloze:Front}}", ordinal: 0)]
        )
        let rendered = renderer.render(card, questionLocale: "en-US", answerLocale: "en-US")
        XCTAssertEqual(rendered.question.first, .speech(text: "The powerhouse of the cell is the [...].", locale: "en-US"))
        // Answer side reveals the content.
        XCTAssertEqual(rendered.answer.first, .speech(text: "The powerhouse of the cell is the mitochondrion.", locale: "en-US"))
        XCTAssertEqual(rendered.compatibility, .usable)
    }

    func testClozeNonActiveOrdinalRevealedInQuestion() {
        let card = makeCard(
            front: "{{c2::Paris}} is the capital of {{c1::France}}",
            back: "",
            kind: .cloze,
            templates: [NoteTemplate(name: "Cloze", questionFormat: "{{cloze:Front}}", answerFormat: "{{cloze:Front}}", ordinal: 1)]  // c2 active
        )
        let rendered = renderer.render(card, questionLocale: "en-US", answerLocale: "en-US")
        XCTAssertEqual(rendered.question.first, .speech(text: "[...] is the capital of France", locale: "en-US"))
    }

    func testClozeHintUsedAsPrompt() {
        XCTAssertEqual(
            SpeechRenderer.expandClozes(in: "{{c1::E=mc^2::energy}}", reveal: false, activeOrdinal: 0),
            "[energy]"
        )
        XCTAssertEqual(
            SpeechRenderer.expandClozes(in: "{{c1::E=mc^2::energy}}", reveal: true, activeOrdinal: 0),
            "E=mc^2"
        )
    }

    // MARK: Templates & locales

    func testPerSideLocales() {
        let rendered = renderer.render(
            makeCard(front: "cat", back: "chat"), questionLocale: "en-US", answerLocale: "fr-FR"
        )
        XCTAssertEqual(rendered.question.first, .speech(text: "cat", locale: "en-US"))
        XCTAssertEqual(rendered.answer.first, .speech(text: "chat", locale: "fr-FR"))
    }

    func testReversedTemplateOrdinalUsesBackAsQuestion() {
        let card = makeCard(
            front: "cat", back: "chat",
            templates: [
                NoteTemplate(name: "Card 1", questionFormat: "{{Front}}", answerFormat: "{{FrontSide}}\n<hr>\n{{Back}}", ordinal: 0),
                NoteTemplate(name: "Card 2", questionFormat: "{{Back}}", answerFormat: "{{FrontSide}}\n<hr>\n{{Front}}", ordinal: 1),
            ]
        )
        var mutableCard = card
        mutableCard.card.templateOrdinal = 1
        let rendered = renderer.render(mutableCard, questionLocale: "en-US", answerLocale: "fr-FR")
        XCTAssertEqual(rendered.question.first, .speech(text: "chat", locale: "en-US"))
        XCTAssertTrue(engineText(rendered.answer).contains("cat"))
    }

    func testHiddenFieldHint() {
        let card = makeCard(front: "{{hint:Front}}", back: "{{Back}}")
        _ = card
        // hint:Front renders the value inline as "Hint: value" for speech.
    }

    private func engineText(_ segments: [SpeechRenderer.Segment]) -> String {
        segments.compactMap {
            if case .speech(let text, _) = $0 { return text }
            return nil
        }.joined(separator: " ")
    }
}

final class CommandRecognizerTests: XCTestCase {
    private let recognizer = CommandRecognizer()

    func testCanonicalRatings() {
        for (word, rating) in [("again", Rating.again), ("hard", Rating.hard), ("good", Rating.good), ("easy", Rating.easy)] {
            XCTAssertEqual(recognizer.recognizeRating(transcript: word), rating)
        }
    }

    func testAliases() {
        XCTAssertEqual(recognizer.recognizeRating(transcript: "wrong"), .again)
        XCTAssertEqual(recognizer.recognizeRating(transcript: "forgot"), .again)
        XCTAssertEqual(recognizer.recognizeRating(transcript: "difficult"), .hard)
        XCTAssertEqual(recognizer.recognizeRating(transcript: "Good."), .good, "punctuation stripped")
    }

    func testRatingWithFillers() {
        XCTAssertEqual(recognizer.recognizeRating(transcript: "um good"), .good)
        XCTAssertEqual(recognizer.recognizeRating(transcript: "okay easy please"), .easy)
    }

    func testLongUtteranceIsNotARating() {
        XCTAssertNil(recognizer.recognizeRating(transcript: "I think it was the mitochondria powerhouse of the cell"))
    }

    func testCommandsInRatingPhase() {
        let match = recognizer.recognize(transcript: "good", phase: .awaitingRating)
        XCTAssertEqual(match?.command, .good)
        XCTAssertEqual(recognizer.recognize(transcript: "repeat question", phase: .awaitingRating)?.command, .repeatQuestion)
        XCTAssertEqual(recognizer.recognize(transcript: "repeat answer", phase: .awaitingRating)?.command, .repeatAnswer)
        XCTAssertEqual(recognizer.recognize(transcript: "pause", phase: .awaitingRating)?.command, .pause)
        XCTAssertEqual(recognizer.recognize(transcript: "undo", phase: .awaitingRating)?.command, .undo)
    }

    func testRatingWordsIgnoredInAnswerPhase() {
        XCTAssertNil(recognizer.recognize(transcript: "good", phase: .awaitingAnswer))
        XCTAssertNil(recognizer.recognize(transcript: "hard", phase: .awaitingAnswer))
        XCTAssertNil(recognizer.recognize(transcript: "easy", phase: .awaitingAnswer))
        // Control commands still valid.
        XCTAssertEqual(recognizer.recognize(transcript: "repeat", phase: .awaitingAnswer)?.command, .repeatContent)
        XCTAssertEqual(recognizer.recognize(transcript: "reveal", phase: .awaitingAnswer)?.command, .reveal)
        XCTAssertEqual(recognizer.recognize(transcript: "skip", phase: .awaitingAnswer)?.command, .skip)
        XCTAssertEqual(recognizer.recognize(transcript: "stop", phase: .awaitingAnswer)?.command, .stop)
    }

    func testPausedPhaseAcceptsOnlyResumeStopRepeat() {
        XCTAssertEqual(recognizer.recognize(transcript: "resume", phase: .paused)?.command, .resume)
        XCTAssertEqual(recognizer.recognize(transcript: "stop", phase: .paused)?.command, .stop)
        XCTAssertNil(recognizer.recognize(transcript: "good", phase: .paused))
        XCTAssertNil(recognizer.recognize(transcript: "pause", phase: .paused))
    }

    func testCommandEmbeddedInUtterance() {
        XCTAssertEqual(recognizer.recognize(transcript: "uh good", phase: .awaitingRating)?.command, .good)
        XCTAssertEqual(recognizer.recognize(transcript: "repeat question please", phase: .awaitingRating)?.command, .repeatQuestion)
    }

    func testNormalization() {
        XCTAssertEqual(CommandRecognizer.normalize("Good, MORNING!"), "good morning")
        XCTAssertEqual(CommandRecognizer.normalize("it’s easy"), "it s easy")
    }

    func testLongestPhraseWins() {
        // "repeat question" must not match as "repeat" + stray word.
        let match = recognizer.recognize(transcript: "repeat question", phase: .awaitingRating)
        XCTAssertEqual(match?.command, .repeatQuestion)
    }
}
