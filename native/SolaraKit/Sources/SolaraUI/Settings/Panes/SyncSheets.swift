import AppKit
import SwiftUI

struct SyncSheetView: View {
  let model: SyncPaneModel
  let sheet: SyncSheet

  var body: some View {
    switch sheet {
    case .recoveryKit: SyncRecoveryKitSheet(model: model)
    case .phrase(let canChange): SyncPhraseSheet(model: model, canChangeFolder: canChange)
    case .connectDevice: SyncConnectDeviceSheet(model: model)
    case .stop: SyncStopSheet(model: model)
    case .deleteData: SyncDeleteDataSheet(model: model)
    }
  }
}

struct SyncSheetFrame<Content: View, Buttons: View, Leading: View>: View {
  let width: CGFloat
  let content: Content
  let leading: Leading
  let buttons: Buttons

  init(width: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) {
    self.width = width
    self.content = content()
    self.leading = leading()
    self.buttons = buttons()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
      HStack(spacing: 8) {
        leading
        Spacer(minLength: 0)
        buttons
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: width, alignment: .leading)
  }
}

extension SyncSheetFrame where Leading == EmptyView {
  init(width: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons) {
    self.init(width: width, content: content, leading: { EmptyView() }, buttons: buttons)
  }
}

struct SyncSheetTitle: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(.system(size: 15, weight: .semibold))
  }
}

struct SyncSheetBody: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 12.5))
      .foregroundStyle(.secondary)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 6)
  }
}

struct SyncPNGImage: View {
  let png: Data?
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    if let png, let image = NSImage(data: png) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.none)
        .frame(width: width, height: height)
    }
  }
}

struct SyncRecoveryKitSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SyncPaneModel
  @State private var preview: Data?
  @State private var saved: String?
  @State private var unavailable: String?

  static let previewSize = CGSize(width: 168, height: 217)

  var body: some View {
    SyncSheetFrame(width: 460) {
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 0) {
          SyncSheetTitle("Save Your Recovery Kit")
          SyncSheetBody("Your Recovery Kit contains all you need to recover your data should you lose access to this device.")
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 12))
              .foregroundStyle(Color.orange)
            Text("Save a copy of your Recovery Kit to \(Text("another").underline()) device or to the cloud. You’ll need it if you lose access to this device.")
              .font(.system(size: 12))
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
          .padding(.top, 14)
          if let saved {
            SyncSheetBody("Saved to \(SyncText.homeRelative(saved)).")
              .padding(.top, 4)
          }
          if unavailable != nil {
            SyncPhraseUnavailableNote()
              .padding(.top, 10)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        SyncPNGImage(png: preview, width: Self.previewSize.width, height: Self.previewSize.height)
          .frame(width: Self.previewSize.width, height: Self.previewSize.height)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1))
          .accessibilityLabel("Recovery kit preview")
      }
    } leading: {
      Menu("Other Options") {
        Button("Copy", systemImage: "doc.on.doc") { Task { await model.services.copyRecoveryKit() } }
        Button("Share…", systemImage: "square.and.arrow.up") { Task { await model.services.shareRecoveryKit() } }
        Divider()
        Button("Save as Text…", systemImage: "doc.plaintext") { Task { await save(.text) } }
      }
      .menuStyle(.button)
      .fixedSize()
    } buttons: {
      Button("Close") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save…") { Task { await save(.pdf) } }
        .keyboardShortcut(.defaultAction)
    }
    .task {
      unavailable = await model.services.phraseUnavailable()
      preview = await model.services.recoveryKitPreview(width: Double(Self.previewSize.width))
    }
    .onDisappear { preview = nil }
  }

  func save(_ format: SyncKitFormat) async {
    if let path = await model.services.saveRecoveryKit(format) { saved = path }
  }
}

struct SyncPhraseUnavailableNote: View {
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "lock.fill")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Text("Your recovery phrase can’t be shown, copied or saved because this Mac has no login password. Set one in System Settings › Users & Groups, then try again.")
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum SyncPhrase {
  static let wordCount = 24

  static func countWords(_ text: String) -> Int {
    text.lowercased().split(whereSeparator: { !("a"..."z").contains($0) }).count
  }

  static func countLabel(_ count: Int) -> String {
    count > wordCount ? "too many words" : "\(count)/\(wordCount) words"
  }
}

struct SyncPhraseSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SyncPaneModel
  let canChangeFolder: Bool
  var onConnected: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  @State private var text = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    let count = SyncPhrase.countWords(text)
    let folder = model.info
    SyncSheetFrame(width: 440) {
      SyncSheetTitle("Connect with Recovery Phrase")
      SyncSheetBody("Enter your 24-word recovery phrase to sync with another device.")
      ZStack(alignment: .topLeading) {
        SyncPhraseEditor(text: Binding(get: { text }, set: { text = $0; error = nil }))
        if text.isEmpty {
          Text("Enter your 24-word recovery phrase")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
      }
      .padding(8)
      .frame(height: 96)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(error != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.separator), lineWidth: 1))
      .padding(.top, 12)
      HStack(alignment: .firstTextBaseline) {
        Text(error ?? "")
          .foregroundStyle(error != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(SyncPhrase.countLabel(count))
          .monospacedDigit()
          .foregroundStyle(count > SyncPhrase.wordCount ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
      }
      .font(.system(size: 11.5))
      .padding(.top, 6)
      if let folder {
        HStack(spacing: 6) {
          Image(systemName: "folder")
            .font(.system(size: 11))
          Text(SyncText.folderLabel(folder))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          if canChangeFolder {
            Button("Change…") { Task { await model.changeFolderForPhrase() } }
              .buttonStyle(.link)
          }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.top, 10)
      }
    } buttons: {
      Button("Cancel") {
        if let onCancel { onCancel() } else { dismiss() }
      }
        .keyboardShortcut(.cancelAction)
      Button(busy ? "Connecting…" : "Connect") { Task { await submit() } }
        .keyboardShortcut(.defaultAction)
        .disabled(busy || count != SyncPhrase.wordCount || folder == nil)
    }
    .onDisappear { text = "" }
  }

  func submit() async {
    guard model.info != nil, !busy else { return }
    busy = true
    error = nil
    let message = await model.submitPhrase(text)
    busy = false
    error = message
    if message == nil { onConnected?() }
  }
}

struct SyncPhraseEditor: NSViewRepresentable {
  @Binding var text: String

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      text.wrappedValue = view.string
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    guard let view = scroll.documentView as? NSTextView else { return scroll }
    view.delegate = context.coordinator
    view.drawsBackground = false
    view.isRichText = false
    view.allowsUndo = true
    view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 5
    view.isContinuousSpellCheckingEnabled = false
    view.isGrammarCheckingEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticTextCompletionEnabled = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.string = text
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.text = $text
    guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
    view.string = text
  }
}

struct SyncConnectDeviceSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsContext) private var context
  let model: SyncPaneModel
  @State private var qrCode: Data?
  @State private var words: [String]?
  @State private var unavailable: String?

  var body: some View {
    let app = context?.appName ?? ""
    SyncSheetFrame(width: 480) {
      SyncSheetTitle("Connect Another Device")
      SyncSheetBody("On your other Mac, open \(app) › Settings › Sync and choose the same sync folder. Then click Enter Recovery Phrase and enter the 24 words of your recovery phrase.")
      HStack(spacing: 16) {
        Group {
          if qrCode == nil {
            Button("Show Code") { Task { qrCode = await model.services.recoveryQRCode() } }
          } else {
            SyncPNGImage(png: qrCode, width: 120, height: 120)
          }
        }
          .frame(width: 132, height: 132)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel("Recovery phrase QR code")
        Text("Or scan this code with your iPhone’s camera to copy the words, then paste them on your other Mac with Universal Clipboard.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.top, 16)
      if let words {
        SyncWordGrid(words: words)
          .padding(.top, 14)
      }
      if unavailable != nil {
        SyncPhraseUnavailableNote()
          .padding(.top, 14)
      }
    } leading: {
      Button(words == nil ? "Show Words" : "Hide Words") {
        if words == nil {
          Task { words = await model.services.recoveryWords() }
        } else {
          words = nil
        }
      }
      Button("Copy Words") { Task { await model.services.copyRecoveryPhrase() } }
    } buttons: {
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .task { unavailable = await model.services.phraseUnavailable() }
    .onDisappear {
      words = nil
      qrCode = nil
    }
  }
}

struct SyncWordGrid: View {
  let words: [String]

  static func number(_ index: Int) -> String {
    let text = String(index + 1)
    return text.count < 2 ? " " + text : text
  }

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .leading), count: 4), alignment: .leading, spacing: 0) {
      ForEach(Array(words.enumerated()), id: \.offset) { index, word in
        Text("\(Text(Self.number(index)).foregroundStyle(.tertiary)) \(word)")
          .font(.system(size: 12.5, design: .monospaced))
          .padding(.vertical, 3)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }
}

struct SyncStopSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SyncPaneModel

  var body: some View {
    SyncSheetFrame(width: 420) {
      SyncSheetTitle("Stop Syncing This Device?")
      SyncSheetBody("Syncing will stop on this device. To re-enable sync, you’ll need another device that is currently syncing, or the recovery phrase from your Recovery Kit. Everything on this Mac stays as it is.")
    } leading: {
      Button("Save Recovery Kit") { model.sheet = .recoveryKit }
    } buttons: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Stop Syncing", role: .destructive) { model.sheet = .deleteData }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
  }
}

struct SyncDeleteDataSheet: View {
  let model: SyncPaneModel
  @State private var understood = false
  @State private var busy = false

  var body: some View {
    SyncSheetFrame(width: 420) {
      SyncSheetTitle("Delete Sync Data?")
      SyncSheetBody("Would you also like to permanently delete your synced data from the sync folder? This will stop syncing on all your other devices too. To sync again, you’ll need to set up each device from scratch. Your data on each Mac stays.")
      Toggle("I understand this cannot be undone", isOn: $understood)
        .toggleStyle(.checkbox)
        .padding(.top, 12)
    } buttons: {
      Button("Keep Sync Data") { Task { await finish(deleteData: false) } }
        .keyboardShortcut(.cancelAction)
        .disabled(busy)
      Button("Delete My Sync Data", role: .destructive) { Task { await finish(deleteData: true) } }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!understood || busy)
    }
    .interactiveDismissDisabled()
  }

  func finish(deleteData: Bool) async {
    busy = true
    await model.stop(deleteData: deleteData)
  }
}
