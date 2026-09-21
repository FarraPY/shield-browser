import SwiftUI

struct StartPageView: View {
    let isPrivate: Bool
    let open: (String) -> Void
    @EnvironmentObject private var blocker: ContentBlocker

    private struct Favorite: Identifiable {
        let name: String, host: String
        var id: String { host }
    }

    private let favorites = [
        Favorite(name: "YouTube", host: "m.youtube.com"), Favorite(name: "Wikipedia", host: "es.wikipedia.org"),
        Favorite(name: "Marca", host: "marca.com"), Favorite(name: "El País", host: "elpais.com"),
        Favorite(name: "Reddit", host: "reddit.com"), Favorite(name: "X", host: "x.com"),
        Favorite(name: "Amazon", host: "amazon.es"), Favorite(name: "GitHub", host: "github.com"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: isPrivate ? "eyeglasses" : "shield.lefthalf.filled")
                        .font(.system(size: 56))
                        .foregroundStyle(isPrivate ? Color.purple : Color.orange)
                    Text(isPrivate ? "Pestaña privada" : "Shield")
                        .font(.largeTitle.bold())
                    Text(isPrivate
                         ? "No se guarda historial, cookies ni caché al cerrar."
                         : "Navegación sin anuncios ni rastreadores.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)

                HStack(spacing: 6) {
                    if !blocker.isReady { ProgressView() }
                    Text(blocker.status).font(.footnote).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 18) {
                    ForEach(favorites) { fav in
                        Button { open(fav.host) } label: {
                            VStack(spacing: 6) {
                                Text(String(fav.name.prefix(1)))
                                    .font(.title2.bold())
                                    .frame(width: 56, height: 56)
                                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                                Text(fav.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
        }
        .background(isPrivate ? Color.purple.opacity(0.08) : Color(.systemBackground))
    }
}
