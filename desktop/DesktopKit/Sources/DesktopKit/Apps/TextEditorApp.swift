import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TextEditorApp {
    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.editor, name: "Text Editor", symbol: "doc.text", category: .accessories,
            defaultSize: CGSize(width: 820, height: 600)
        ) { context in
            AnyView(TextEditorAppView(context: context))
        }
    }
}

// MARK: - Document

@MainActor
@Observable
final class EditorDocument: LifecycleSaving {
    static let readOnlyByteLimit = 2 * 1024 * 1024
    /// Beyond this many UTF-16 units a full regex pass costs noticeable main-thread time.
    static let highlightLengthLimit = 300_000
    /// Autosave and the recovery snapshot run this long after the last change.
    static let autosaveDelay: Duration = .milliseconds(1500)

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let window: any WindowHandle
    @ObservationIgnored let editorView: EditorContainerView
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private let recovery: EditorRecoveryStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Names this window's recovery record; kept in the window's arguments so a restored
    /// window finds it again.
    @ObservationIgnored private(set) var recoveryID: String
    @ObservationIgnored private var recoveryIDPublished: Bool
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// The change count the recovery record (or the file) last captured.
    @ObservationIgnored private var persistedChangeCount = -1

    let homeDirectory: String
    private(set) var path: String?
    private(set) var language: SyntaxLanguage
    private(set) var isDirty = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isReadOnly = false
    private(set) var readOnlyReason: String?
    private(set) var lineCount = 1
    var errorMessage: String?
    var noticeMessage: String?
    var isFindVisible = false
    var isSaveAsPresented = false

    init(context: AppLaunchContext, recovery: EditorRecoveryStore = .shared, defaults: UserDefaults = .standard) {
        host = context.host
        window = context.window
        self.recovery = recovery
        self.defaults = defaults
        let restoredID = context.arguments[AppArgument.recovery]
        recoveryID = restoredID ?? UUID().uuidString
        recoveryIDPublished = restoredID != nil
        homeDirectory = AppPath.normalize(context.host.homeDirectory)
        let initialPath = context.arguments[AppArgument.path].map { AppPath.normalize($0) }
        path = initialPath
        language = SyntaxLanguage(path: initialPath)
        editorView = EditorContainerView()
        editorView.onEdit = { [weak self] in
            self?.markDirty()
            self?.scheduleAutosave()
        }
        LifecycleSavers.shared.register(self)
        editorView.onLineCountChange = { [weak self] count in self?.lineCount = count }
        editorView.textView.onSave = { [weak self] in self?.save() }
        editorView.textView.onSaveAs = { [weak self] in self?.presentSaveAs() }
        editorView.textView.onFind = { [weak self] in self?.isFindVisible = true }
    }

    var displayName: String {
        path.map(AppPath.lastComponent) ?? "Untitled"
    }

    var suggestedSavePath: String {
        path ?? AppPath.join(homeDirectory, "untitled.txt")
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        updateTitle()
        guard let path else {
            editorView.load(text: "", language: language, readOnly: false, highlight: true)
            applyRecoveredText(over: "")
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await host.readFile(path)
            let isTooLarge = data.count > Self.readOnlyByteLimit
            let isBinary = data.prefix(8192).contains(0)
            let text = String(decoding: data, as: UTF8.self)
            if isTooLarge {
                setReadOnly("This file is larger than 2 MB, so it was opened read-only.")
            } else if isBinary {
                setReadOnly("This looks like a binary file, so it was opened read-only.")
            }
            let highlight = !isBinary && (text.utf16.count <= Self.highlightLengthLimit)
            editorView.load(text: text, language: isBinary ? .plain : language,
                            readOnly: isReadOnly, highlight: highlight)
            if !isReadOnly { applyRecoveredText(over: text) }
        } catch {
            await handleLoadFailure(path: path, error: error)
            if !isReadOnly { applyRecoveredText(over: "") }
        }
    }

    /// A restored window whose last edits never reached the file (LinPad was closed
    /// first): show those edits, unsaved, instead of the file.
    private func applyRecoveredText(over loaded: String) {
        guard let record = recovery.read(recoveryID) else { return }
        guard record.text != loaded else {
            recovery.remove(recoveryID)
            return
        }
        editorView.load(text: record.text, language: language, readOnly: false,
                        highlight: record.text.utf16.count <= Self.highlightLengthLimit)
        persistedChangeCount = editorView.changeCount
        markDirty()
        noticeMessage = "Recovered unsaved changes from \(record.savedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Autosave and recovery

    private var autosavesToFile: Bool {
        path != nil && !isReadOnly && LifecycleSettings.editorAutosaves(defaults)
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.persistChanges()
        }
    }

    /// Captures unsaved text: the recovery record first (iPad side, instant), then the
    /// file itself when autosave applies. The record goes once the file has the text.
    func persistChanges() async {
        guard isDirty, !isReadOnly else { return }
        let changeCount = editorView.changeCount
        if changeCount != persistedChangeCount {
            if !recoveryIDPublished {
                window.setArgument(recoveryID, forKey: AppArgument.recovery)
                recoveryIDPublished = true
            }
            if recovery.write(EditorRecoveryRecord(path: path, text: editorView.text, savedAt: Date()), id: recoveryID) {
                persistedChangeCount = changeCount
            }
        }
        if autosavesToFile, let path {
            await write(to: path, automatic: true)
        }
    }

    func saveBeforeSuspension() async {
        autosaveTask?.cancel()
        await persistChanges()
    }

    func save() {
        guard !isReadOnly else { return }
        guard let path else {
            presentSaveAs()
            return
        }
        Task { await write(to: path) }
    }

    func presentSaveAs() {
        isSaveAsPresented = true
    }

    func saveAs(_ input: String) {
        let base = path.map(AppPath.parent(of:)) ?? homeDirectory
        var value = input.trimmedWhitespace
        if value == "~" || value.hasPrefix("~/") {
            value = homeDirectory + value.dropFirst()
        }
        guard !value.isEmpty, !value.hasSuffix("/") else {
            errorMessage = "Enter a file path to save to."
            return
        }
        let target = AppPath.normalize(value, relativeTo: base)
        Task {
            guard await write(to: target) else { return }
            path = target
            isReadOnly = false
            readOnlyReason = nil
            editorView.setReadOnly(false)
            let newLanguage = SyntaxLanguage(path: target)
            if newLanguage != language {
                language = newLanguage
                editorView.setLanguage(newLanguage)
            }
            updateTitle()
        }
    }

    // MARK: Private

    private func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        noticeMessage = nil
        updateTitle()
    }

    private func setReadOnly(_ reason: String) {
        isReadOnly = true
        readOnlyReason = reason
    }

    private func handleLoadFailure(path: String, error: Error) async {
        let exists = await host.run("[ -e \(ShellQuote.quote(path)) ]", cwd: nil, stdin: nil).succeeded
        if exists {
            // Saving over a file we failed to read would silently replace its contents.
            setReadOnly("Couldn't read this file, so it was opened read-only.")
            errorMessage = error.localizedDescription
            editorView.load(text: "", language: .plain, readOnly: true, highlight: false)
        } else {
            noticeMessage = "New file — it will be created when you save."
            editorView.load(text: "", language: language, readOnly: false, highlight: true)
        }
    }

    /// `automatic`: autosave, which stays quiet about success and leaves a failure to the
    /// recovery record (and the next explicit save) instead of an error banner per change.
    @discardableResult
    private func write(to target: String, automatic: Bool = false) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let changeCount = editorView.changeCount
        let data = Data(editorView.text.utf8)
        do {
            try await host.writeFile(target, data: data)
            isDirty = editorView.changeCount != changeCount
            if !isDirty { recovery.remove(recoveryID) }
            errorMessage = nil
            noticeMessage = automatic ? "Saved automatically" : "Saved \(AppPath.lastComponent(target))"
            updateTitle()
            return true
        } catch {
            if !automatic {
                errorMessage = "Couldn't save \(target): \(error.localizedDescription)"
            }
            return false
        }
    }

    private func updateTitle() {
        window.setTitle((isDirty ? "• " : "") + displayName)
    }
}

// MARK: - SwiftUI

struct TextEditorAppView: View {
    @Environment(\.desktopTheme) private var theme
    @State private var document: EditorDocument
    @State private var findQuery = ""
    @State private var findMatchCount: Int?
    @FocusState private var findFieldFocused: Bool
    private let desktop: any DesktopActions
    private let windowID: UUID

    init(context: AppLaunchContext) {
        let document = EditorDocument(context: context)
        let desktop = context.desktop
        // Files dropped on the editor open in their own windows, as in Mousepad.
        document.editorView.onOpenFiles = { paths in
            for path in paths { desktop.open(appID: AppID.editor, arguments: [AppArgument.path: path]) }
        }
        _document = State(initialValue: document)
        self.desktop = desktop
        windowID = context.window.id
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let reason = document.readOnlyReason {
                InlineBanner(kind: .warning, message: reason)
            }
            if let message = document.errorMessage {
                InlineBanner(kind: .error, message: message, onDismiss: { document.errorMessage = nil })
            }
            if document.isFindVisible {
                findBar
            }
            ZStack {
                EditorRepresentable(editorView: document.editorView, style: EditorStyle(theme: theme))
                if document.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.windowBackground.opacity(0.6))
                }
            }
            statusBar
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .animation(.easeOut(duration: 0.18), value: document.isFindVisible)
        .task { await document.loadIfNeeded() }
        .nativeDropTarget(window: windowID) { [editorView = document.editorView] items, _ in
            editorView.receiveDrop(items)
        }
        .onChange(of: document.isFindVisible) { _, visible in
            if visible {
                findFieldFocused = true
            } else {
                document.editorView.clearFindHighlight()
                document.editorView.focus()
            }
        }
        .sheet(isPresented: $document.isSaveAsPresented) {
            SaveAsSheet(initialPath: document.suggestedSavePath) { target in
                document.saveAs(target)
            }
            .environment(\.desktopTheme, theme)
        }
    }

    private var toolbar: some View {
        AppToolbar {
            ToolbarIconButton("square.and.arrow.down", help: "Save (⌘S)") { document.save() }
                .disabled(document.isReadOnly || document.isSaving)
            ToolbarIconButton("square.and.arrow.down.on.square", help: "Save As… (⇧⌘S)") {
                document.presentSaveAs()
            }
            ToolbarIconButton("magnifyingglass", help: "Find (⌘F)", isActive: document.isFindVisible) {
                document.isFindVisible.toggle()
            }
            Spacer(minLength: 8)
            if document.isSaving {
                ProgressView().controlSize(.small)
            }
            if document.isDirty {
                Text("Edited")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.primaryText.opacity(0.08)))
            }
            Text(document.path ?? "Untitled")
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.trailing, 6)
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            AppSearchField(prompt: "Find", text: $findQuery) { find(backwards: false) }
                .focused($findFieldFocused)
                .frame(maxWidth: 320)
            if let findMatchCount, !findQuery.isEmpty {
                Text(findMatchCount == 0 ? "No matches" : "\(findMatchCount) match\(findMatchCount == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(findMatchCount == 0 ? Color.red.opacity(0.85) : theme.secondaryText)
            }
            Spacer(minLength: 0)
            ToolbarIconButton("chevron.up", help: "Previous Match") { find(backwards: true) }
                .disabled(findQuery.isEmpty)
            ToolbarIconButton("chevron.down", help: "Next Match") { find(backwards: false) }
                .disabled(findQuery.isEmpty)
            ToolbarIconButton("xmark", help: "Close Find Bar") { document.isFindVisible = false }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.titleBarInactive.opacity(0.7))
        .overlay(alignment: .bottom) { ThemedSeparator() }
        .onChange(of: findQuery) { _, query in
            findMatchCount = query.isEmpty ? nil : document.editorView.matchCount(of: query)
            if !query.isEmpty { document.editorView.find(query, backwards: false, fromSelectionStart: true) }
        }
    }

    private var statusBar: some View {
        AppStatusBar {
            Text(document.language.rawValue)
            Text("\(document.lineCount) line\(document.lineCount == 1 ? "" : "s")")
            Text("UTF-8")
            if document.isReadOnly {
                Label("Read-only", systemImage: "lock.fill")
            }
            Spacer(minLength: 0)
            if let notice = document.noticeMessage {
                Text(notice)
            }
        }
    }

    private func find(backwards: Bool) {
        guard !findQuery.isEmpty else { return }
        document.editorView.find(findQuery, backwards: backwards, fromSelectionStart: false)
    }
}

private struct SaveAsSheet: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @FocusState private var focused: Bool
    let onSave: (String) -> Void

    init(initialPath: String, onSave: @escaping (String) -> Void) {
        _path = State(initialValue: initialPath)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save As")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Path in the Linux file system")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                TextField("/root/project/file.txt", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(commit)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.windowBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.separator, lineWidth: 1))
            }
            HStack {
                Spacer()
                ToolbarTextButton(title: "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ToolbarTextButton(title: "Save", prominent: true, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmedWhitespace.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .background(theme.titleBarActive)
        .foregroundStyle(theme.primaryText)
        .presentationDetents([.height(200)])
        .onAppear { focused = true }
    }

    private func commit() {
        onSave(path)
        dismiss()
    }
}

// MARK: - UIKit editor

/// UIKit colors derived from the desktop theme. Equality is by source theme because
/// colors bridged from SwiftUI don't reliably compare equal, and a false mismatch
/// would re-highlight the whole document on every SwiftUI update.
struct EditorStyle: Equatable {
    private let source: DesktopTheme
    var fontSize: CGFloat
    var background: UIColor
    var gutterBackground: UIColor
    var gutterText: UIColor
    var gutterActiveText: UIColor
    var separator: UIColor
    var currentLine: UIColor
    var findHighlight: UIColor
    var tint: UIColor
    var palette: SyntaxPalette

    init(theme: DesktopTheme) {
        let text = UIColor(theme.primaryText)
        let accent = UIColor(theme.accent)
        source = theme
        fontSize = theme.monospacedFontSize
        background = UIColor(theme.windowBackground)
        gutterBackground = UIColor(theme.titleBarInactive)
        gutterText = UIColor(theme.secondaryText).withAlphaComponent(0.6)
        gutterActiveText = text
        separator = UIColor(theme.separator)
        currentLine = text.withAlphaComponent(0.06)
        findHighlight = accent.withAlphaComponent(0.45)
        tint = accent
        palette = SyntaxPalette(text: text, heading: accent)
    }

    static let fallback = EditorStyle(theme: .dark)

    static func == (lhs: EditorStyle, rhs: EditorStyle) -> Bool {
        lhs.source == rhs.source
    }
}

private struct EditorRepresentable: UIViewRepresentable {
    let editorView: EditorContainerView
    let style: EditorStyle

    func makeUIView(context: Context) -> EditorContainerView {
        editorView
    }

    func updateUIView(_ view: EditorContainerView, context: Context) {
        view.apply(style)
    }
}

/// Hardware-keyboard commands only fire while this text view is first responder,
/// so several editor windows never fight over ⌘S.
final class EditorTextView: UITextView {
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onFind: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let save = UIKeyCommand(title: "Save", action: #selector(handleSave), input: "s", modifierFlags: .command)
        let saveAs = UIKeyCommand(title: "Save As…", action: #selector(handleSaveAs), input: "s",
                                  modifierFlags: [.command, .shift])
        let find = UIKeyCommand(title: "Find", action: #selector(handleFind), input: "f", modifierFlags: .command)
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab))
        for command in [save, saveAs, find, tab] {
            command.wantsPriorityOverSystemBehavior = true
        }
        return [save, saveAs, find, tab]
    }

    @objc private func handleSave() { onSave?() }
    @objc private func handleSaveAs() { onSaveAs?() }
    @objc private func handleFind() { onFind?() }

    @objc private func handleTab() {
        guard isEditable else { return }
        insertText("  ")
    }
}

final class EditorContainerView: UIView, UITextViewDelegate, NSTextStorageDelegate, UITextDropDelegate {
    let textView = EditorTextView(usingTextLayoutManager: false)
    var onEdit: (() -> Void)?
    var onLineCountChange: ((Int) -> Void)?
    var onOpenFiles: (([String]) -> Void)?
    /// Set while a drop of files is in flight: UITextView would paste their contents, but
    /// a dropped file opens instead.
    private var suppressesDropInsertion = false
    private(set) var changeCount = 0

    private let gutter = LineNumberGutterView()
    private let currentLineView = UIView()
    private let findHighlightView = UIView()
    private var style = EditorStyle.fallback
    private var language: SyntaxLanguage = .plain
    private var highlighter: SyntaxHighlighter?
    private var isHighlightingEnabled = true
    private var isReplacingText = false
    /// UTF-16 offsets where each line begins; kept in sync incrementally on edits.
    private var lineStarts: [Int] = [0]

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    var text: String { textView.textStorage.string }

    // MARK: Public API

    func load(text: String, language: SyntaxLanguage, readOnly: Bool, highlight: Bool) {
        self.language = language
        isHighlightingEnabled = highlight
        rebuildHighlighter()
        isReplacingText = true
        textView.attributedText = NSAttributedString(string: text, attributes: baseAttributes)
        isReplacingText = false
        textView.typingAttributes = baseAttributes
        recomputeLineStarts()
        highlightAll()
        textView.isEditable = !readOnly
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.setContentOffset(.zero, animated: false)
        clearFindHighlight()
        setNeedsLayout()
        gutter.setNeedsDisplay()
        if !readOnly { focus() }
    }

    func setLanguage(_ newLanguage: SyntaxLanguage) {
        language = newLanguage
        rebuildHighlighter()
        highlightAll()
    }

    func setReadOnly(_ readOnly: Bool) {
        textView.isEditable = !readOnly
    }

    func apply(_ newStyle: EditorStyle) {
        guard newStyle != style else { return }
        style = newStyle
        backgroundColor = style.background
        textView.backgroundColor = style.background
        textView.tintColor = style.tint
        currentLineView.backgroundColor = style.currentLine
        findHighlightView.backgroundColor = style.findHighlight
        gutter.style = style
        rebuildHighlighter()
        textView.typingAttributes = baseAttributes
        highlightAll()
        setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    func focus() {
        guard window != nil else { return }
        textView.becomeFirstResponder()
    }

    func matchCount(of query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let string = textView.textStorage.string as NSString
        var count = 0
        var searchRange = NSRange(location: 0, length: string.length)
        while count < 10_000 {
            let found = string.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            count += 1
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return count
    }

    /// Selects the next match. The find field keeps focus, so the selection itself is
    /// invisible; an overlay marks the match instead.
    @discardableResult
    func find(_ query: String, backwards: Bool, fromSelectionStart: Bool) -> Bool {
        guard !query.isEmpty else { return false }
        let string = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        let length = string.length
        var found: NSRange
        if backwards {
            found = string.range(of: query, options: [.caseInsensitive, .backwards],
                                 range: NSRange(location: 0, length: selection.location))
            if found.location == NSNotFound {
                found = string.range(of: query, options: [.caseInsensitive, .backwards])
            }
        } else {
            let start = min(length, fromSelectionStart ? selection.location : selection.location + selection.length)
            found = string.range(of: query, options: .caseInsensitive,
                                 range: NSRange(location: start, length: length - start))
            if found.location == NSNotFound {
                found = string.range(of: query, options: .caseInsensitive)
            }
        }
        guard found.location != NSNotFound else {
            clearFindHighlight()
            return false
        }
        textView.selectedRange = found
        textView.scrollRangeToVisible(found)
        showFindHighlight(for: found)
        updateCurrentLine()
        gutter.setNeedsDisplay()
        return true
    }

    func clearFindHighlight() {
        findHighlightView.isHidden = true
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth = gutter.preferredWidth(lineCount: lineStarts.count)
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        updateCurrentLine()
        gutter.setNeedsDisplay()
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if suppressesDropInsertion { return false }
        if text == "\t" {
            textView.insertText("  ")
            return false
        }
        if text == "\n" {
            textView.insertText("\n" + leadingWhitespace(ofLineAt: range.location))
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        changeCount += 1
        clearFindHighlight()
        onEdit?()
        updateCurrentLine()
        gutter.setNeedsDisplay()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateCurrentLine()
        gutter.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        gutter.setNeedsDisplay()
    }

    /// Undo and Redo first, then the system's Cut/Copy/Paste/Select All, then Find; shown
    /// on long press and on secondary click.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        let undoManager = textView.undoManager
        let history = UIMenu(options: .displayInline, children: [
            UIAction(title: "Undo", image: UIImage.themed(systemName: "arrow.uturn.backward"),
                     attributes: undoManager?.canUndo == true ? [] : .disabled) { _ in undoManager?.undo() },
            UIAction(title: "Redo", image: UIImage.themed(systemName: "arrow.uturn.forward"),
                     attributes: undoManager?.canRedo == true ? [] : .disabled) { _ in undoManager?.redo() },
        ])
        let find = UIMenu(options: .displayInline, children: [
            UIAction(title: "Find…", image: UIImage.themed(systemName: "magnifyingglass")) { [weak self] _ in
                self?.textView.onFind?()
            },
        ])
        return UIMenu(children: [history] + suggestedActions + [find])
    }

    // MARK: Drops

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        let proposal = UITextDropProposal(operation: .copy)
        if drop.dropSession.hasItemsConforming(toTypeIdentifiers: [UTType.guestItems.identifier]) {
            proposal.dropAction = .insert
        }
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        let session = drop.dropSession
        let hasFiles = session.hasItemsConforming(toTypeIdentifiers: [UTType.guestItems.identifier])
            || session.items.contains { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard hasFiles else { return }
        suppressesDropInsertion = true
        let providers = session.items.map(\.itemProvider)
        Task { @MainActor [weak self] in
            let (_, items) = await DragItemProviders.loadItems(from: providers)
            self?.receiveDrop(items)
            try? await Task.sleep(for: .milliseconds(500))
            self?.suppressesDropInsertion = false
        }
    }

    /// Guest files open; text is inserted at the cursor.
    func receiveDrop(_ items: [DragItem]) {
        let paths = items.compactMap(\.guestPath)
        if !paths.isEmpty { onOpenFiles?(paths) }
        let texts = items.compactMap { item -> String? in
            switch item {
            case .text(let text): return text
            case .url(let url): return url.absoluteString
            default: return nil
            }
        }
        if !texts.isEmpty, textView.isEditable, !suppressesDropInsertion {
            textView.insertText(texts.joined(separator: "\n"))
        }
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isReplacingText else { return }
        let previousDigits = String(lineStarts.count).count
        updateLineStarts(editedRange: editedRange, delta: delta, storage: textStorage)
        if String(lineStarts.count).count != previousDigits { setNeedsLayout() }
        onLineCountChange?(lineStarts.count)

        guard isHighlightingEnabled, let highlighter else { return }
        let paragraph = (textStorage.string as NSString).paragraphRange(for: editedRange)
        highlighter.highlight(textStorage, in: paragraph)
    }

    // MARK: Gutter support

    func drawLineNumbers(in gutterBounds: CGRect) {
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        let offsetY = textView.contentOffset.y
        let visible = CGRect(x: 0, y: offsetY - inset.top, width: container.size.width, height: textView.bounds.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let string = textView.textStorage.string as NSString
        let activeLine = lineIndex(for: textView.selectedRange.location)
        let font = gutter.numberFont

        func draw(_ line: Int, fragment: CGRect) {
            let isActive = line == activeLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? style.gutterActiveText : style.gutterText,
            ]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + inset.top - offsetY + (fragment.height - size.height) / 2
            label.draw(at: CGPoint(x: gutterBounds.width - size.width - 10, y: y), withAttributes: attributes)
        }

        if glyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, fragmentGlyphs, _ in
                let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location)
                guard charIndex == 0 || string.character(at: charIndex - 1) == 10 else { return }
                draw(self.lineIndex(for: charIndex), fragment: fragment)
            }
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            draw(lineStarts.count - 1, fragment: layoutManager.extraLineFragmentRect)
        }
    }

    // MARK: Private

    private var baseAttributes: [NSAttributedString.Key: Any] {
        highlighter?.baseAttributes ?? [
            .font: UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular),
            .foregroundColor: style.palette.text,
        ]
    }

    private func configure() {
        textView.delegate = self
        textView.textDropDelegate = self
        textView.textStorage.delegate = self
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 24, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = true

        currentLineView.isUserInteractionEnabled = false
        findHighlightView.isUserInteractionEnabled = false
        findHighlightView.layer.cornerRadius = 3
        findHighlightView.isHidden = true
        textView.addSubview(currentLineView)
        textView.addSubview(findHighlightView)

        gutter.editor = self
        addSubview(textView)
        addSubview(gutter)

        style = EditorStyle.fallback
        backgroundColor = style.background
        textView.backgroundColor = style.background
        textView.tintColor = style.tint
        currentLineView.backgroundColor = style.currentLine
        findHighlightView.backgroundColor = style.findHighlight
        gutter.style = style
        rebuildHighlighter()
        textView.typingAttributes = baseAttributes
    }

    private func rebuildHighlighter() {
        let font = UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        gutter.numberFont = UIFont.monospacedDigitSystemFont(ofSize: max(9, style.fontSize - 2), weight: .regular)
        highlighter = SyntaxHighlighter(language: isHighlightingEnabled ? language : .plain,
                                        font: font, palette: style.palette)
    }

    private func highlightAll() {
        guard let highlighter else { return }
        highlighter.highlightAll(textView.textStorage)
    }

    private func leadingWhitespace(ofLineAt location: Int) -> String {
        let string = textView.textStorage.string as NSString
        let lineRange = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        let prefixLength = max(0, min(location, NSMaxRange(lineRange)) - lineRange.location)
        let prefix = string.substring(with: NSRange(location: lineRange.location, length: prefixLength))
        return String(prefix.prefix { $0 == " " || $0 == "\t" })
    }

    private func updateCurrentLine() {
        let layoutManager = textView.layoutManager
        let length = textView.textStorage.length
        let location = textView.selectedRange.location
        var rect: CGRect
        if length == 0 || (location >= length && layoutManager.extraLineFragmentTextContainer != nil) {
            rect = layoutManager.extraLineFragmentRect
            if rect.height == 0 {
                rect = CGRect(x: 0, y: 0, width: 0, height: UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular).lineHeight)
            }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        currentLineView.frame = CGRect(x: 0, y: rect.minY + textView.textContainerInset.top,
                                       width: max(textView.bounds.width, textView.contentSize.width),
                                       height: rect.height)
        currentLineView.isHidden = textView.selectedRange.length > 0
        textView.sendSubviewToBack(findHighlightView)
        textView.sendSubviewToBack(currentLineView)
    }

    private func showFindHighlight(for range: NSRange) {
        let layoutManager = textView.layoutManager
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        rect = rect.offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        findHighlightView.frame = rect.insetBy(dx: -2, dy: -1)
        findHighlightView.isHidden = false
        textView.sendSubviewToBack(findHighlightView)
        textView.sendSubviewToBack(currentLineView)
    }

    private func recomputeLineStarts() {
        let string = textView.textStorage.string as NSString
        lineStarts = [0] + Self.lineStartOffsets(in: string, range: NSRange(location: 0, length: string.length))
        onLineCountChange?(lineStarts.count)
    }

    /// Replaces the line starts that fell inside the edited span, shifts the rest by
    /// `delta`, and inserts those created by the new text — O(lines), not O(characters).
    private func updateLineStarts(editedRange: NSRange, delta: Int, storage: NSTextStorage) {
        let location = editedRange.location
        let newEnd = NSMaxRange(editedRange)
        let oldEnd = newEnd - delta
        let lower = Self.lowerBound(lineStarts, location + 1)
        let upper = Self.lowerBound(lineStarts, oldEnd + 1)
        let inserted = Self.lineStartOffsets(in: storage.string as NSString, range: editedRange)
        let shifted = lineStarts[upper...].map { $0 + delta }
        lineStarts.replaceSubrange(lower..<lineStarts.count, with: inserted + shifted)
    }

    private func lineIndex(for characterIndex: Int) -> Int {
        max(0, Self.lowerBound(lineStarts, characterIndex + 1) - 1)
    }

    private static func lineStartOffsets(in string: NSString, range: NSRange) -> [Int] {
        var offsets: [Int] = []
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let count = min(chunkSize, end - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0..<count where buffer[index] == 10 {
                offsets.append(location + index + 1)
            }
            location += count
        }
        return offsets
    }

    /// First index whose value is >= `value`.
    private static func lowerBound(_ values: [Int], _ value: Int) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

final class LineNumberGutterView: UIView {
    weak var editor: EditorContainerView?
    var style = EditorStyle.fallback
    var numberFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func preferredWidth(lineCount: Int) -> CGFloat {
        let digits = max(3, String(lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        return ceil(CGFloat(digits) * digitWidth + 22)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(style.gutterBackground.cgColor)
        context.fill(bounds)
        context.setFillColor(style.separator.cgColor)
        context.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
        context.clip(to: bounds)
        editor?.drawLineNumbers(in: bounds)
    }
}

#Preview("Text Editor") {
    TextEditorAppView(context: AppsPreview.context([AppArgument.path: "/root/app/vite.config.ts"]))
        .frame(width: 820, height: 600)
}
