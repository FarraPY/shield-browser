import SwiftUI

struct TabsView: View {
    @EnvironmentObject private var tabs: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tabs.tabs) { tab in
                    TabRow(tab: tab, selected: tab.id == tabs.selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tabs.selectedID = tab.id
                            dismiss()
                        }
                        .swipeActions {
                            Button("Cerrar", role: .destructive) { tabs.close(tab) }
                        }
                }
            }
            .navigationTitle("Pestañas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar todas", role: .destructive) { tabs.closeAll(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { tabs.newTab(isPrivate: true); dismiss() } label: {
                        Label("Privada", systemImage: "eyeglasses")
                    }
                    Spacer()
                    Button { tabs.newTab(); dismiss() } label: {
                        Label("Nueva", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                .foregroundStyle(tab.isPrivate ? Color.purple : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "Nueva pestaña" : tab.title).lineLimit(1)
                Text(tab.url?.host() ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.orange) }
        }
    }
}
