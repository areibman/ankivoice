import SwiftUI
import UIKit
import WebKit

/// The study card. Formatted HTML, furigana and math render as the card;
/// when that isn't the same as the words the voice reads, a second view
/// shows the spoken text exactly.
struct RenderedCardView: View {
    let face: SpeechRenderer.RenderedFace
    var mediaDirectory: URL?

    @State private var showSpoken = false
    @State private var webHeight: CGFloat = 72
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if face.readAloudDiffers {
                Picker("What to show", selection: $showSpoken) {
                    Text("Card").tag(false)
                    Text("Read aloud").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("session.cardView")
            }

            if showSpoken || !face.isRich {
                Text(displaySpoken)
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if showSpoken {
                    Text("This is exactly what the voice reads.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                CardWebView(
                    html: Self.document(face.html, css: face.css, cardClass: face.cardClass, scheme: colorScheme),
                    baseURL: mediaDirectory,
                    height: $webHeight
                )
                .frame(height: min(max(webHeight, 44), 420))
                .accessibilityLabel(displaySpoken)
            }
        }
    }

    private var displaySpoken: String {
        let trimmed = face.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(nothing to read on this side)" : trimmed
    }

    private static func document(_ body: String, css: String, cardClass: String, scheme: ColorScheme) -> String {
        let colorScheme = scheme == .dark ? "dark" : "light"
        let night = scheme == .dark ? " nightMode" : ""
        let deckCSS = css.replacingOccurrences(of: "</", with: "<\\/")
        return """
        <!DOCTYPE html>
        <html class="\(night.trimmingCharacters(in: .whitespaces))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        :root { color-scheme: \(colorScheme); }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
            font: -apple-system-body;
            font-size: 22px;
            line-height: 1.35;
            color: CanvasText;
            word-wrap: break-word;
        }
        ruby rt { font-size: 0.55em; }
        table { border-collapse: collapse; width: 100%; font-size: 0.85em; }
        td, th { border: 1px solid color-mix(in srgb, CanvasText 28%, transparent); padding: 4px 6px; vertical-align: top; }
        hr#answer { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 25%, transparent); margin: 0.6em 0; }
        .math {
            font-family: ui-serif, "Times New Roman", serif;
            background: color-mix(in srgb, CanvasText 8%, transparent);
            padding: 0.05em 0.35em;
            border-radius: 6px;
        }
        div.math { display: block; margin: 6px 0; padding: 6px 8px; }
        .anki-hint, .notes, .note { color: color-mix(in srgb, CanvasText 62%, transparent); font-size: 0.82em; }
        a { color: LinkText; }
        \(deckCSS)
        img, svg, video { max-width: 100%; height: auto; }
        </style>
        </head>
        <body><div class="\(cardClass)\(night)">\(body)</div></body>
        </html>
        """
    }
}

private struct CardWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        // Page scripts are stripped before load. JavaScript stays on only so
        // we can measure the rendered height.
        preferences.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = preferences
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeight = { measured in
            if abs(measured - height) > 1 { height = measured }
        }
        webView.overrideUserInterfaceStyle = webView.traitCollection.userInterfaceStyle
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onHeight: (CGFloat) -> Void = { _ in }
        var loadedHTML: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                let measured: CGFloat?
                if let number = value as? Double { measured = CGFloat(number) }
                else if let number = value as? Int { measured = CGFloat(number) }
                else { measured = nil }
                guard let measured else { return }
                DispatchQueue.main.async { self.onHeight(measured + 4) }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }
    }
}
