import AppKit
import SwiftUI
import TandemCore
import TandemUI

/// "Listen" next to "Live screen": transcribe the shared Mac's computer audio.
struct ListenToggleChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = model.settings.listen
        Button {
            model.studio.setListening(!isOn)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "waveform" : "waveform.slash")
                    .foregroundStyle(isOn ? Theme.accentSecondary : Theme.textTertiary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isOn && model.studio.transcription.level > 0.15)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Listen").font(.system(size: 11.5, weight: .semibold))
                    Text(isOn ? "Transcribing audio" : "Audio not used").font(TandemFont.micro).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(isOn ? Theme.accentSecondary.opacity(0.1) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(isOn ? Theme.accentSecondary.opacity(0.35) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isOn
            ? "Transcribing the shared Mac's computer audio. What's said goes with your next question (⌥⌘L to stop)."
            : "Transcribe the shared Mac's computer audio (a meeting or call), so questions asked out loud can be answered (⌥⌘L)")
    }
}

/// A two-line live caption of the shared Mac's audio above the skill buttons, with the full
/// transcript a click away.
struct LiveCaptionBar: View {
    @Environment(AppModel.self) private var model
    @State private var showsTranscript = false
    /// Exactly two lines of callout text.
    static let captionHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12.5)
        return ceil(font.ascender - font.descender + font.leading) * 2
    }()

    var body: some View {
        let transcription = model.studio.transcription
        HStack(alignment: .center, spacing: 10) {
            LevelBars(level: transcription.level, active: transcription.isReady)
                .frame(width: 18, height: 16)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showsTranscript.toggle()
            } label: {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the whole transcript")
            .popover(isPresented: $showsTranscript, arrowEdge: .top) {
                TranscriptPanel().environment(model)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        let status = ListeningStatus(model: model)
        if let message = status.message {
            Label {
                Text(message).lineLimit(2)
            } icon: {
                if status.isWorking {
                    ProgressView().controlSize(.mini)
                } else if status.isProblem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
            .font(TandemFont.callout)
            .foregroundStyle(status.isProblem ? Theme.textPrimary : Theme.textSecondary)
        } else {
            let recent = model.studio.transcription.transcript.recentText(maxCharacters: 420)
            // Like live captions: the newest words sit on the bottom line and older ones scroll
            // up and out of the two-line window.
            (Text(recent.final).foregroundStyle(Theme.textSecondary)
                + Text(recent.final.isEmpty || recent.volatile.isEmpty ? "" : " ")
                + Text(recent.volatile).foregroundStyle(Theme.textPrimary))
                .font(TandemFont.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.captionHeight, alignment: .bottomLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black, location: 0.45)], startPoint: .top, endPoint: .bottom))
                .help(recent.final + " " + recent.volatile)
        }
    }
}

/// What the caption bar says when there's no speech to show.
struct ListeningStatus {
    var message: String?
    var isProblem = false
    var isWorking = false

    @MainActor
    init(model: AppModel) {
        let studio = model.studio
        let transcription = studio.transcription
        let name = studio.sourceName ?? "the shared Mac"
        switch transcription.engineState {
        case .off, .preparing:
            message = "Loading the speech model…"
            isWorking = true
            return
        case .downloading(let fraction):
            message = transcription.usesParakeet
                ? "Downloading the speech model (one time, \(ByteCountFormatter.string(fromByteCount: Int64(ParakeetModelStore.Mirror.size), countStyle: .file)))… \(Int(fraction * 100))%"
                : "Downloading the speech model for this language… \(Int(fraction * 100))%"
            isWorking = true
            return
        case .failed(let error):
            message = error
            isProblem = true
            return
        case .ready:
            break
        }
        if let problem = studio.listeningProblem {
            message = problem
            isProblem = true
        } else if !studio.isConnected {
            message = transcription.transcript.isEmpty ? "Listening starts when the shared Mac connects." : nil
        } else if !transcription.isReceivingAudio() {
            if studio.sourceAudioStatus?.state == .live {
                message = transcription.transcript.isEmpty ? "Listening to \(name). Waiting for sound…" : nil
            } else {
                message = "Starting audio on \(name)…"
                isWorking = true
            }
        } else if transcription.transcript.isEmpty {
            message = "Listening to \(name). Nothing said yet."
        }
    }
}

/// A tiny three-bar level meter.
private struct LevelBars: View {
    let level: Double
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3) { index in
                let weight = [0.6, 1.0, 0.75][index]
                Capsule()
                    .fill(active ? Theme.accentSecondary : Theme.textTertiary)
                    .frame(width: 3.5, height: max(3.5, 16 * min(1, level * 1.4) * weight))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel(active ? "Audio level" : "Not listening")
    }
}

/// The full transcript: timestamps, the words still being recognized, copy and clear.
struct TranscriptPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let transcript = model.studio.transcription.transcript
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(TandemFont.headline)
                if let name = model.studio.sourceName {
                    Text("· \(name)").font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.plainText(transcript), forType: .string)
                }
                .disabled(transcript.isEmpty)
                Button("Clear") { model.studio.transcription.clear() }
                    .disabled(transcript.isEmpty)
            }
            .controlSize(.small)
            .padding(12)
            Hairline()
            if transcript.isEmpty {
                Text(model.settings.listen ? "Nothing's been said yet." : "Turn on Listen to transcribe the shared Mac's audio.")
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.segments.suffix(400)) { segment in
                            TranscriptLine(time: segment.start, text: segment.text, isVolatile: false)
                        }
                        if let volatile = transcript.volatile {
                            TranscriptLine(time: volatile.start, text: volatile.text, isVolatile: true)
                        }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom)
            }
            Hairline()
            Text("Transcribed on this Mac. What's new is sent with your next question.")
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 440, height: 380)
    }

    static func plainText(_ transcript: LiveTranscript) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        var lines = transcript.segments.map { "[\(formatter.string(from: $0.start))] \($0.text)" }
        if let volatile = transcript.volatile { lines.append("[\(formatter.string(from: volatile.start))] \(volatile.text)") }
        return lines.joined(separator: "\n")
    }
}

private struct TranscriptLine: View {
    let time: Date
    let text: String
    let isVolatile: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time, format: .dateTime.hour().minute().second())
                .font(TandemFont.monoSmall)
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(TandemFont.body)
                .foregroundStyle(isVolatile ? Theme.textSecondary : Theme.textPrimary)
                .italic(isVolatile)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// On a sent message: the transcript that went with it, collapsed to one line.
struct TranscriptChip: View {
    let excerpt: TranscriptExcerpt
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                    Text("Transcript · \(excerpt.wordCount) word\(excerpt.wordCount == 1 ? "" : "s")")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(TandemFont.caption.weight(.semibold))
                .foregroundStyle(Theme.accentSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.accentSecondary.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("What was said on the shared Mac before this question; it was sent along with it")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if excerpt.omitsEarlierSpeech {
                        Text("Earlier speech omitted").font(TandemFont.caption).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(excerpt.segments) { segment in
                        TranscriptLine(time: segment.start, text: segment.text, isVolatile: false)
                    }
                    if let pending = excerpt.pendingText {
                        TranscriptLine(time: excerpt.coveredThrough ?? Date(), text: pending, isVolatile: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.accentSecondary.opacity(0.06)))
            }
        }
    }
}
