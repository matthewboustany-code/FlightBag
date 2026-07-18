import SwiftUI

/// What the map's non-modal info panel is showing.
enum MapInspection: Identifiable, Equatable {
    case airport(id: String)
    case advisories(InspectedAdvisories)

    var id: String {
        switch self {
        case .airport(let id): "airport-\(id)"
        case .advisories(let inspected): inspected.id.uuidString
        }
    }

    static func == (lhs: MapInspection, rhs: MapInspection) -> Bool {
        lhs.id == rhs.id
    }
}

/// Non-modal info card over the map — the map stays visible and scrubbable
/// around it. Compact widths get a bottom card; regular (iPad) gets a
/// floating side card. Presented via `.overlay` in MapHomeView, never a
/// sheet, so nothing blocks map interaction outside the card.
struct MapInfoPanel: View {
    let inspection: MapInspection
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .offset(y: max(0, dragOffset))
    }

    private var isCompact: Bool { sizeClass == .compact }

    private var header: some View {
        HStack {
            if case .advisories(let inspected) = inspection {
                Text(inspected.advisories.count == 1 ? "Advisory" : "\(inspected.advisories.count) Advisories")
                    .font(.headline)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.infoPanel.close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            if isCompact {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 36, height: 5)
                    .padding(.top, 5)
            }
        }
        .contentShape(Rectangle())
        // Dismiss drag lives on the header only — a card-wide gesture would
        // fight the List's scroll.
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard isCompact else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    dragOffset = 0
                    if isCompact, value.translation.height > 80 { onClose() }
                }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch inspection {
        case .airport(let id):
            // AirportDetailView brings its own navigation (plates, weather);
            // give it a stack local to the card.
            NavigationStack {
                AirportDetailView(airportId: id)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .advisories(let inspected):
            AdvisoryListView(advisories: inspected.advisories)
        }
    }
}

/// Details for advisories under a map tap (shared by the info panel).
struct AdvisoryListView: View {
    let advisories: [AdvisoryDisplayInfo]

    var body: some View {
        List(advisories) { advisory in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(advisory.color))
                        .frame(width: 10, height: 10)
                    Text(advisory.title)
                        .font(.headline)
                }
                if !advisory.subtitle.isEmpty {
                    Text(advisory.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !advisory.detail.isEmpty {
                    Text(advisory.detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
