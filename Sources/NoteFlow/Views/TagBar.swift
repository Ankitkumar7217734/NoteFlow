import SwiftUI

// Slim tag editor that sits below the editor body. Shows the note's
// current tags as removable chips and an inline "Add tag…" field.
struct TagBar: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    let note: Note

    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.iconColorDim)

                ForEach(note.tags, id: \.self) { tag in
                    TagChip(text: tag) {
                        store.removeTag(tag, from: note.id)
                    }
                }

                TextField("Add tag…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(theme.palette.text)
                    .focused($draftFocused)
                    .frame(minWidth: 80)
                    .onSubmit(commitDraft)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .background(theme.palette.chromeBackground)
    }

    private func commitDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.addTag(value, to: note.id)
        draft = ""
        draftFocused = true
    }
}

struct TagChip: View {
    @EnvironmentObject var theme: ThemeStore
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.palette.text)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.palette.iconColorDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.palette.activeRowBackground, in: Capsule())
    }
}
