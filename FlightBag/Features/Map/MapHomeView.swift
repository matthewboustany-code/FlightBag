import SwiftUI
import MapKit

/// Phase 2 replaces this with the full EFB map: MKMapView representable with
/// sectional/IFR chart tile overlays, radar, TFRs, and ownship.
struct MapHomeView: View {
    /// CONUS overview until chart overlays arrive.
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 45)
        )
    )

    var body: some View {
        Map(position: $position)
            .mapStyle(.standard(elevation: .flat))
            .overlay(alignment: .bottom) {
                Text("Chart overlays (sectional, IFR, radar, TFR) arrive in Phase 2")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
    }
}

#Preview {
    MapHomeView()
}
