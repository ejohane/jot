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
                    if value == .background { store.dictation.interrupted(); store.flush() }
                    else if value == .inactive { store.flush() }
                    else if value == .active { store.preserveCloudConflicts(); store.reconcileCloudNote() }
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
                        Button("Jots", systemImage: "line.3.horizontal") { store.openLibrary() }.disabled(!store.ready || store.importingImage || store.storageBusy || store.reconciling || store.dictation.active)
                        Spacer()
                        Button("New Jot", systemImage: "square.and.pencil") { store.newJot() }
                            .keyboardShortcut("n", modifiers: .command)
                            .disabled(!store.ready || store.importingImage || store.storageBusy || store.reconciling || store.dictation.active)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    PhoneEditor(store: store).allowsHitTesting(store.ready && !store.storageBusy && !store.reconciling)
                        .overlay {
                            if !store.ready {
                                VStack(spacing: 16) {
                                    if store.openingNotebook { ProgressView("Opening your notebook…") }
                                    else { Button("Try Opening Again") { store.retryOpeningNotebook() } }
                                }.padding(24).background(Color(uiColor: .systemBackground))
                            }
                        }
                    HStack(spacing: 4) {
                        Button { store.send(["version": 1, "type": "toggleFormat", "format": "bold"]) } label: { Image(systemName: "bold").frame(width: 44, height: 44) }
                            .accessibilityLabel("Bold")
                        Button { store.send(["version": 1, "type": "toggleFormat", "format": "italic"]) } label: { Image(systemName: "italic").frame(width: 44, height: 44) }
                            .accessibilityLabel("Italic")
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Image(systemName: "photo").frame(width: 44, height: 44)
                        }.accessibilityLabel("Add image").disabled(!store.ready || store.importingImage || store.storageBusy || store.reconciling || store.dictation.active)
                        if store.dictation.active {
                            Button { store.dictation.finish() } label: { Image(systemName: "checkmark").frame(width: 44, height: 44) }
                                .accessibilityLabel("Keep dictation").disabled(store.dictation.state != .recording)
                            Button { store.dictation.cancel() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                .accessibilityLabel("Cancel dictation")
                        } else {
                            Button { store.toggleDictation() } label: { Image(systemName: "mic").frame(width: 44, height: 44) }
                                .accessibilityLabel("Start dictation").disabled(store.importingImage || store.storageBusy)
                        }
                        Spacer()
                        if store.dictation.state == .preparing || store.dictation.state == .finishing { ProgressView().controlSize(.small) }
                        if store.importingImage { ProgressView().controlSize(.small) }
                        Button { store.webView?.endEditing(true) } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }
                            .accessibilityLabel("Dismiss keyboard")
                    }.font(.system(size: 17)).padding(.horizontal, 16).padding(.vertical, 4)
                        .disabled(!store.ready || store.storageBusy || store.reconciling)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer()
                    Text("A place for\nyour thoughts.").font(.system(size: 36, weight: .semibold)).tracking(-1)
                    Text(store.session.storage == .iCloud ? "Open your iCloud notebook to continue." : "Choose where your jots live.").foregroundStyle(.secondary)
                    Button("On This iPhone") { store.configureLocal() }.buttonStyle(.borderedProminent)
                        .disabled(store.storageBusy || store.session.storage == .iCloud)
                    Button(store.session.storage == .iCloud ? "Try iCloud Again" : "iCloud") { store.configureCloud() }.buttonStyle(.bordered)
                        .disabled(store.storageBusy)
                    if store.storageBusy { ProgressView("Opening your notebook…") }
                    Text("Keep jots on this device, or share them with your Mac through iCloud.")
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
        .sheet(isPresented: $store.showSettings) { JotStorageSettings(store: store) }
        .fullScreenCover(isPresented: $store.showLibrary, onDismiss: { store.focus() }) { JotLibraryView(store: store) }
        .alert("Jot", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.hasConflict { Button("Keep Both Versions") { store.preserveBothVersions() } }
            Button(store.hasConflict ? "Keep Editing" : "OK", role: .cancel) { store.error = nil }
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
                        if !note.isDownloaded { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary) }
                        Text(note.title.isEmpty ? "Untitled jot" : note.title).font(.body.weight(.medium)).lineLimit(2)
                        Text(note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(note.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.primary)
            }
            .listStyle(.plain)
            .refreshable { store.retryCloudDownloads(); await store.refreshNotes() }
            .safeAreaInset(edge: .bottom) {
                if store.pendingCloudNotes > 0 {
                    Text("Waiting for \(store.pendingCloudNotes) iCloud jots. Search updates as they download.")
                        .font(.footnote).foregroundStyle(.secondary).padding(16)
                        .frame(maxWidth: .infinity).background(Color(uiColor: .systemBackground))
                }
            }
            .overlay { if store.notes.isEmpty { ContentUnavailableView(store.query.isEmpty ? "Your jots will appear here" : "No matching jots", systemImage: "text.alignleft") } }
            .navigationTitle("Jots")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { store.showSettings = true } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .sheet(isPresented: $store.showSettings) { JotStorageSettings(store: store) }
            .searchable(text: $store.query, prompt: "Search your jots")
            .task(id: store.query) { await store.refreshNotes() }
        }.tint(.primary)
    }
}

struct JotStorageSettings: View {
    @Bindable var store: JotStore
    @Environment(\.dismiss) private var dismiss
    @State private var destination: NotebookStorage?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your notebook") {
                    LabeledContent("Storage", value: store.storage == .local ? "On This iPhone" : "iCloud")
                    Button(store.storage == .local ? "Transfer to iCloud" : "Transfer to This iPhone") {
                        destination = store.storage == .local ? .iCloud : .local
                    }.disabled(store.storageBusy || store.importingImage || store.dictation.active)
                    if store.storageBusy { ProgressView("Transferring your jots…") }
                }
                Section {
                    Text("Your jots and images are copied together. The original notebook is retained as a backup. After switching, new changes save in the selected location.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.storageBusy) } }
            .confirmationDialog("Transfer your notebook?", isPresented: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })) {
                if let destination {
                    Button(destination == .iCloud ? "Transfer to iCloud" : "Transfer to This iPhone") { store.transfer(to: destination); self.destination = nil }
                }
                Button("Cancel", role: .cancel) { destination = nil }
            } message: { Text("All jots and images will be copied. The original notebook will be kept as a backup.") }
        }.interactiveDismissDisabled(store.storageBusy).tint(.primary)
    }
}
