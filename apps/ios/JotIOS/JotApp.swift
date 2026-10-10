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
                    if value == .background { store.sceneBecameBackground(); store.dictation.interrupted() }
                    else if value == .inactive { store.sceneBecameInactive() }
                    else if value == .active { store.sceneBecameActive(); store.preserveCloudConflicts(); store.reconcileCloudNote() }
                }
        }
    }
}

struct JotRootView: View {
    @Bindable var store: JotStore
    @State private var keyboardVisible = false
    @State private var formatPanelVisible = false
    @State private var reviewChromeHidden = false
    private var chromeHidden: Bool { keyboardVisible || reviewChromeHidden || formatPanelVisible }
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoLoadToken: UUID?
    private var navigationDisabled: Bool {
        !store.canEdit || store.importingImage || store.storageBusy || store.reconciling || store.dictation.active
    }
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if !chromeHidden {
            ToolbarItem(placement: .principal) {
                JotPageTitle(store: store).frame(width: 210, height: 36)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Jots", systemImage: "list.bullet") { store.openLibrary() }
                    .disabled(navigationDisabled)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Jot", systemImage: "square.and.pencil") { store.newJot() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(navigationDisabled)
            }
        }
    }

    private var keyboardControls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
            Button {
                formatPanelVisible = true
                store.webView?.endEditing(true)
            } label: { Image(systemName: "textformat").frame(width: 52, height: 44) }
                .accessibilityLabel("Format")
                .disabled(navigationDisabled)
            Spacer(minLength: 12)
            Button { store.send(["version": 1, "type": "setTextStyle", "style": "task"]) } label: { Image(systemName: "checklist").frame(width: 44, height: 44) }
                .accessibilityLabel("Checklist")
                .disabled(navigationDisabled)
            Spacer(minLength: 12)
            PhotosPicker(selection: Binding(get: { pickedPhoto }, set: { value in
                if let token = photoLoadToken { store.cancelPhotoLoad(token) }
                photoLoadToken = value == nil ? nil : store.beginPhotoLoad()
                pickedPhoto = photoLoadToken == nil ? nil : value
            }), matching: .images) {
                Image(systemName: "photo").frame(width: 44, height: 44)
            }.accessibilityLabel("Add image").disabled(!store.canEdit || store.importingImage || store.storageBusy || store.reconciling || store.dictation.active)
            Spacer(minLength: 12)
            if store.dictation.active {
                Button { store.dictation.finish() } label: { Image(systemName: "checkmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Keep dictation").disabled(!store.canEdit || store.storageBusy || store.reconciling || store.dictation.state != .recording)
                Button { store.dictation.cancel() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Cancel dictation")
                .disabled(!store.canEdit || store.storageBusy || store.reconciling)
            } else {
                Button { store.toggleDictation() } label: { Image(systemName: "mic.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Start dictation").disabled(!store.canEdit || store.importingImage || store.storageBusy || store.reconciling)
            }
            }
            Spacer(minLength: 12)
            if store.dictation.state == .preparing || store.dictation.state == .finishing { ProgressView().controlSize(.small) }
            if store.importingImage { ProgressView().controlSize(.small) }
            Button { store.webView?.endEditing(true) } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }
                .accessibilityLabel("Dismiss keyboard")
                .disabled(!store.canEdit || store.storageBusy || store.reconciling)
        }
        .buttonStyle(.plain)
        .font(.system(size: 21, weight: .semibold))
        .tint(.primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .modifier(KeyboardBarSurface())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    var body: some View {
        Group {
            if store.configured {
                NavigationStack {
                    PhoneEditor(store: store, reviewChromeHidden: reviewChromeHidden, onReviewScroll: {
                        if !keyboardVisible { withAnimation(.easeInOut(duration: 0.2)) { reviewChromeHidden = true } }
                    }, onReviewTap: {
                        if !keyboardVisible { withAnimation(.easeInOut(duration: 0.2)) { reviewChromeHidden = false } }
                    }).allowsHitTesting(store.canEdit && !store.storageBusy && !store.reconciling)
                        .overlay {
                            if !store.canEdit {
                                VStack(spacing: 16) {
                                    if store.openingNotebook || (!store.editorLoaded && !store.editorLoadFailed) { ProgressView("Opening your notebook…") }
                                    else { Button("Try Opening Again") { store.retryOpeningNotebook() } }
                                }.padding(24).background(Color(uiColor: .systemBackground))
                            }
                        }
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { editorToolbar }
                        // Keep the navigation and accessory layout slots stable across modes.
                        .toolbar(.visible, for: .navigationBar)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if formatPanelVisible {
                                JotFormatPanel(store: store) {
                                    formatPanelVisible = false
                                    store.focus()
                                }
                                .disabled(navigationDisabled)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                            } else {
                                keyboardControls
                                    .opacity(keyboardVisible ? 1 : 0)
                                    .allowsHitTesting(keyboardVisible)
                                    .accessibilityHidden(!keyboardVisible)
                            }
                        }
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
        .onChange(of: store.session.active?.id) { previous, _ in
            reviewChromeHidden = false
            if previous != nil { formatPanelVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            guard !store.showLibrary && !store.showSettings && store.imagePreview == nil else { return }
            keyboardVisible = true
            formatPanelVisible = false
            reviewChromeHidden = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            reviewChromeHidden = false
        }
        .task(id: pickedPhoto) {
            guard let pickedPhoto, let token = photoLoadToken else { return }
            defer {
                store.cancelPhotoLoad(token)
                if photoLoadToken == token { self.pickedPhoto = nil; photoLoadToken = nil }
            }
            do {
                guard let data = try await pickedPhoto.loadTransferable(type: Data.self) else {
                    if !Task.isCancelled, store.isCurrentPhotoLoad(token) { store.error = "This photo couldn’t be opened. Please choose it again." }
                    return
                }
                try Task.checkCancellation()
                store.finishPhotoLoad(data, token: token)
            } catch is CancellationError { }
            catch { if !Task.isCancelled, store.isCurrentPhotoLoad(token) { store.error = "This photo couldn’t be opened. Please choose it again." } }
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
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: Binding(get: { store.showSettings && !store.showLibrary }, set: { store.showSettings = $0 })) { JotStorageSettings(store: store) }
        .sheet(isPresented: $store.showLibrary, onDismiss: { store.focus() }) {
            JotLibraryView(store: store, onClose: { store.showLibrary = false })
        }
        .task(id: "\(store.ready)-\(store.configured)-\(store.session.active?.id ?? "new")") { await store.refreshPagingNotes() }
        .alert("Jot", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.hasConflict { Button("Keep Both Versions") { store.preserveBothVersions() } }
            Button(store.hasConflict ? "Keep Editing" : "OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct JotLibraryView: View {
    @Bindable var store: JotStore
    var onClose: () -> Void
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close Jots", systemImage: "chevron.left") { onClose() }
                        .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                }
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

private struct JotFormatPanel: View {
    @Bindable var store: JotStore
    var onClose: () -> Void
    @ScaledMetric private var controlHeight = 44
    private let accent = Color(uiColor: .systemYellow)
    private let styles: [(name: String, value: String, size: CGFloat, weight: Font.Weight)] = [
        ("Title", "heading1", 22, .bold),
        ("Heading", "heading2", 18, .bold),
        ("Subheading", "heading3", 14, .semibold),
        ("Body", "paragraph", 16, .regular)
    ]

    private func style(_ value: String) {
        store.send(["version": 1, "type": "setTextStyle", "style": value, "focus": false])
    }

    private func format(_ value: String) {
        store.send(["version": 1, "type": value == "code" ? "toggleCode" : "toggleFormat", "format": value, "focus": false])
    }

    private func control(_ label: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(selected ? Color.black : Color.primary)
                .frame(maxWidth: .infinity, minHeight: controlHeight)
                .background(selected ? accent : Color.clear)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 1) { content() }
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(Capsule())
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Format").font(.title3.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Close formatting")
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(styles, id: \.value) { item in
                        Button { style(item.value) } label: {
                            Text(item.name)
                                .font(.system(size: item.size, weight: item.weight))
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 16)
                                .frame(minHeight: controlHeight)
                                .foregroundStyle(store.textStyle == item.value ? Color.black : Color.primary)
                                .background(store.textStyle == item.value ? accent : Color.clear, in: Capsule())
                        }
                        .accessibilityAddTraits(store.textStyle == item.value ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())

            HStack(spacing: 14) {
                group {
                    control("Bold", icon: "bold", selected: store.boldActive) { format("bold") }
                    control("Italic", icon: "italic", selected: store.italicActive) { format("italic") }
                    control("Strikethrough", icon: "strikethrough", selected: store.activeFormats.contains("strikethrough")) { format("strikethrough") }
                }
                group {
                    control("Monospace", icon: "chevron.left.forwardslash.chevron.right", selected: store.activeFormats.contains("code")) { format("code") }
                }
                .frame(width: 64)
            }

            HStack(spacing: 14) {
                group {
                    control("Bulleted list", icon: "list.bullet", selected: store.textStyle == "bullet") { style(store.textStyle == "bullet" ? "paragraph" : "bullet") }
                    control("Checklist", icon: "checklist", selected: store.textStyle == "task") { style(store.textStyle == "task" ? "paragraph" : "task") }
                    control("Numbered list", icon: "list.number", selected: store.textStyle == "number") { style(store.textStyle == "number" ? "paragraph" : "number") }
                }
                group {
                    control("Decrease indent", icon: "decrease.indent") { store.send(["version": 1, "type": "changeListIndent", "direction": "out", "focus": false]) }
                    control("Increase indent", icon: "increase.indent") { store.send(["version": 1, "type": "changeListIndent", "direction": "in", "focus": false]) }
                }
                .frame(width: 96)
                group {
                    control("Block quote", icon: "text.quote", selected: store.textStyle == "quote") { style(store.textStyle == "quote" ? "paragraph" : "quote") }
                }
                .frame(width: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 32))
        .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format")
    }
}

private struct KeyboardBarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
