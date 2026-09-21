import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var blocker: ContentBlocker
    @EnvironmentObject private var tabs: TabManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ShieldSettings.searchEngineKey) private var engine = SearchEngine.duckDuckGo.rawValue
    @AppStorage(ShieldSettings.globalShieldsKey) private var globalShields = true
    @AppStorage(DownloadManager.autoSaveKey) private var autoSaveToPhotos = true
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Búsqueda") {
                    Picker("Motor de búsqueda", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }
                Section {
                    Toggle("Escudos (bloquear anuncios y rastreadores)", isOn: $globalShields)
                        .tint(.orange)
                        .onChange(of: globalShields) { _, _ in
                            tabs.tabs.forEach { $0.reload() }
                        }
                    LabeledContent("Reglas activas", value: blocker.ruleCount.formatted())
                    if blocker.droppedRules > 0 {
                        LabeledContent("Reglas descartadas", value: "\(blocker.droppedRules)")
                    }
                    Button("Restablecer excepciones por sitio") { ShieldSettings.resetSiteExceptions() }
                } header: {
                    Text("Escudos")
                } footer: {
                    Text("Listas: EasyList, EasyPrivacy, EasyList Español, Peter Lowe. Se actualizan en cada compilación de la app.")
                }
                Section {
                    Toggle("Guardar descargas en Fotos", isOn: $autoSaveToPhotos).tint(.orange)
                    NavigationLink("Ver descargas") { DownloadsView() }
                } header: {
                    Text("Descargas")
                } footer: {
                    Text("Todo se guarda también en Archivos → En mi iPhone → Shield. Los vídeos HLS en formato .ts no se pueden añadir a Fotos; ábrelos con VLC.")
                }
                Section("Privacidad") {
                    Button("Borrar historial, cookies y caché", role: .destructive) {
                        WKWebsiteDataStore.default().removeData(
                            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: .distantPast) { cleared = true }
                    }
                    if cleared { Text("Datos borrados ✓").foregroundStyle(.secondary) }
                }
                Section("Acerca de") {
                    LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    LabeledContent("Motor", value: "WebKit (WKWebView)")
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } }
            }
        }
    }
}
