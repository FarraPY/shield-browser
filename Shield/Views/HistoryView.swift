import SwiftUI

/// Historial de páginas visitadas, agrupado por día y con buscador.
struct HistoryView: View {
    let open: (URL) -> Void
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    private struct DaySection: Identifiable {
        let day: Date
        var entries: [HistoryEntry]
        var id: Date { day }
    }

    /// Entradas agrupadas por día, del más reciente al más antiguo.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.date)
            if let last = result.last, last.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(DaySection(day: day, entries: [entry]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(title(for: section.day)) {
                        ForEach(section.entries) { entry in
                            Button {
                                open(entry.url)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe").foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Text(entry.url.host() ?? entry.url.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Text(entry.date, format: .dateTime.hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Borrar", role: .destructive) { history.delete(entry) }
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.url = entry.url } label: {
                                    Label("Copiar enlace", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: entry.url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { history.delete(entry) } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Sin historial", systemImage: "clock.arrow.circlepath",
                                               description: Text("Las páginas que visites aparecerán aquí. Las pestañas privadas no se guardan."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Buscar en el historial")
            .navigationTitle("Historial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Borrar", role: .destructive) { confirmClear = true }
                        .disabled(history.entries.isEmpty && history.searches.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
            .confirmationDialog("¿Borrar todo el historial y las búsquedas?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Borrar historial", role: .destructive) { history.clear() }
            }
        }
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
