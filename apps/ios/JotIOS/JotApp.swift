import SwiftUI
import PhotosUI

@main
struct JotPhoneApp: App {
    @State private var store = JotStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            JotRootView(store: store)
                .onChange(of: phase) { _, value in
                    if value != .active { store.flush() }
                }
        }
    }
}

struct JotRootView: View {
    @Bindable var store: JotStore
    @State private var pickedPhoto: PhotosPickerItem?
    var body: some View {
        Group {
            if store.configured {
                VStack(spacing: 0) {
                    HStack {
                        Button("Jots", systemImage: "line.3.horizontal") { store.showLibrary = true }.disabled(store.importingImage)
                        Spacer()
                        Button("New Jot", systemImage: "square.and.pencil") { store.newJot() }
                            .keyboardShortcut("n", modifiers: .command)
                            .disabled(store.importingImage)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    PhoneEditor(store: store)
                    HStack(spacing: 28) {
                        Button { store.send(["version": 1, "type": "toggleFormat", "format": "bold"]) } label: { Image(systemName: "bold") }
                            .accessibilityLabel("Bold")
                        Button { store.send(["version": 1, "type": "toggleFormat", "format": "italic"]) } label: { Image(systemName: "italic") }
                            .accessibilityLabel("Italic")
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Image(systemName: "photo")
                        }.accessibilityLabel("Add image").disabled(store.importingImage)
                        Spacer()
                        if store.importingImage { ProgressView().controlSize(.small) }
                        Button { store.webView?.endEditing(true) } label: { Image(systemName: "keyboard.chevron.compact.down") }
                            .accessibilityLabel("Dismiss keyboard")
                    }.font(.system(size: 17)).padding(.horizontal, 24).padding(.vertical, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer()
                    Text("A place for\nyour thoughts.").font(.system(size: 36, weight: .semibold)).tracking(-1)
                    Text("Choose where your jots live.").foregroundStyle(.secondary)
                    Button("On This iPhone") { store.configureLocal() }.buttonStyle(.borderedProminent)
                    Text("Your jots stay on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: pickedPhoto) {
            guard let pickedPhoto else { return }
            do {
                guard let data = try await pickedPhoto.loadTransferable(type: Data.self) else {
                    store.error = "This photo couldn’t be opened. Please choose it again."
                    return
                }
                store.insertPickedImage(data)
            } catch { store.error = "This photo couldn’t be opened. Please choose it again." }
            self.pickedPhoto = nil
        }
        .sheet(item: $store.imagePreview, onDismiss: { store.focus() }) { preview in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: preview.image).resizable().scaledToFit()
                        .frame(maxWidth: UIScreen.main.bounds.width)
                        .accessibilityLabel("Attached image")
                }
                .navigationTitle("Image").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { store.imagePreview = nil } } }
            }
        }
        .tint(Color.primary)
        .background(Color(uiColor: .systemBackground))
        .fullScreenCover(isPresented: $store.showLibrary, onDismiss: { store.focus() }) { JotLibraryView(store: store) }
        .alert("Your writing is protected", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct JotLibraryView: View {
    @Bindable var store: JotStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(store.notes, id: \.id) { note in
                Button { store.open(note) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(note.title.isEmpty ? "Untitled jot" : note.title).font(.body.weight(.medium)).lineLimit(2)
                        Text(note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(note.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.primary)
            }
            .listStyle(.plain)
            .overlay { if store.notes.isEmpty { ContentUnavailableView(store.query.isEmpty ? "Your jots will appear here" : "No matching jots", systemImage: "text.alignleft") } }
            .navigationTitle("Jots")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .searchable(text: $store.query, prompt: "Search your jots")
            .task(id: store.query) { await store.refreshNotes() }
        }.tint(.primary)
    }
}
