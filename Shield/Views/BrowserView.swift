import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        TabContent(tab: tabs.current)
            .id(tabs.current.id)
            .fullScreenCover(isPresented: $tabs.showingTabs) { TabsView() }
    }
}

/// Pantalla principal de una pestaña: web + barra inferior al estilo Safari/Brave.
private struct TabContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var blocker: ContentBlocker

    @State private var address = ""
    @State private var addressFocused = false
    @State private var showSettings = false
    @State private var showShieldPanel = false
    @State private var showMedia = false
    @State private var showDownloads = false
    @State private var showHistory = false
    @State private var downloadNotice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var barDrag: CGFloat = 0
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ZStack(alignment: .top) {
                    ZStack(alignment: .topLeading) {
                        WebViewContainer(webView: tab.webView)
                        if let video = tab.nativeVideo {
                            InlinePlayerOverlay(video: video, tab: tab, placement: tab.playerPlacement)
                                .id(video.id)
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                    .opacity(tab.url == nil ? 0 : 1)
                    if tab.url == nil {
                        StartPageView(isPrivate: tab.isPrivate) { tab.load($0) }
                    }
                    if tab.isLoading {
                        ProgressView(value: tab.progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                    }
                    if addressFocused {
                        suggestionsPanel
                    }
                }
                VStack(spacing: 8) {
                    if tabs.recentlyClosed != nil {
                        undoToast
                    }
                    if let downloadNotice, !addressFocused {
                        downloadToast(downloadNotice)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .animation(.easeInOut(duration: 0.2), value: tabs.recentlyClosed?.id)
            .animation(.easeInOut(duration: 0.2), value: downloadNotice)
            bottomBar
        }
        .background(tab.isPrivate ? Color.purple.opacity(0.15) : Color(.systemBackground))
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showMedia) { MediaView(tab: tab) }
        .sheet(isPresented: $showHistory) {
            HistoryView { url in tab.load(url.absoluteString) }
        }
        .sheet(isPresented: $showDownloads) { NavigationStack { DownloadsView() } }
        .sheet(isPresented: $showShieldPanel) {
            ShieldPanel(tab: tab).presentationDetents([.medium])
        }
        .onChange(of: downloads.items.first?.id) { _, id in
            guard id != nil, let item = downloads.items.first else { return }
            showDownloadNotice("Descargando «\(item.name)»")
        }
    }

    // MARK: - Sugerencias de la barra de direcciones

    /// Búsquedas anteriores y páginas del historial que coinciden con lo escrito.
    private var suggestionsPanel: some View {
        let typed = address == (tab.url?.absoluteString ?? "") ? "" : address
        let items = tab.isPrivate && typed.isEmpty ? [] : history.suggestions(for: typed)
        return Group {
            if !items.isEmpty {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.kind == .search ? "magnifyingglass" : "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Button { address = item.text } label: {
                                Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Completar")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { submit(item.text) }
                        .swipeActions {
                            Button("Borrar", role: .destructive) {
                                if item.kind == .search {
                                    history.deleteSearch(item.text)
                                } else if let entry = history.entries.first(where: { $0.url.absoluteString == item.text }) {
                                    history.delete(entry)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
                .background(Color(.systemBackground))
                .transition(.opacity)
            }
        }
    }

    private func submit(_ text: String) {
        tab.load(text)
        addressFocused = false
    }

    // MARK: - Avisos temporales

    private var undoToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.square").foregroundStyle(.secondary)
            Text("Pestaña cerrada").font(.footnote.bold())
            Spacer()
            Button("Deshacer") { tabs.undoClose() }
                .font(.footnote.bold())
                .foregroundStyle(.orange)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func downloadToast(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text(text).font(.footnote).lineLimit(1)
            Spacer()
            Button("Ver") { showDownloads = true; downloadNotice = nil }
                .font(.footnote.bold())
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func showDownloadNotice(_ text: String) {
        downloadNotice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { downloadNotice = nil }
        }
    }

    // MARK: - Barra inferior

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { showShieldPanel = true } label: {
                    Image(systemName: tab.shieldsActive ? "shield.lefthalf.filled" : "shield.slash")
                        .foregroundStyle(tab.shieldsActive ? Color.orange : Color.secondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Escudos")

                Group {
                    if addressFocused {
                        AddressField(text: $address, isFocused: $addressFocused) { submit(address) }
                    } else {
                        HStack(spacing: 4) {
                            if tab.url?.scheme == "https" {
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(displayHost)
                                .lineLimit(1)
                                .foregroundStyle(tab.url == nil ? Color.secondary : Color.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            address = tab.url?.absoluteString ?? ""
                            addressFocused = true
                        }
                        // Deslizar la barra a los lados cambia de pestaña, como en Safari.
                        .offset(x: barDrag)
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onChanged { value in
                                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                    barDrag = value.translation.width * 0.4
                                }
                                .onEnded { value in
                                    let dx = value.translation.width
                                    withAnimation(.easeOut(duration: 0.2)) { barDrag = 0 }
                                    guard abs(dx) > 60, abs(dx) > abs(value.translation.height) else { return }
                                    tabs.selectAdjacent(dx < 0 ? 1 : -1)
                                }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                if addressFocused {
                    Button("Cancelar") { addressFocused = false }
                } else {
                    Button { if tab.isLoading { tab.stop() } else { tab.reload() } } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .disabled(tab.url == nil)
                }
            }

            if !addressFocused {
                HStack {
                    toolbarButton("chevron.backward", enabled: tab.canGoBack) { tab.goBack() }
                    toolbarButton("chevron.forward", enabled: tab.canGoForward) { tab.goForward() }
                    Button { showMedia = true } label: {
                        Image(systemName: "arrow.down.circle")
                            .overlay(alignment: .topTrailing) {
                                if tab.videoCount > 0 || downloads.activeCount > 0 {
                                    Text("\(downloads.activeCount > 0 ? downloads.activeCount : tab.videoCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .background(downloads.activeCount > 0 ? Color.blue : Color.orange, in: Capsule())
                                        .offset(x: 8, y: -6)
                                }
                            }
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(tab.url == nil)
                    .accessibilityLabel("Descargar vídeos e imágenes")
                    Button {
                        tab.captureSnapshot()
                        tabs.showingTabs = true
                    } label: {
                        Text("\(tabs.tabs.count)")
                            .font(.footnote.bold())
                            .frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                            .frame(maxWidth: .infinity)
                    }
                    .contextMenu {
                        Button { tabs.newTab() } label: { Label("Nueva pestaña", systemImage: "plus.square") }
                        Button { tabs.newTab(isPrivate: true) } label: {
                            Label("Nueva pestaña privada", systemImage: "eyeglasses")
                        }
                        Divider()
                        Button(role: .destructive) { tabs.closeWithUndo(tab) } label: {
                            Label("Cerrar esta pestaña", systemImage: "xmark")
                        }
                    }
                    .accessibilityLabel("Pestañas")
                    Menu {
                        Button { tabs.newTab() } label: { Label("Nueva pestaña", systemImage: "plus.square") }
                        Button { tabs.newTab(isPrivate: true) } label: {
                            Label("Nueva pestaña privada", systemImage: "eyeglasses")
                        }
                        Divider()
                        if let url = tab.url {
                            ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                        }
                        Button { showHistory = true } label: {
                            Label("Historial", systemImage: "clock.arrow.circlepath")
                        }
                        Button { showDownloads = true } label: {
                            Label("Descargas", systemImage: "tray.and.arrow.down")
                        }
                        Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(maxWidth: .infinity)
                    }
                }
                .font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var displayHost: String {
        guard let url = tab.url else {
            return blocker.isReady ? "Buscar o escribir dirección" : blocker.status
        }
        return url.host() ?? url.absoluteString
    }

    private func toolbarButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }
}

/// Campo de la barra de direcciones. Es un UITextField para que al tocarlo se
/// seleccione toda la dirección (escribir encima la reemplaza) y tenga botón de borrar.
private struct AddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Buscar o escribir dirección"
        field.keyboardType = .webSearch
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.text = text
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        init(_ parent: AddressField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            DispatchQueue.main.async { field.selectAll(nil) }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// Panel de escudos: estado para el sitio actual, igual que el león de Brave.
private struct ShieldPanel: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var blocker: ContentBlocker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: tab.shieldsActive ? "shield.lefthalf.filled" : "shield.slash")
                            .font(.largeTitle)
                            .foregroundStyle(tab.shieldsActive ? Color.orange : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(tab.url?.host() ?? "Sin página").font(.headline)
                            Text(tab.shieldsActive ? "Escudos ACTIVADOS" : "Escudos DESACTIVADOS")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("En esta página") {
                    LabeledContent("Pop-ups y capas trampa bloqueados", value: "\(tab.popupsBlocked)")
                    if let popup = tab.blockedPopup, ["http", "https"].contains(popup.scheme ?? "") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Último pop-up bloqueado").font(.footnote)
                                Text(popup.host() ?? popup.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Abrir") {
                                tab.openBlockedPopup()
                                dismiss()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    LabeledContent("Anuncios y capas flotantes eliminados", value: "\(tab.cosmeticBlocked)")
                    LabeledContent("Reglas de bloqueo cargadas", value: blocker.ruleCount.formatted())
                }
                Section {
                    Button(tab.shieldsActive ? "Desactivar escudos en este sitio" : "Activar escudos en este sitio") {
                        tab.toggleShieldsForCurrentSite()
                        dismiss()
                    }
                    .disabled(tab.url?.host() == nil || !ShieldSettings.globalShields)
                } footer: {
                    Text("Anuncios, rastreadores, pop-ups y banners se bloquean a nivel de red con EasyList, EasyPrivacy, EasyList Español, Peter Lowe y HaGeZi; las capas flotantes que insertan scripts de anuncios se eliminan automáticamente.")
                }
            }
            .navigationTitle("Escudos")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
