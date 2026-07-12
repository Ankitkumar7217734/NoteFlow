import Foundation
import SwiftUI
import AppKit
import CryptoKit

class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [Note] = []
    @Published var openTabIds: [UUID] = []
    @Published var activeTabId: UUID?
    /// Global: whether the floating panel is currently shown. Shared across
    /// windows so each window's TabBar can adapt. UI state like
    /// sidebarOpen, searchText and formattingVisible lives in WindowState.
    @Published var isFloating = false

    // Cache of plain-text bodies keyed by note id, populated lazily by
    // plainText(for:) and invalidated by updateNote / deleteNote.
    // Lets full-text search avoid re-decoding RTF on every keystroke.
    private var plainTextCache: [UUID: String] = [:]

    // One NSTextStorage per note, shared by every NSTextView that edits that
    // note (main window + floating panel). NSTextStorage notifies all attached
    // NSLayoutManagers on every edit, so a keystroke in one editor instantly
    // re-renders in the other without going through @Published or RTF.
    private var sharedStorages: [UUID: NSTextStorage] = [:]

    // Debounced persistence. Typing calls noteBodyDidChange(_:), which marks
    // the note's id dirty and (re)arms a timer instead of encoding RTF +
    // writing notes.json on every keystroke. The shared NSTextStorage holds
    // the live text in the meantime, so nothing is lost; flushPendingSaves()
    // encodes from it and writes once typing pauses (and on app
    // resign/terminate, so quitting never drops the last edits).
    private var pendingDirtyNoteIds: Set<UUID> = []
    private var saveDebounceTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 0.6
    // RTF-encoding a long note takes visible milliseconds; doing it on the
    // main thread caused a typing hitch whenever the debounce fired. The
    // timer path encodes on this queue instead (see
    // flushPendingSavesInBackground); the synchronous flushPendingSaves()
    // remains for app-switch / quit, where blocking is the point.
    private let encodeQueue = DispatchQueue(label: "com.noteflow.rtf-encode", qos: .utility)
    // Bumped on every keystroke per note. Lets a background flush detect
    // "the user typed while I was encoding" and keep the note dirty so the
    // newer text is re-encoded by the next flush.
    private var editGenerations: [UUID: UInt64] = [:]

    /// Rich-text notes the user created this session that still have no body
    /// text. Purged on app quit only — kept while the app stays open.
    private var sessionEmptyNoteIds: Set<UUID> = []

    // MARK: – External change sync (MCP server / other notes.json writers)

    // SHA-256 of the notes.json bytes this store has already accounted for —
    // either because we wrote them (save) or because we merged them in
    // (reloadFromDiskIfExternallyChanged / load). Any on-disk content whose
    // hash differs was written by another process (the NoteFlow MCP server,
    // a hand edit, …) and must be merged before we read stale state or
    // clobber it with our own write.
    private var lastAccountedDiskHash: Data?
    // Per-note snapshot of the last disk state this store accounted for —
    // the "base" of the three-way merge in applyExternalNotes. Comparing
    // local and disk against it tells "changed locally", "changed
    // externally", and "changed in both" apart, so an external write can
    // never silently undo a local edit (or vice versa).
    private var lastSyncedNotes: [UUID: Note] = [:]
    private var storeDirectoryWatcher: DispatchSourceFileSystemObject?
    private var externalReloadWorkItem: DispatchWorkItem?
    private let fileWatchQueue = DispatchQueue(label: "com.noteflow.file-watch", qos: .utility)

    deinit {
        storeDirectoryWatcher?.cancel()
    }

    private static func contentHash(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Watch the directory containing notes.json for writes. We watch the
    /// *directory*, not the file: external writers (the MCP server included)
    /// replace the file via temp-file + rename, which would orphan a
    /// file-descriptor watch on the old inode after the first write.
    private func startWatchingStoreDirectory() {
        let dirPath = saveURL.deletingLastPathComponent().path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: fileWatchQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleExternalReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        storeDirectoryWatcher = source
    }

    /// Debounced hop to the main thread. A temp-file + rename write fires
    /// several directory events back-to-back; coalescing them also gives the
    /// writer time to finish before we read.
    private func scheduleExternalReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.externalReloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reloadFromDiskIfExternallyChanged()
            }
            self.externalReloadWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Re-read notes.json and fold in any changes made by another process
    /// (the NoteFlow MCP server, a hand edit, …). No-ops when the on-disk
    /// bytes are the ones this store already wrote or merged, so the app's
    /// own saves never trigger a reload loop. Returns true when a merge ran.
    ///
    /// Main-thread only (mutates @Published state and NSTextStorage).
    @discardableResult
    func reloadFromDiskIfExternallyChanged() -> Bool {
        guard let data = try? Data(contentsOf: saveURL) else { return false }
        let hash = Self.contentHash(of: data)
        guard hash != lastAccountedDiskHash else { return false }
        guard let diskNotes = try? JSONDecoder().decode([Note].self, from: data) else {
            // Partially written / invalid external content. Don't merge and
            // don't mark it accounted — we'll retry on the next event, and a
            // later save() simply rewrites a good store.
            return false
        }
        applyExternalNotes(diskNotes)
        lastAccountedDiskHash = hash
        return true
    }

    /// Three-way merge of externally written notes into memory, using
    /// `lastSyncedNotes` as the base:
    /// - a note the user is mid-edit on (unflushed keystrokes) keeps its
    ///   local version — the debounce flush persists it moments later;
    /// - a note only the external writer touched takes the disk version,
    ///   refreshing its live shared NSTextStorage so open editors re-render
    ///   immediately;
    /// - a note only changed locally (e.g. a rename racing the debounced
    ///   watcher inside save()) keeps the local version;
    /// - changed in both → newer `updatedAt` wins;
    /// - notes that exist only in memory are kept (never destructive) and
    ///   get re-persisted by the next save.
    private func applyExternalNotes(_ diskNotes: [Note]) {
        let localById = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let diskIds = Set(diskNotes.map { $0.id })

        var merged: [Note] = []
        merged.reserveCapacity(diskNotes.count)
        for diskNote in diskNotes {
            let local = localById[diskNote.id]
            // On disk + in the sync base, but gone from memory ⇒ the user
            // permanently deleted it this session (and this merge is running
            // inside the save() that persists that deletion). Don't
            // resurrect it — unless the external writer also changed it
            // since the base, in which case keeping it is the safe call.
            if local == nil, let base = lastSyncedNotes[diskNote.id], diskNote == base {
                continue
            }
            let winner = resolvedNote(disk: diskNote, local: local)
            merged.append(winner)
            if winner.rtfData == diskNote.rtfData,
               let local, local.rtfData != diskNote.rtfData {
                refreshLiveContent(for: winner)
            }
        }
        let localOnly = notes.filter { !diskIds.contains($0.id) }
        merged.insert(contentsOf: localOnly, at: 0)

        withAnimation(.easeInOut(duration: 0.22)) {
            notes = merged
        }

        // Tab hygiene: drop tabs whose notes vanished or were trashed
        // externally, and make sure something sensible stays active.
        openTabIds.removeAll { id in
            guard let note = notes.first(where: { $0.id == id }) else { return true }
            return note.isTrashed
        }
        if openTabIds.isEmpty, let first = notes.first(where: { !$0.isTrashed }) {
            openTabIds = [first.id]
        }
        if activeTabId == nil || !openTabIds.contains(activeTabId!) {
            activeTabId = openTabIds.last
        }

        recordSyncedSnapshot()
    }

    /// Pick the surviving version of one note during an external merge.
    private func resolvedNote(disk: Note, local: Note?) -> Note {
        guard let local = local else { return disk }
        // Unflushed keystrokes: the live NSTextStorage (not disk, not the
        // stale local.rtfData) is the source of truth — keep local; the
        // debounce flush re-encodes and persists it.
        if pendingDirtyNoteIds.contains(disk.id) { return local }
        let base = lastSyncedNotes[disk.id]
        let localChanged = base == nil ? false : local != base
        let diskChanged = base == nil ? true : disk != base
        switch (localChanged, diskChanged) {
        case (false, _): return disk          // only external edits (or none)
        case (true, false): return local      // only local edits
        case (true, true):                    // both — newer edit wins
            return disk.updatedAt >= local.updatedAt ? disk : local
        }
    }

    /// Remember the current in-memory notes as the last-synced base for the
    /// next external merge. Called whenever memory and disk are in agreement
    /// (after load, save, and every external merge).
    private func recordSyncedSnapshot() {
        lastSyncedNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
    }

    /// Push an externally updated note's body into its live shared
    /// NSTextStorage (if one exists), running the same normalization pipeline
    /// as sharedTextStorage(for:) so MCP-written RTF obeys theming and layout
    /// rules. Every attached editor (main window + floating panel) re-renders
    /// instantly; the caret is restored clamped so typing isn't derailed.
    private func refreshLiveContent(for note: Note) {
        plainTextCache.removeValue(forKey: note.id)
        guard let storage = sharedStorages[note.id] else { return }

        let mutable = NSMutableAttributedString(attributedString: note.attributedContent)
        Self.replaceThemeDefaultForegroundColors(in: mutable)
        Self.normalizeParagraphStyles(in: mutable, preserveVerticalSpacing: true)
        Self.normalizeWhitespace(in: mutable)
        guard !mutable.isEqual(to: storage) else { return }

        let textViews = storage.layoutManagers.compactMap { $0.firstTextView }
        let selections = textViews.map { $0.selectedRange() }

        storage.beginEditing()
        storage.setAttributedString(mutable)
        storage.endEditing()

        for (textView, selection) in zip(textViews, selections) {
            let location = min(selection.location, storage.length)
            let length = min(selection.length, storage.length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
        }
    }

    func sharedTextStorage(for id: UUID) -> NSTextStorage {
        if let existing = sharedStorages[id] {
            return existing
        }
        let storage = NSTextStorage()
        if let note = notes.first(where: { $0.id == id }) {
            let attr = note.attributedContent
            if attr.length > 0 {
                // Strip only the foreground colors that match a theme's
                // default text color, so notes saved in light/dark mode
                // adapt to the current theme — but user-applied colors
                // (red, blue, etc. from the Text Formatting picker) are
                // preserved.
                let mutable = NSMutableAttributedString(attributedString: attr)
                Self.replaceThemeDefaultForegroundColors(in: mutable)
                // Reset foreign paragraph indents/alignment baked in by old
                // pastes so existing notes render with one straight left
                // margin. Tables (textBlocks) are preserved. Vertical spacing
                // is kept (clamped) so imported Markdown notes keep their
                // heading / body / list rhythm across reopens.
                Self.normalizeParagraphStyles(in: mutable, preserveVerticalSpacing: true)
                // Collapse doubled interior spaces that make soft-wrapped
                // lines start at uneven positions.
                Self.normalizeWhitespace(in: mutable)
                storage.setAttributedString(mutable)
            }
        }
        sharedStorages[id] = storage
        return storage
    }

    // Colors the editor uses as a "default" text color (one per theme).
    // We compare against these when deciding which foreground colors to
    // strip so the user's explicitly-picked colors survive.
    private static let themeDefaultColors: [NSColor] = [
        .black,                                      // legacy light default
        NSColor(white: 0.91, alpha: 1),              // legacy dark default
        Palette.lightInkNS,                          // Paper & Ink light (#2C2A26)
        Palette.legacyDarkInkNS,                     // Paper & Ink dark (#DAD7D1)
        Palette.midBrightDarkInkNS,                  // Paper & Ink dark (#F0EEEA)
        Palette.darkInkNS                            // Paper & Ink dark (#FFFFFF)
    ]

    private static func isThemeDefault(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        for ref in themeDefaultColors {
            guard let r = ref.usingColorSpace(.sRGB) else { continue }
            if abs(c.redComponent - r.redComponent) < 0.02
                && abs(c.greenComponent - r.greenComponent) < 0.02
                && abs(c.blueComponent - r.blueComponent) < 0.02 {
                return true
            }
        }
        return false
    }

    static func stripThemeDefaultForegroundColors(in storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var rangesToClear: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            if isThemeDefault(color) { rangesToClear.append(range) }
        }
        for range in rangesToClear {
            storage.removeAttribute(.foregroundColor, range: range)
        }
    }

    /// Same as stripThemeDefaultForegroundColors but replaces matched colors
    /// with Palette.dynamicInkNS instead of removing them. Text with no
    /// foreground attribute falls back to black in AppKit — not to
    /// textColor — so a removal leaves text invisible in dark mode.
    /// Replacing with the dynamic ink means the attribute is always present
    /// and re-resolves automatically whenever the view's appearance changes.
    ///
    /// Runs with NO foreground attribute get the dynamic ink too. Every run
    /// in a live storage must carry an explicit .foregroundColor: the editor
    /// deliberately never sets textView.textColor (that NSText setter
    /// recolors the whole storage and was flattening user/MCP colors — see
    /// RichTextEditor.buildEditor), so an attribute-less run would render
    /// AppKit-fallback black in both themes.
    static func replaceThemeDefaultForegroundColors(in storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var rangesToReplace: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor else {
                rangesToReplace.append(range)  // no color at all -> needs ink
                return
            }
            if isThemeDefault(color) { rangesToReplace.append(range) }
        }
        for range in rangesToReplace {
            storage.addAttribute(.foregroundColor, value: Palette.dynamicInkNS, range: range)
        }
    }

    /// Reset every paragraph to a clean, left-aligned style so consecutive
    /// lines share one left margin. Foreign content (pasted from the web,
    /// Word, etc.) carries first-line / head indents, custom tab stops, and
    /// alignment that make each line start at a different horizontal
    /// position — this strips all of that down to the editor's default.
    /// Table-cell membership (`textBlocks`) is preserved so tables keep
    /// their layout; the app's own lists are plain-text prefixes, so nothing
    /// else here depends on paragraph indentation.
    ///
    /// `preserveVerticalSpacing` carries over *vertical* metrics
    /// (paragraph spacing + line spacing, clamped to sane maxima) while still
    /// flattening all horizontal layout. The misalignment bug this method
    /// fixes is purely horizontal, so vertical rhythm is safe to keep — this
    /// lets imported Markdown notes (which set paragraph spacing for headings
    /// / body / lists) survive being reopened from disk. The paste path keeps
    /// the default (`false`) so its aggressive flatten is unchanged.
    static func normalizeParagraphStyles(in storage: NSMutableAttributedString,
                                         preserveVerticalSpacing: Bool = false) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var replacements: [(NSRange, NSParagraphStyle)] = []
        storage.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            let clean = NSMutableParagraphStyle()
            clean.alignment = .natural
            let original = value as? NSParagraphStyle
            // Keep table cells intact; drop everything else (indents, tab
            // stops, list markers, spacing) back to the default. A table
            // cell's column alignment is part of its layout, so preserve it
            // (only table paragraphs carry textBlocks).
            if let original = original, !original.textBlocks.isEmpty {
                clean.textBlocks = original.textBlocks
                clean.alignment = original.alignment
            }
            // Vertical rhythm doesn't cause the horizontal misalignment this
            // method exists to fix, so it's safe to keep. Clamp it so a
            // legacy foreign paste with huge spacing / line-height can't
            // produce enormous gaps. Line-height multiples / min / max are
            // *not* carried over — they're the usual culprit and NoteFlow's
            // own imports express spacing via lineSpacing, not line heights.
            if preserveVerticalSpacing, let original = original {
                clean.paragraphSpacing = min(original.paragraphSpacing, 12)
                clean.paragraphSpacingBefore = min(original.paragraphSpacingBefore, 12)
                clean.lineSpacing = min(original.lineSpacing, 8)
            }
            replacements.append((range, clean))
        }
        for (range, style) in replacements {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Clean up whitespace that makes wrapped lines look misaligned. Pasted
    /// content (especially from PDFs / formatted docs) often has doubled
    /// interior spaces; when a paragraph soft-wraps, the wrap can leave a
    /// stray space at the start of the next visual line, so consecutive
    /// lines appear to start at slightly different positions. We collapse
    /// runs of 2+ spaces that follow a non-space character down to one, and
    /// fold non-breaking / exotic spaces into a regular space. Leading-line
    /// whitespace (the app's blockquote indent, intentional indentation) is
    /// left untouched, since those runs aren't preceded by a visible char.
    static func normalizeWhitespace(in storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let ms = storage.mutableString
        for exotic in ["\u{00A0}", "\u{2007}", "\u{202F}", "\u{2009}", "\u{2002}", "\u{2003}"] {
            ms.replaceOccurrences(of: exotic, with: " ", options: [],
                                  range: NSRange(location: 0, length: ms.length))
        }
        if let regex = try? NSRegularExpression(pattern: "(\\S) {2,}") {
            regex.replaceMatches(in: ms, options: [],
                                 range: NSRange(location: 0, length: ms.length),
                                 withTemplate: "$1 ")
        }
    }

    // Tests inject a temp-directory URL here so they never touch the real
    // notes.json in Application Support. nil (the app) uses the default path.
    private let saveURLOverride: URL?

    private var saveURL: URL {
        if let override = saveURLOverride { return override }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    var openTabs: [Note] { openTabIds.compactMap { id in notes.first(where: { $0.id == id }) } }

    var activeNote: Note? { notes.first(where: { $0.id == activeTabId }) }

    /// Notes filtered by a per-window search query and/or tag, then sorted
    /// pinned-first within each group. Excludes trashed notes — those live
    /// behind the Trash view. Pinned ordering: pinned notes by updatedAt
    /// desc, then unpinned by updatedAt desc.
    func filteredNotes(matching query: String = "", tag: String? = nil) -> [Note] {
        var result = notes.filter { !$0.isTrashed }

        if let tag = tag, !tag.isEmpty {
            result = result.filter { $0.tags.contains(tag) }
        }

        if !query.isEmpty {
            result = result.filter { note in
                if note.title.localizedCaseInsensitiveContains(query) { return true }
                if note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                // API pages: match provider names + key labels (never values).
                if note.kind == .apiManager {
                    return apiSearchText(for: note).localizedCaseInsensitiveContains(query)
                }
                return plainText(for: note.id).localizedCaseInsensitiveContains(query)
            }
        }

        return result.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Every distinct tag across non-trashed notes, sorted alphabetically.
    var allTags: [String] {
        var set = Set<String>()
        for note in notes where !note.isTrashed {
            for tag in note.tags { set.insert(tag) }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Trashed notes, most-recently-deleted first.
    var trashedNotes: [Note] {
        notes.filter { $0.isTrashed }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Returns the note's body as plain text. Prefers the live NSTextStorage
    /// (always up-to-date with whatever the user is typing right now) and
    /// falls back to decoding the persisted RTF, caching the result.
    func plainText(for noteId: UUID) -> String {
        if let storage = sharedStorages[noteId] { return storage.string }
        if let cached = plainTextCache[noteId] { return cached }
        guard let note = notes.first(where: { $0.id == noteId }) else { return "" }
        // API pages have no RTF body — don't decode/cache an empty string, and
        // never surface key material through this text (used for row snippets).
        if note.kind == .apiManager { return "" }
        let plain = note.attributedContent.string
        plainTextCache[noteId] = plain
        return plain
    }

    init(saveURL: URL? = nil) {
        self.saveURLOverride = saveURL
        load()
        startWatchingStoreDirectory()
        // When the theme flips, any text the user has already typed in the
        // current session has an explicit .foregroundColor baked into its
        // shared NSTextStorage from typingAttributes. Without stripping, it
        // stays the old theme's color and renders invisible against the new
        // background. We strip across every in-memory storage so newly
        // opened notes are also correct.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stripForegroundColorsAcrossStorages),
            name: .themeChanged, object: nil
        )
    }

    @objc private func stripForegroundColorsAcrossStorages() {
        // Replace runs whose color matches a theme default with
        // Palette.dynamicInkNS. Removing the attribute entirely (the old
        // approach) caused black text: AppKit's fallback for no foreground
        // attribute is black, not the text view's textColor property.
        // The dynamic ink re-resolves to the correct color on every redraw
        // once applyPalette has updated the text view's appearance.
        // User-picked colors from the formatting toolbar are not theme
        // defaults and are left untouched.
        for (_, storage) in sharedStorages where storage.length > 0 {
            storage.beginEditing()
            Self.replaceThemeDefaultForegroundColors(in: storage)
            storage.endEditing()
        }
    }

    func newNote(userInitiated: Bool = true) {
        let note = Note()
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.insert(note, at: 0)
        }
        openTabIds.append(note.id)
        activeTabId = note.id
        if userInitiated {
            sessionEmptyNoteIds.insert(note.id)
        }
        save()
    }

    // MARK: – API Key Manager pages

    /// Create a new API Key Manager page. Mirrors newNote()'s insert / open-tab
    /// / activate / persist sequence, but the note is an auto-pinned
    /// `.apiManager` page carrying a structured provider list instead of RTF.
    func newAPIPage() {
        let note = Note(apiManagerTitled: "API Keys")
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.insert(note, at: 0)
        }
        openTabIds.append(note.id)
        activeTabId = note.id
        save()
    }

    /// All provider/key mutation funnels through here so it can't run against a
    /// rich-text note (kind guard) and every change bumps updatedAt + persists.
    private func mutateProviders(_ id: UUID, _ body: (inout [APIProvider]) -> Void) {
        guard let idx = notes.firstIndex(where: { $0.id == id }),
              notes[idx].kind == .apiManager else { return }
        var providers = notes[idx].providers ?? []
        body(&providers)
        notes[idx].providers = providers
        notes[idx].updatedAt = Date()
        save()
    }

    /// Insert a blank provider slot the user names afterward (API page flow).
    @discardableResult
    func addProvider(to noteId: UUID) -> UUID? {
        let provider = APIProvider()
        mutateProviders(noteId) { $0.append(provider) }
        return provider.id
    }

    func addProvider(named name: String, to noteId: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateProviders(noteId) { $0.append(APIProvider(name: trimmed)) }
    }

    func renameProvider(_ providerId: UUID, to name: String, in noteId: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateProviders(noteId) { providers in
            guard let i = providers.firstIndex(where: { $0.id == providerId }) else { return }
            providers[i].name = trimmed
        }
    }

    func updateProviderBaseURL(_ providerId: UUID, to baseURL: String, in noteId: UUID) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateProviders(noteId) { providers in
            guard let i = providers.firstIndex(where: { $0.id == providerId }) else { return }
            guard providers[i].baseURL != trimmed else { return }
            providers[i].baseURL = trimmed
        }
    }

    func deleteProvider(_ providerId: UUID, in noteId: UUID) {
        mutateProviders(noteId) { $0.removeAll { $0.id == providerId } }
    }

    /// Add (paste) a key under a provider. Blank values are ignored so an empty
    /// paste field can't create a phantom key.
    func addKey(_ value: String, label: String = "", toProvider providerId: UUID, in noteId: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateProviders(noteId) { providers in
            guard let i = providers.firstIndex(where: { $0.id == providerId }) else { return }
            providers[i].keys.append(APIKeyEntry(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                value: trimmed
            ))
        }
    }

    func updateKey(_ keyId: UUID, value: String? = nil, label: String? = nil,
                   inProvider providerId: UUID, note noteId: UUID) {
        mutateProviders(noteId) { providers in
            guard let pi = providers.firstIndex(where: { $0.id == providerId }),
                  let ki = providers[pi].keys.firstIndex(where: { $0.id == keyId }) else { return }
            if let value = value { providers[pi].keys[ki].value = value }
            if let label = label { providers[pi].keys[ki].label = label }
        }
    }

    func deleteKey(_ keyId: UUID, inProvider providerId: UUID, note noteId: UUID) {
        mutateProviders(noteId) { providers in
            guard let pi = providers.firstIndex(where: { $0.id == providerId }) else { return }
            providers[pi].keys.removeAll { $0.id == keyId }
        }
    }

    /// Reorder a provider so it lands at `toIndex` in the final array (0 = top).
    /// Array order is what the API page and menu bar both display.
    func moveProvider(_ providerId: UUID, toIndex: Int, in noteId: UUID) {
        mutateProviders(noteId) { providers in
            guard let from = providers.firstIndex(where: { $0.id == providerId }),
                  let dest = Self.finalIndexAfterMove(from: from, toIndex: toIndex, count: providers.count)
            else { return }
            let item = providers.remove(at: from)
            providers.insert(item, at: dest)
        }
    }

    /// Drop between cards: `slot` is 0...count (0 = before first / top, count = after last).
    func moveProvider(_ providerId: UUID, toInsertionSlot slot: Int, in noteId: UUID) {
        mutateProviders(noteId) { providers in
            guard let from = providers.firstIndex(where: { $0.id == providerId }),
                  let dest = Self.finalIndex(from: from, insertionSlot: slot, count: providers.count)
            else { return }
            let item = providers.remove(at: from)
            providers.insert(item, at: dest)
        }
    }

    /// Insertion slot (0...count) → final index after removing `from`. Nil = no-op.
    static func finalIndex(from: Int, insertionSlot: Int, count: Int) -> Int? {
        guard count > 1, from >= 0, from < count else { return nil }
        var dest = max(0, min(insertionSlot, count))
        if from < dest { dest -= 1 }
        guard dest != from else { return nil }
        return dest
    }

    /// Desired final index (0...count-1) → insert index after removing `from`. Nil = no-op.
    static func finalIndexAfterMove(from: Int, toIndex: Int, count: Int) -> Int? {
        guard count > 1, from >= 0, from < count else { return nil }
        let target = max(0, min(toIndex, count - 1))
        guard target != from else { return nil }
        return target
    }

    /// Copy arbitrary text (an API key) to the system clipboard. Same pattern
    /// as the editor's Copy button.
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Text used to match an API page against a search query: provider names +
    /// key labels only. Key *values* are deliberately excluded so secrets never
    /// leak into search matching or sidebar snippets.
    func apiSearchText(for note: Note) -> String {
        guard let providers = note.providers else { return "" }
        var parts: [String] = []
        for provider in providers {
            parts.append(provider.name)
            parts.append(contentsOf: provider.keys.map { $0.label })
        }
        return parts.joined(separator: " ")
    }

    /// Non-trashed API manager pages in sidebar order (newest updated first).
    func apiManagerPages() -> [Note] {
        notes.filter { $0.kind == .apiManager && !$0.isTrashed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every stored API key across all API pages — used by the menu-bar extra.
    func allMenuBarAPIEntries() -> [MenuBarAPIEntry] {
        var entries: [MenuBarAPIEntry] = []
        for note in apiManagerPages() {
            guard let providers = note.providers else { continue }
            let pageTitle = note.title.isEmpty ? "API Keys" : note.title
            for provider in providers {
                let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                for key in provider.keys {
                    let value = key.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    entries.append(MenuBarAPIEntry(
                        keyId: key.id,
                        providerId: provider.id,
                        pageId: note.id,
                        pageTitle: pageTitle,
                        providerName: name,
                        keyValue: value,
                        createdAt: key.createdAt
                    ))
                }
            }
        }
        return entries
    }

    /// Named providers with a non-empty base URL — for menu-bar URL copy actions.
    func allMenuBarProviderEntries() -> [MenuBarProviderEntry] {
        var entries: [MenuBarProviderEntry] = []
        for note in apiManagerPages() {
            guard let providers = note.providers else { continue }
            let pageTitle = note.title.isEmpty ? "API Keys" : note.title
            for provider in providers {
                let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !url.isEmpty else { continue }
                entries.append(MenuBarProviderEntry(
                    providerId: provider.id,
                    pageId: note.id,
                    pageTitle: pageTitle,
                    providerName: name,
                    baseURL: url
                ))
            }
        }
        return entries
    }

    func closeTab(_ id: UUID) {
        openTabIds.removeAll { $0 == id }
        if activeTabId == id {
            activeTabId = openTabIds.last
        }
        if openTabIds.isEmpty {
            newNote()
        }
    }

    func selectNote(_ id: UUID) {
        if !openTabIds.contains(id) {
            openTabIds.append(id)
        }
        activeTabId = id
    }

    func updateNote(id: UUID, title: String? = nil, rtfData: Data? = nil) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if let t = title { notes[idx].title = t }
        if let d = rtfData {
            notes[idx].rtfData = d
            plainTextCache.removeValue(forKey: id)
        }
        notes[idx].updatedAt = Date()
        save()
    }

    /// Stop auto-deriving the title from body text (called when the user
    /// renames a tab).
    func markTitleAsManual(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[idx].titleIsManual else { return }
        notes[idx].titleIsManual = true
        save()
    }

    /// Derive a sidebar / tab title from the first non-empty body line.
    static func autoTitle(from body: String, maxWords: Int = 3) -> String? {
        for rawLine in body.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            line = stripLeadingListMarker(from: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            return truncateAutoTitle(line, maxWords: maxWords)
        }
        return nil
    }

    private static func stripLeadingListMarker(from line: String) -> String {
        var s = line
        if s.hasPrefix("▎ ") { s = String(s.dropFirst(2)) }
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["• ", "☐ ", "☑ ", "- ", "* "] {
            if s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        }
        if s.hasPrefix("> ") { return String(s.dropFirst(2)) }
        if let regex = try? NSRegularExpression(pattern: #"^\d+\.\s"#),
           let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            return (s as NSString).substring(from: match.range.length)
        }
        return s
    }

    private static func truncateAutoTitle(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if words.count <= maxWords { return words.joined(separator: " ") }
        return words.prefix(maxWords).joined(separator: " ")
    }

    /// Update an untitled note's name from its body. `persist: false` refreshes
    /// the tab/sidebar live while typing; `true` writes notes.json.
    func syncAutoTitleIfNeeded(for id: UUID, persist: Bool = true) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].kind == .richText, !notes[idx].titleIsManual else { return }

        let nextTitle = Self.autoTitle(from: plainText(for: id)) ?? "Untitled"
        guard notes[idx].title != nextTitle else { return }
        notes[idx].title = nextTitle
        notes[idx].updatedAt = Date()
        if persist { save() }
    }

    /// Called from the editor on every keystroke. Cheap: marks the note's
    /// body dirty and (re)arms the debounce timer. The actual RTF-encode +
    /// disk write happen in flushPendingSaves() once typing pauses.
    func noteBodyDidChange(_ id: UUID) {
        if !isNoteBodyEmpty(id) {
            sessionEmptyNoteIds.remove(id)
        }
        syncAutoTitleIfNeeded(for: id, persist: false)
        pendingDirtyNoteIds.insert(id)
        editGenerations[id, default: 0] += 1
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: saveDebounceInterval, repeats: false
        ) { [weak self] _ in
            self?.flushPendingSavesInBackground()
        }
    }

    /// Debounce-timer flush. Snapshots dirty storages on the main thread
    /// (cheap copy), RTF-encodes on a background queue (the expensive part),
    /// then applies the result and persists back on the main thread — so the
    /// save never stalls typing the way the synchronous flush did.
    ///
    /// Safety invariants:
    /// - Dirty ids are NOT cleared until their encoded data is applied, so
    ///   the synchronous flush (app switch / quit) can never miss edits that
    ///   were mid-encode.
    /// - A note edited *during* encoding (edit-generation mismatch) stays
    ///   dirty; the re-armed debounce re-encodes the newer text. Its stale
    ///   snapshot is still applied — newer than disk, older than live.
    /// - If a synchronous flush raced ahead and already persisted newer
    ///   content (clearing the dirty mark), the late apply is skipped.
    func flushPendingSavesInBackground(completion: (() -> Void)? = nil) {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        guard !pendingDirtyNoteIds.isEmpty else { completion?(); return }

        var snapshots: [(id: UUID, text: NSAttributedString, generation: UInt64)] = []
        for id in Array(pendingDirtyNoteIds) {
            guard let storage = sharedStorages[id] else {
                // Note was permanently deleted while dirty — nothing to save.
                pendingDirtyNoteIds.remove(id)
                continue
            }
            snapshots.append((id, NSAttributedString(attributedString: storage),
                              editGenerations[id] ?? 0))
        }
        guard !snapshots.isEmpty else { completion?(); return }

        encodeQueue.async { [weak self] in
            let encoded: [(id: UUID, data: Data, generation: UInt64)] = snapshots.compactMap {
                let full = NSRange(location: 0, length: $0.text.length)
                guard let data = try? $0.text.data(
                    from: full,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ) else { return nil }
                return ($0.id, data, $0.generation)
            }
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self else { return }
                let now = Date()
                var didApply = false
                for item in encoded {
                    guard self.pendingDirtyNoteIds.contains(item.id),
                          let idx = self.notes.firstIndex(where: { $0.id == item.id })
                    else { continue }
                    self.notes[idx].rtfData = item.data
                    self.notes[idx].updatedAt = now
                    self.plainTextCache.removeValue(forKey: item.id)
                    didApply = true
                    if self.editGenerations[item.id] == item.generation {
                        self.pendingDirtyNoteIds.remove(item.id)
                    }
                    self.syncAutoTitleIfNeeded(for: item.id, persist: false)
                }
                if didApply { self.save() }
            }
        }
    }

    /// Encode every dirty note's live NSTextStorage to RTF, fold it into the
    /// model, and persist. No-ops when nothing is dirty, so it's safe to call
    /// eagerly (e.g. on app resign/terminate). Synchronous so it completes
    /// before the process exits on quit.
    func flushPendingSaves() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        guard !pendingDirtyNoteIds.isEmpty else { return }
        let ids = pendingDirtyNoteIds
        pendingDirtyNoteIds.removeAll()
        let now = Date()
        for id in ids {
            guard let idx = notes.firstIndex(where: { $0.id == id }),
                  let storage = sharedStorages[id] else { continue }
            let full = NSRange(location: 0, length: storage.length)
            // Keep the last good rtfData if encoding ever fails — assigning
            // a failed `try?` result directly would null out the note's
            // persisted content.
            if let encoded = try? storage.data(
                from: full,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                notes[idx].rtfData = encoded
            }
            notes[idx].updatedAt = now
            plainTextCache.removeValue(forKey: id)
            syncAutoTitleIfNeeded(for: id, persist: false)
        }
        save()
    }

    /// The note's current rich-text content. Prefers the live shared
    /// NSTextStorage (always up to date with the latest keystrokes, even
    /// ones not yet re-encoded to RTF) and falls back to decoding the
    /// persisted RTF. Used by the exporter so files match what's on screen.
    func attributedContent(for id: UUID) -> NSAttributedString {
        if let storage = sharedStorages[id] {
            return NSAttributedString(attributedString: storage)
        }
        return notes.first(where: { $0.id == id })?.attributedContent ?? NSAttributedString()
    }

    /// Export a note to a file the user picks, in the given format,
    /// preserving its formatting.
    func exportNote(_ id: UUID, as format: ExportFormat) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        // API pages have no RTF body to export; the UI hides the Export menu
        // for them, but guard here too so a stray call can't write an empty file.
        guard note.kind == .richText else { return }
        NoteExporter.export(note: note, content: attributedContent(for: id), format: format)
    }

    /// Create a note from pre-built rich-text content: RTF-encode `content`,
    /// insert it at the top, open it as a tab, make it active, and persist.
    /// The general "note from existing content" primitive used by import;
    /// the editor's shared storage decodes the RTF (and runs the usual
    /// paragraph / whitespace / theme-color normalization) when first opened.
    @discardableResult
    func addNote(title: String, content: NSAttributedString) -> UUID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = Note(title: trimmed.isEmpty ? "Untitled" : trimmed)
        note.titleIsManual = true
        let full = NSRange(location: 0, length: content.length)
        note.rtfData = try? content.data(
            from: full,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.insert(note, at: 0)
        }
        openTabIds.append(note.id)
        activeTabId = note.id
        save()
        return note.id
    }

    /// Show an open panel and import each selected Markdown / plain-text file
    /// as a new note, preserving Markdown formatting. Unreadable files are
    /// collected and surfaced afterward without aborting the rest.
    func importFiles() {
        // Bring the app forward so the panel is front-most even when invoked
        // from the non-activating floating panel (same trick as the exporter).
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ImportFormat.allowedContentTypes
        panel.title = "Import Notes"
        panel.prompt = "Import"

        panel.begin { [self] response in
            guard response == .OK else { return }
            var failures: [String] = []
            var lastImported: UUID?
            for url in panel.urls {
                do {
                    let content = try NoteImporter.attributedString(forFileAt: url)
                    let title = url.deletingPathExtension().lastPathComponent
                    lastImported = addNote(title: title, content: content)
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            if let id = lastImported { activeTabId = id }
            if !failures.isEmpty { NoteImporter.presentImportError(files: failures) }
        }
    }

    func togglePin(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].isPinned.toggle()
        }
        save()
    }

    /// Add `tag` to the note if not already present. Tags are trimmed and
    /// lowercased to keep "Work" and " work " from being treated as
    /// different tags.
    func addTag(_ tag: String, to id: UUID) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if !notes[idx].tags.contains(normalized) {
            notes[idx].tags.append(normalized)
            save()
        }
    }

    func removeTag(_ tag: String, from id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].tags.removeAll { $0 == tag }
        save()
    }

    /// Soft-delete: move the note to the Trash. Tab is closed (since the
    /// main list hides trashed notes) but storage + plain-text cache are
    /// preserved so Restore returns the note intact, including any edits
    /// that hadn't been re-encoded to RTF yet.
    func deleteNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].deletedAt = Date()
        }
        closeTab(id)
        save()
    }

    /// Bring a trashed note back to the active list. Doesn't reopen it as
    /// a tab — the user can click it in the sidebar to do that.
    func restoreNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].deletedAt = nil
        }
        save()
    }

    /// Permanent deletion — drops the note, its shared storage, and its
    /// plain-text cache. No undo.
    func permanentlyDeleteNote(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.removeAll { $0.id == id }
        }
        sharedStorages.removeValue(forKey: id)
        plainTextCache.removeValue(forKey: id)
        save()
    }

    /// Permanently delete every trashed note.
    func emptyTrash() {
        let ids = trashedNotes.map { $0.id }
        for id in ids { permanentlyDeleteNote(id) }
    }

    /// True when a rich-text note has no meaningful body content (ignoring
    /// whitespace). Prefers the live shared storage over persisted RTF.
    func isNoteBodyEmpty(_ id: UUID) -> Bool {
        plainText(for: id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Drop user-created notes that still have no body text when the app
    /// quits. Called after flushPendingSaves() so the final body is encoded.
    /// Notes created at launch (bootstrap) are not tracked and are kept.
    func purgeUnusedSessionNotesOnQuit() {
        guard !sessionEmptyNoteIds.isEmpty else { return }
        let toRemove = sessionEmptyNoteIds.filter { id in
            guard let note = notes.first(where: { $0.id == id }) else { return false }
            return note.kind == .richText && !note.isTrashed && isNoteBodyEmpty(id)
        }
        guard !toRemove.isEmpty else { return }
        for id in toRemove {
            dropNoteData(for: id)
        }
        notes.removeAll { toRemove.contains($0.id) }
        openTabIds.removeAll { toRemove.contains($0) }
        if let active = activeTabId, toRemove.contains(active) {
            activeTabId = openTabIds.last
        }
        sessionEmptyNoteIds.subtract(toRemove)
        save()
    }

    private func dropNoteData(for id: UUID) {
        sharedStorages.removeValue(forKey: id)
        plainTextCache.removeValue(forKey: id)
        pendingDirtyNoteIds.remove(id)
        editGenerations.removeValue(forKey: id)
        sessionEmptyNoteIds.remove(id)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else {
            // No store file yet (first launch) — start fresh.
            newNote(userInitiated: false)
            return
        }
        lastAccountedDiskHash = Self.contentHash(of: data)
        guard let decoded = try? JSONDecoder().decode([Note].self, from: data) else {
            // The file exists but can't be decoded. Move it aside before
            // newNote() → save() writes a fresh store, so one corrupt byte
            // can never silently erase the user's entire note history.
            backupCorruptStoreFile()
            newNote(userInitiated: false)
            return
        }
        notes = decoded
        recordSyncedSnapshot()
        // Don't auto-open a trashed note. If everything is trashed (or the
        // file is empty), fall through to creating a fresh note.
        if let firstActive = notes.first(where: { !$0.isTrashed }) {
            openTabIds = [firstActive.id]
            activeTabId = firstActive.id
        } else {
            newNote(userInitiated: false)
        }
    }

    /// Preserve an undecodable notes.json as notes.json.corrupt-<timestamp>
    /// next to the original, so it can be inspected / recovered by hand.
    private func backupCorruptStoreFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = saveURL.lastPathComponent + ".corrupt-" + formatter.string(from: Date())
        let destination = saveURL.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.moveItem(at: saveURL, to: destination)
    }

    func save() {
        // Fold in any external write (MCP server) that landed since we last
        // read the file — the directory watcher is debounced, so a save can
        // race ahead of it. Skipping this would overwrite the external
        // change with our stale in-memory copy.
        reloadFromDiskIfExternallyChanged()
        guard let data = try? JSONEncoder().encode(notes) else { return }
        guard (try? data.write(to: saveURL, options: .atomic)) != nil else { return }
        lastAccountedDiskHash = Self.contentHash(of: data)
        recordSyncedSnapshot()
    }
}
