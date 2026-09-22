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
        let (text, media) = SpeechRenderer.extract(html: "猫 [sound:neko.mp3]", clozeAnswer: false)
        XCTAssertEqual(media, ["neko.mp3"])
        XCTAssertTrue(text.hasPrefix("猫"))
        XCTAssertFalse(text.contains("sound"))

        let rendered = renderer.render(card, questionLocale: "ja-JP", answerLocale: "en-US")
        XCTAssertEqual(rendered.question.first, .media(filename: "neko.mp3"))
        XCTAssertTrue(rendered.question.contains(.speech(text: "猫", locale: "ja-JP")))
    }

    /// An audio-only side must still play its recording rather than render as silence.
    func testAudioOnlySideRendersMediaOnly() {
        let rendered = renderer.render(
            makeCard(front: "[sound:word.mp3]", back: "Answer"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.question, [.media(filename: "word.mp3")])
    }

    func testImageOnlySideHasNothingToSpeak() {
        let rendered = renderer.render(
            makeCard(front: "<img src=\"anatomy.png\">", back: "The heart"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertTrue(rendered.question.isEmpty)
        XCTAssertEqual(rendered.answer, [.speech(text: "The heart", locale: "en-US")])
    }

    func testScriptAndStyleBodiesAreNotSpoken() {
        let rendered = renderer.render(
            makeCard(front: "<style>.x{color:red}</style>Question<script>alert(1)</script>", back: "x"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertEqual(rendered.question, [.speech(text: "Question", locale: "en-US")])
        XCTAssertEqual(HTMLText.plain("<style>.x{color:red}</style>Question<script>alert(1)</script>"), "Question")
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

    /// Phrase decks put a section title ("Asking for things") on the front
    /// next to the sentence. The title is not the card.
    func testLessonHeadingIsNotSpokenInsteadOfTheSentence() {
        let type = NoteType(
            id: 12, name: "Phrases",
            fieldNames: ["Lesson", "Sentence", "Translation"],
            templates: [NoteTemplate(
                name: "Card 1",
                questionFormat: "<div class=\"lesson\">{{Lesson}}</div>{{Sentence}}",
                answerFormat: "{{Translation}}",
                ordinal: 0
            )],
            kind: .standard
        )
        let note = Note(
            id: 1, noteTypeID: 12,
            fields: ["Asking for things", "Could I have a menu, please?", "メニューをお願いできますか。"],
            tags: [], guid: "g"
        )
        let deck = Deck(id: 1, name: "D", fullName: "Phrases::Asking for things", parentID: nil)
        let card = StudyCard(card: Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0), note: note, noteType: type, deck: deck)
        let question = engineText(renderer.render(card, questionLocale: "en-US", answerLocale: "ja-JP").question)
        XCTAssertEqual(question, "Could I have a menu, please?")
        XCTAssertFalse(question.localizedCaseInsensitiveContains("asking for things"))
    }

    /// Portuguese Everyday v2. Topic is the section label ("Asking for things").
    /// Understand asks the Portuguese line; Speak asks the English line.
    /// The example on the back must not replace the answer.
    func testPortugueseEverydaySpeaksThePromptNotTheTopic() {
        let fields = [
            "ptbr-everyday-001", "Por favor.", "Please.",
            "Say this in Brazilian Portuguese.", "Um café, por favor.", "A coffee, please.",
            "Add this to a request.", "", "Asking for things", "phrase", "", "",
        ]
        let names = [
            "ID", "Portuguese", "English", "Cue", "ExamplePortuguese", "ExampleEnglish",
            "Usage", "Alternatives", "Topic", "Kind", "AudioPortuguese", "AudioExample",
        ]
        let understand = NoteTemplate(
            name: "Understand",
            questionFormat: "<div class=\"meta\">{{Topic}} · Understand</div><div class=\"prompt\">{{Portuguese}}</div>{{#AudioPortuguese}}{{AudioPortuguese}}{{/AudioPortuguese}}<div class=\"cue\">What does this mean in English?</div>",
            answerFormat: "{{FrontSide}}<hr>{{English}}{{#ExamplePortuguese}}<div class=\"label\">Example</div>{{ExamplePortuguese}}{{ExampleEnglish}}{{/ExamplePortuguese}}{{#Usage}}{{Usage}}{{/Usage}}",
            ordinal: 0
        )
        let speak = NoteTemplate(
            name: "Speak",
            questionFormat: "<div class=\"meta\">{{Topic}} · Speak</div><div class=\"prompt\">{{English}}</div><div class=\"cue\">{{Cue}}</div>",
            answerFormat: "{{FrontSide}}<hr><div class=\"answer\">{{Portuguese}}</div>{{#ExamplePortuguese}}<div class=\"label\">Example</div>{{ExamplePortuguese}}{{ExampleEnglish}}{{/ExamplePortuguese}}",
            ordinal: 1
        )
        let type = NoteType(id: 13, name: "Brazilian Portuguese - Everyday v2", fieldNames: names, templates: [understand, speak], kind: .standard)
        let note = Note(id: 1, noteTypeID: 13, fields: fields, tags: [], guid: "g")
        let deck = Deck(id: 1, name: "Portuguese", fullName: "Portuguese - Everyday Brazilian Portuguese v2", parentID: nil)
        func card(_ ordinal: Int) -> StudyCard {
            StudyCard(card: Card(id: Int64(ordinal + 1), noteID: 1, deckID: 1, templateOrdinal: ordinal), note: note, noteType: type, deck: deck)
        }

        let understandQ = engineText(renderer.render(card(0), questionLocale: "pt-BR", answerLocale: "en-US").question)
        let understandA = engineText(renderer.render(card(0), questionLocale: "pt-BR", answerLocale: "en-US").answer)
        XCTAssertEqual(understandQ, "Por favor.")
        XCTAssertEqual(understandA, "Please.")

        let speakQ = engineText(renderer.render(card(1), questionLocale: "en-US", answerLocale: "pt-BR").question)
        let speakA = engineText(renderer.render(card(1), questionLocale: "en-US", answerLocale: "pt-BR").answer)
        XCTAssertEqual(speakQ, "Please.")
        XCTAssertFalse(speakQ.contains("Asking for things"))
        XCTAssertFalse(speakQ.contains("Say this in Brazilian Portuguese"))
        XCTAssertEqual(speakA, "Por favor.")
        XCTAssertFalse(speakA.contains("Um café"))
    }

    /// Core 2000-style templates bury the word under an index, part of speech,
    /// notes, and a static "about this deck" caption. Voice reads the word
    /// and the meaning only.
    func testCoreDeckSpeaksWordAndMeaningNotMetadata() {
        let type = NoteType(
            id: 11, name: "Japanese",
            fieldNames: ["Optimized-Voc-Index", "Vocabulary-Kanji", "Vocabulary-Kana", "Vocabulary-English", "Vocabulary-Pos", "Notes"],
            templates: [NoteTemplate(
                name: "Recognition",
                questionFormat: "<div class=\"index\">Core {{Optimized-Voc-Index}}</div>{{Vocabulary-Kanji}}",
                answerFormat: "{{Vocabulary-Kana}}<hr>{{Vocabulary-English}}<div>{{Vocabulary-Pos}}</div><div class=\"notes\">{{Notes}}</div><div>This deck is based on the iKnow core list.</div>",
                ordinal: 0
            )],
            kind: .standard
        )
        let note = Note(
            id: 1, noteTypeID: 11,
            fields: ["14", "食べる", "たべる", "to eat", "noun", "Frequency rank from the shared deck. Please read the tutorial."],
            tags: [], guid: "g"
        )
        let deck = Deck(id: 1, name: "D", fullName: "Japanese::Core 2000", parentID: nil)
        let card = StudyCard(card: Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0), note: note, noteType: type, deck: deck)
        let rendered = renderer.render(card, questionLocale: "ja-JP", answerLocale: "en-US")
        let question = engineText(rendered.question)
        let answer = engineText(rendered.answer)
        XCTAssertEqual(question, "食べる")
        XCTAssertEqual(answer, "to eat")
        XCTAssertFalse(question.contains("14") || question.lowercased().contains("core"))
        XCTAssertFalse(answer.lowercased().contains("noun"))
        XCTAssertFalse(answer.lowercased().contains("iknow"))
        XCTAssertFalse(answer.lowercased().contains("tutorial"))
    }

    func testJapaneseTemplateSpeaksTheWordNotTheNotes() {
        let card = makeJapaneseCard()
        let rendered = renderer.render(card, questionLocale: "ja-JP", answerLocale: "en-US")
        let question = engineText(rendered.question)
        let answer = engineText(rendered.answer)
        XCTAssertTrue(question.contains("たべる"), "furigana should be spoken as the reading, got \(question)")
        XCTAssertFalse(question.lowercased().contains("download"), "question must not be the deck tutorial")
        XCTAssertTrue(answer.lowercased().contains("to eat"), "got \(answer)")
        XCTAssertFalse(answer.lowercased().contains("tutorial"))
        XCTAssertFalse(answer.lowercased().contains("download"))

        let face = renderer.face(card, side: .question, questionLocale: "ja-JP", answerLocale: "en-US")
        XCTAssertTrue(face.html.contains("<ruby>"), "the card should show the kanji with its reading")
        XCTAssertTrue(face.readAloudDiffers)
        XCTAssertTrue(face.spokenText.contains("たべる"))
    }

    func testConditionalHidesEmptyNotesAndShowsTheWord() {
        let type = NoteType(
            id: 8, name: "J",
            fieldNames: ["Expression", "Notes"],
            templates: [NoteTemplate(
                name: "Card 1",
                questionFormat: "{{#Notes}}See the notes. {{Notes}}{{/Notes}}{{Expression}}",
                answerFormat: "{{Expression}}",
                ordinal: 0
            )],
            kind: .standard
        )
        let note = Note(id: 1, noteTypeID: 8, fields: ["猫", ""], tags: [], guid: "g")
        let deck = Deck(id: 1, name: "D", fullName: "D", parentID: nil)
        let card = StudyCard(card: Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0), note: note, noteType: type, deck: deck)
        let question = engineText(renderer.render(card, questionLocale: "ja-JP", answerLocale: "en-US").question)
        XCTAssertEqual(question, "猫")
        XCTAssertFalse(question.contains("notes"))
    }

    func testLatexIsSpokenAndMarkedAsDifferentFromTheCard() {
        let rendered = renderer.render(
            makeCard(front: "[$]E=mc^2[/$]", back: "mass-energy"),
            questionLocale: "en-US", answerLocale: "en-US"
        )
        let spoken = engineText(rendered.question)
        XCTAssertTrue(spoken.contains("equals"), spoken)
        XCTAssertTrue(spoken.contains("squared"), spoken)
        XCTAssertFalse(spoken.contains("[$]"))
        let face = renderer.face(
            makeCard(front: "[$]E=mc^2[/$]", back: "mass-energy"),
            side: .question, questionLocale: "en-US", answerLocale: "en-US"
        )
        XCTAssertTrue(face.html.contains("class=\"math\""))
        XCTAssertTrue(face.readAloudDiffers)
        XCTAssertFalse(face.html.contains("[$]"))
    }

    func testMixedLanguageAnswerUsesEachVoice() {
        let runs = LanguageGuess.scriptRuns(in: "たべる to eat", fallback: "en-US", cardHasKana: true)
        XCTAssertEqual(runs.map(\.text), ["たべる", "to eat"])
        XCTAssertEqual(runs.map(\.locale), ["ja-JP", "en-US"])
        let kanji = LanguageGuess.scriptRuns(in: "授業", fallback: "en-US", cardHasKana: true)
        XCTAssertEqual(kanji.first?.locale, "ja-JP", "kanji on a kana card must not be handed to a Chinese voice")
    }

    private func makeJapaneseCard() -> StudyCard {
        let type = NoteType(
            id: 7, name: "Japanese",
            fieldNames: ["Expression", "Meaning", "Reading", "Notes"],
            templates: [NoteTemplate(
                name: "Recognition",
                questionFormat: "{{furigana:Expression}}",
                answerFormat: "{{kana:Reading}}<hr>{{Meaning}}<div class=\"notes\">{{Notes}}</div>",
                ordinal: 0
            )],
            kind: .standard
        )
        let note = Note(
            id: 1, noteTypeID: 7,
            fields: [
                "食[た]べる",
                "to eat",
                "たべる",
                "Please read this before studying. Download the audio for this deck. How to use this deck: finish the tutorial first.",
            ],
            tags: [], guid: "g"
        )
        let deck = Deck(id: 1, name: "D", fullName: "D", parentID: nil)
        return StudyCard(
            card: Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0),
            note: note, noteType: type, deck: deck
        )
    }

    private func engineText(_ segments: [SpeechRenderer.Segment]) -> String {
        segments.compactMap {
            if case .speech(let text, _) = $0 { return text }
            return nil
        }.joined(separator: " ")
    }

    /// Hiragana decks put {{type:Back}} on the front and [sound:] in the answer.
    /// The answer must not appear on the question, and the sound tag must not
    /// be printed. The deck's CSS travels with the face so the study view can
    /// center a 60pt character the way the template asks.
    func testTypingBoxAndSoundTagsDoNotBecomeCardText() {
        let type = NoteType(
            id: 8, name: "Basic Card",
            fieldNames: ["Front", "Back"],
            templates: [NoteTemplate(
                name: "Japanese Character",
                questionFormat: "{{Front}}<br>{{type:Back}}",
                answerFormat: "{{FrontSide}}<hr id=answer>{{Back}}",
                ordinal: 0
            )],
            kind: .standard,
            css: ".card { font-size: 60px; text-align: center; color: black; background-color: white; }"
        )
        let note = Note(id: 1, noteTypeID: 8, fields: ["け", "ke[sound:0.mp3]"], tags: [], guid: "g")
        let deck = Deck(id: 1, name: "D", fullName: "D", parentID: nil)
        let card = StudyCard(
            card: Card(id: 1, noteID: 1, deckID: 1, templateOrdinal: 0),
            note: note, noteType: type, deck: deck
        )
        let question = renderer.face(card, side: .question, questionLocale: "ja-JP", answerLocale: "ja-JP")
        XCTAssertTrue(question.html.contains("け"))
        XCTAssertFalse(question.html.contains("ke"), "typing the answer must not print it on the front")
        XCTAssertFalse(question.html.contains("[sound:"))
        XCTAssertTrue(question.css.contains("font-size: 60px"))
        XCTAssertEqual(question.cardClass, "card card1")

        let answer = renderer.face(card, side: .answer, questionLocale: "ja-JP", answerLocale: "ja-JP")
        XCTAssertTrue(answer.html.contains("け"))
        XCTAssertTrue(answer.html.contains("ke"))
        XCTAssertFalse(answer.html.contains("[sound:"))
    }
}

final class SpokenFieldPlannerTests: XCTestCase {

    func testRepeatedTopicIsSkippedAndTheChangingLineIsRead() {
        let question = "<div class=\"meta\">{{Topic}} · Understand</div><div class=\"prompt\">{{Portuguese}}</div>"
        let answer = "{{FrontSide}}<hr>{{English}}{{#ExamplePortuguese}}{{ExamplePortuguese}}{{/ExamplePortuguese}}"
        var samples: [String: [String]] = [
            "Topic": [], "Portuguese": [], "English": [], "ExamplePortuguese": [], "Cue": [],
        ]
        let phrases = ["Por favor.", "Obrigado.", "Com licença.", "Desculpa.", "Eu queria um café."]
        let english = ["Please.", "Thank you.", "Excuse me.", "Sorry.", "I'd like a coffee."]
        for index in phrases.indices {
            samples["Topic", default: []].append("Asking for things")
            samples["Portuguese", default: []].append(phrases[index])
            samples["English", default: []].append(english[index])
            samples["ExamplePortuguese", default: []].append(index == 0 ? "Um café, por favor." : "")
            samples["Cue", default: []].append("Say this in Brazilian Portuguese.")
        }
        XCTAssertEqual(
            SpokenFieldPlanner.choose(shown: SpokenFieldPlanner.fields(in: question), samples: samples),
            ["Portuguese"]
        )
        XCTAssertEqual(
            SpokenFieldPlanner.choose(shown: SpokenFieldPlanner.fields(in: answer), samples: samples),
            ["English"]
        )
        let speakQuestion = "<div class=\"meta\">{{Topic}} · Speak</div>{{English}}<div class=\"cue\">{{Cue}}</div>"
        let speakAnswer = "{{Portuguese}}{{#ExamplePortuguese}}{{ExamplePortuguese}}{{/ExamplePortuguese}}"
        XCTAssertEqual(
            SpokenFieldPlanner.choose(shown: SpokenFieldPlanner.fields(in: speakQuestion), samples: samples),
            ["English"]
        )
        XCTAssertEqual(
            SpokenFieldPlanner.choose(shown: SpokenFieldPlanner.fields(in: speakAnswer), samples: samples),
            ["Portuguese"]
        )
    }

    func testANumberThatChangesEveryCardIsNotRead() {
        let shown = SpokenFieldPlanner.fields(in: "Core {{Index}} {{Kanji}}")
        var samples = ["Index": [String](), "Kanji": [String]()]
        for n in 1...8 {
            samples["Index", default: []].append("\(n)")
            samples["Kanji", default: []].append("字\(n)")
        }
        XCTAssertEqual(SpokenFieldPlanner.choose(shown: shown, samples: samples), ["Kanji"])
    }
}

final class CommandRecognizerTests: XCTestCase {
    private let recognizer = CommandRecognizer()

    private func rating(_ transcript: String) -> CommandRecognizer.Command? {
        recognizer.recognize(transcript: transcript, phase: .awaitingRating)?.command
    }

    func testCanonicalRatings() {
        for (word, command) in [("again", CommandRecognizer.Command.again), ("hard", .hard), ("good", .good), ("easy", .easy)] {
            XCTAssertEqual(rating(word), command)
        }
    }

    func testAliases() {
        XCTAssertEqual(rating("wrong"), .again)
        XCTAssertEqual(rating("forgot"), .again)
        XCTAssertEqual(rating("difficult"), .hard)
        XCTAssertEqual(rating("Good."), .good, "punctuation stripped")
    }

    func testRatingWithFillers() {
        XCTAssertEqual(rating("um good"), .good)
        XCTAssertEqual(rating("okay easy please"), .easy)
    }

    func testLongUtteranceIsNotARating() {
        XCTAssertNil(rating("I think it was the mitochondria powerhouse of the cell"))
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
