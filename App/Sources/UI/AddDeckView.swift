import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The one place decks come from.
///
/// Two big actions — browse AnkiWeb's shared decks, or import a file already
/// on the phone — plus a name field for starting an empty deck. Less common
/// sources (Anki on a computer, pasted text) sit behind a disclosure so they
/// don't compete for attention.
struct AddDeckView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var importing = false
    @State private var progressText: String?
    @State private var result: String?
    @State private var errorText: String?
    @State private var newDeckName = ""
    @State private var showMore = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    primaryActions
                    createSection
                    if importing || result != nil || errorText != nil {
                        statusCard
                    }
                    moreSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(importing)
                }
            }
            .interactiveDismissDisabled(importing)
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "apkg") ?? .zip,
                    UTType(filenameExtension: "colpkg") ?? .zip,
                    .commaSeparatedText,
                    .tabSeparatedText,
                    .plainText,
                    .zip,
                ],
                allowsMultipleSelection: false
            ) { outcome in
                switch outcome {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await importFile(url) }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: Primary actions

    private var primaryActions: some View {
        VStack(spacing: 12) {
            NavigationLink {
                AnkiWebSearchView()
            } label: {
                BigActionCard(
                    icon: "globe", tint: .blue,
                    title: "Browse shared decks",
                    subtitle: "Thousands of community decks on AnkiWeb — preview the cards, import in one tap"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("adddeck.browse")

            Button {
                showPicker = true
            } label: {
                BigActionCard(
                    icon: "square.and.arrow.down", tint: .green,
                    title: "Import a file",
                    subtitle: "An .apkg exported from Anki, or a CSV / TSV spreadsheet"
                )
            }
            .buttonStyle(.plain)
            .disabled(importing)
            .accessibilityIdentifier("adddeck.import")
        }
    }

    // MARK: Create

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or start from scratch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            HStack(spacing: 10) {
                TextField("Deck name", text: $newDeckName)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(createDeck)
                    .accessibilityIdentifier("adddeck.name")
                Button("Create", action: createDeck)
                    .buttonStyle(.borderedProminent)
                    .disabled(newDeckName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("adddeck.create")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Use :: to nest, e.g. Japanese::Vocabulary. Add cards from the deck page.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progressText ?? "Importing…")
                        .foregroundStyle(.secondary)
                }
            }
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: More

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { showMore.toggle() }
            } label: {
                HStack {
                    Text("More ways to add decks")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showMore ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("adddeck.more")

            if showMore {
                VStack(spacing: 0) {
                    NavigationLink {
                        AnkiConnectImportView()
                    } label: {
                        SmallOptionRow(
                            icon: "desktopcomputer", tint: .purple,
                            title: "Anki on your computer",
                            subtitle: "Copy decks with review history over Wi‑Fi"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("adddeck.ankiconnect")
                    Divider().padding(.leading, 56)
                    NavigationLink {
                        PasteImportView { summary in result = summary }
                    } label: {
                        SmallOptionRow(
                            icon: "doc.on.clipboard", tint: .orange,
                            title: "Paste text",
                            subtitle: "One card per line: front, back, tags"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Actions

    private func createDeck() {
        let name = newDeckName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try services.decks.create(fullName: name)
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFile(_ url: URL) async {
        importing = true
        errorText = nil
        result = nil
        progressText = "Opening \(url.lastPathComponent)…"
        defer { importing = false; progressText = nil }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let apkg = ApkgImporter(decks: services.decks, cards: services.cards, reviews: services.reviews)
            let delimited = DelimitedTextImporter(cards: services.cards, decks: services.decks)
            let ext = url.pathExtension.lowercased()
            let isPackage = ext.hasPrefix("apkg") || ext == "colpkg" || ext == "zip"
            let report: ApkgImporter.ProgressHandler = { _, message in
                Task { @MainActor in progressText = message }
            }
            let summary: String = try await Task.detached(priority: .userInitiated) {
                if isPackage {
                    let s = try apkg.importPackage(at: url, progress: report)
                    return "Imported \(s.notesImported) notes, \(s.cardsImported) cards, \(s.reviewsImported) reviews"
                        + (s.mediaImported > 0 ? ", \(s.mediaImported) media files." : ".")
                } else {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let name = url.deletingPathExtension().lastPathComponent
                    let s = try delimited.importText(text, intoDeck: name, hasHeader: false)
                    return "Imported \(s.notesImported) cards into “\(name)”"
                        + (s.notesSkipped > 0 ? " (\(s.notesSkipped) rows skipped)." : ".")
                }
            }.value
            result = summary
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
        } catch {
            result = nil
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Rows

/// Large tappable card for the two primary ways of adding a deck.
struct BigActionCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Compact row used for the secondary options.
struct SmallOptionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Paste CSV/TSV text and import it into a named deck.
struct PasteImportView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let onImported: (String) -> Void

    @State private var text = ""
    @State private var deckName = "Imported"
    @State private var hasHeader = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("Deck name", text: $deckName)
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .font(.body.monospaced())
                Toggle("First row is a header", isOn: $hasHeader)
            } header: {
                Text("Cards")
            } footer: {
                Text("One card per line: front, back, tags. Commas, tabs and semicolons are detected automatically; quotes follow CSV rules.")
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button {
                    importPasted()
                } label: {
                    Text("Import")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || deckName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Paste text")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func importPasted() {
        do {
            let importer = DelimitedTextImporter(cards: services.cards, decks: services.decks)
            let summary = try importer.importText(text, intoDeck: deckName, hasHeader: hasHeader)
            onImported("Imported \(summary.notesImported) cards into “\(deckName)”"
                       + (summary.notesSkipped > 0 ? " (\(summary.notesSkipped) rows skipped)." : "."))
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
