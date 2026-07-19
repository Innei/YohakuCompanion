import AppKit
import SwiftUI

struct MomentComposerView: View {
    @StateObject private var model: MomentComposerViewModel

    init(model: @autoclosure @escaping () -> MomentComposerViewModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Publish This Moment")
                    .font(.title2.weight(.semibold))
                Text("A fixed, privacy-sanitized snapshot will be published publicly to \(model.targetDescription).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.phase == .loading || model.phase == .publishing)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Capturing a sanitized snapshot…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .published(let id, let url):
            resultView(
                symbol: "checkmark.circle.fill",
                title: "Moment Published",
                message: "Recently #\(id) is now public.",
                symbolColor: .green,
                actionTitle: url == nil ? nil : "Open Yohaku",
                action: model.openPublishedURL
            )

        case .queued:
            resultView(
                symbol: "clock.arrow.circlepath",
                title: "Saved for Publishing",
                message: "The Moment is stored locally and will be retried automatically.",
                symbolColor: .orange,
                actionTitle: nil,
                action: {}
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Label("Publishing Unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Return to Composer") { model.returnToEditing() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(28)

        case .editing, .publishing:
            composer
        }
    }

    private var composer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Note")
                        .font(.headline)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.content)
                            .font(.body)
                            .frame(minHeight: 116)
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .background(.background)
                            .accessibilityLabel("Moment note")
                        if model.content.isEmpty {
                            Text("What is happening at this moment?")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 13)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    HStack {
                        Text("Text is optional when application or media context is included.")
                        Spacer()
                        Text("\(model.content.unicodeScalars.count) / 5,000")
                    }
                    .font(.caption)
                    .foregroundStyle(
                        model.content.unicodeScalars.count > 5_000 ? .red : .secondary
                    )
                }

                if let snapshot = model.snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Included Context")
                            .font(.headline)

                        if let application = snapshot.application {
                            Toggle(isOn: $model.includesApplication) {
                                Label(
                                    application.displayName,
                                    systemImage: "app.fill"
                                )
                            }
                            if model.includesApplication,
                               let windowTitle = application.windowTitle
                            {
                                Toggle("Include window title: \(windowTitle)", isOn: $model.includesWindowTitle)
                                    .padding(.leading, 26)
                                    .help("Window titles may contain sensitive information and are excluded by default.")
                            }
                        }

                        if let media = snapshot.media {
                            Toggle(isOn: $model.includesMedia) {
                                HStack(spacing: 10) {
                                    artwork(for: media)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(media.title ?? media.artist ?? "Media")
                                        if let artist = media.artist, artist != media.title {
                                            Text(artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        if snapshot.application == nil, snapshot.media == nil {
                            Text("No shareable application or media context was captured.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Label(
                    "This is a public post. The captured context is fixed and does not update after publishing.",
                    systemImage: "globe"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .overlay {
            if model.phase == .publishing {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.8)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Publishing Moment…")
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { MomentComposerWindowManager.shared.closeWindow() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if case .editing = model.phase {
                Button("Publish") {
                    Task { await model.publish() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canPublish)
            } else if case .failed = model.phase {
                EmptyView()
            } else if model.phase != .loading && model.phase != .publishing {
                Button("Done") { MomentComposerWindowManager.shared.closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func artwork(for media: SanitizedMediaPresence) -> some View {
        Group {
            if let data = media.artwork?.pngData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private func resultView(
        symbol: String,
        title: String,
        message: String,
        symbolColor: Color,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
