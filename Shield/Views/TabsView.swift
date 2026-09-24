import SwiftUI

/// Vista de pestañas en cuadrícula con miniaturas, como Safari: tocar una para
/// ir a ella, la ✕ o mantener pulsado para cerrarla, y normales/privadas por separado.
struct TabsView: View {
    @EnvironmentObject private var tabs: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivate = false
    @State private var confirmCloseAll = false

    private var visible: [BrowserTab] { tabs.tabs.filter { $0.isPrivate == showPrivate } }
    private var normalCount: Int { tabs.tabs.filter { !$0.isPrivate }.count }
    private var privateCount: Int { tabs.tabs.count - normalCount }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(visible) { tab in
                            TabCard(tab: tab, selected: tab.id == tabs.selectedID) {
                                tabs.select(tab)
                                dismiss()
                            } onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) { tabs.close(tab) }
                            }
                            .id(tab.id)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(14)
                }
                .onAppear {
                    showPrivate = tabs.current.isPrivate
                    if let id = tabs.selectedID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(showPrivate ? "Sin pestañas privadas" : "Sin pestañas",
                                           systemImage: showPrivate ? "eyeglasses" : "square.on.square",
                                           description: Text("Pulsa + para abrir una."))
                }
            }
            .background(showPrivate ? Color.purple.opacity(0.12) : Color(.secondarySystemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tipo", selection: $showPrivate) {
                        Text("Pestañas (\(normalCount))").tag(false)
                        Text("Privadas (\(privateCount))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }.bold()
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Cerrar todas", role: .destructive) { confirmCloseAll = true }
                        .disabled(visible.isEmpty)
                    Spacer()
                    Button {
                        tabs.newTab(isPrivate: showPrivate)
                        dismiss()
                    } label: {
                        Image(systemName: "plus").font(.title2.bold())
                    }
                    .accessibilityLabel(showPrivate ? "Nueva pestaña privada" : "Nueva pestaña")
                }
            }
            .confirmationDialog("¿Cerrar \(visible.count) pestañas?", isPresented: $confirmCloseAll,
                                titleVisibility: .visible) {
                Button("Cerrar todas", role: .destructive) {
                    withAnimation { tabs.closeAll(privateOnly: showPrivate) }
                }
            }
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                    .font(.caption)
                    .foregroundStyle(tab.isPrivate ? Color.purple : Color.orange)
                Text(tab.title.isEmpty ? (tab.url?.host() ?? "Nueva pestaña") : tab.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar pestaña")
            }
            .padding(.leading, 8)
            .padding(.vertical, 2)
            .background(.bar)

            ZStack {
                Color(.systemBackground)
                if let image = tab.snapshot, tab.url != nil {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: tab.url == nil ? "shield.lefthalf.filled" : "globe")
                            .font(.largeTitle)
                            .foregroundStyle(tab.isPrivate ? Color.purple : Color.orange)
                        if let host = tab.url?.host() {
                            Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.orange : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onSelect) { Label("Ir a esta pestaña", systemImage: "arrow.right.square") }
            Button(role: .destructive, action: onClose) { Label("Cerrar pestaña", systemImage: "xmark") }
        }
        .onAppear { if tab.snapshot == nil { tab.captureSnapshot() } }
    }
}
