import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        TabContent(tab: tabs.current)
            .id(tabs.current.id)
    }
}

/// Pantalla principal de una pestaña: web + barra inferior al estilo Safari/Brave.
private struct TabContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var blocker: ContentBlocker

    @State private var address = ""
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var showShieldPanel = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                WebViewContainer(webView: tab.webView)
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
            }
            bottomBar
        }
        .background(tab.isPrivate ? Color.purple.opacity(0.15) : Color(.systemBackground))
        .sheet(isPresented: $showTabs) { TabsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showShieldPanel) {
            ShieldPanel(tab: tab).presentationDetents([.medium])
        }
        .onChange(of: addressFocused) { _, focused in
            if focused { address = tab.url?.absoluteString ?? "" }
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

                ZStack(alignment: .leading) {
                    TextField("Buscar o escribir dirección", text: $address)
                        .focused($addressFocused)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { tab.load(address); addressFocused = false }
                        .opacity(addressFocused ? 1 : 0)
                    if !addressFocused {
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
                        .onTapGesture { addressFocused = true }
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
                    if let url = tab.url {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } else {
                        toolbarButton("square.and.arrow.up", enabled: false) {}
                    }
                    Button { showTabs = true } label: {
                        Text("\(tabs.tabs.count)")
                            .font(.footnote.bold())
                            .frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                            .frame(maxWidth: .infinity)
                    }
                    Menu {
                        Button { tabs.newTab() } label: { Label("Nueva pestaña", systemImage: "plus.square") }
                        Button { tabs.newTab(isPrivate: true) } label: {
                            Label("Nueva pestaña privada", systemImage: "eyeglasses")
                        }
                        Divider()
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
                    LabeledContent("Anuncios eliminados por script", value: "\(tab.cosmeticBlocked)")
                    LabeledContent("Reglas de bloqueo cargadas", value: blocker.ruleCount.formatted())
                }
                Section {
                    Button(tab.shieldsActive ? "Desactivar escudos en este sitio" : "Activar escudos en este sitio") {
                        tab.toggleShieldsForCurrentSite()
                        dismiss()
                    }
                    .disabled(tab.url?.host() == nil || !ShieldSettings.globalShields)
                } footer: {
                    Text("Anuncios, rastreadores, pop-ups y banners se bloquean a nivel de red con las listas EasyList, EasyPrivacy, EasyList Español y Peter Lowe.")
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
