import SwiftUI
import PDFKit
import FBModels

/// Full-screen terminal procedure chart. Views are cached to disk on first
/// open, so anything viewed once is available in the air.
struct PlateViewerView: View {
    let plate: PlateMetadata

    @Environment(AppEnvironment.self) private var environment
    @State private var documentURL: URL?
    @State private var loadError = false
    @State private var georeference: PlateGeoreference?
    @AppStorage("plateNightMode") private var nightMode = false

    var body: some View {
        Group {
            if let documentURL {
                PDFDocumentView(url: documentURL)
                    .colorInvertIf(nightMode)
                    .ignoresSafeArea(edges: .bottom)
            } else if loadError {
                ContentUnavailableView(
                    "Chart Unavailable",
                    systemImage: "wifi.slash",
                    description: Text("This chart isn't downloaded and couldn't be fetched. Connect to the internet or download the airport's plates before flight.")
                )
            } else {
                ProgressView("Loading chart…")
            }
        }
        .navigationTitle(plate.chartName)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    environment.activePlateOverlay = plate
                    environment.requestedTab = .map
                } label: {
                    Image(systemName: "map")
                }
                .disabled(georeference == nil)
                .help(georeference == nil
                    ? "This chart can't be georeferenced (approach charts and most airport diagrams can)"
                    : "Show on map")
                .accessibilityIdentifier("plate.showOnMap")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    nightMode.toggle()
                } label: {
                    Image(systemName: nightMode ? "sun.max" : "moon")
                }
                .help("Night mode")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if documentURL != nil, georeference == nil {
                Text("Not georeferenced — approach charts and most airport diagrams can overlay the map.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
        .task(id: plate) {
            do {
                let url = try await environment.plateStore.fetch(plate)
                documentURL = url
                georeference = await PlateGeoreferenceResolver.resolve(
                    plate: plate, url: url, database: environment.aeroDatabase
                )
            } catch {
                loadError = true
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func colorInvertIf(_ inverted: Bool) -> some View {
        if inverted {
            colorInvert().hueRotation(.degrees(180))
        } else {
            self
        }
    }
}

#if canImport(UIKit)
private struct PDFDocumentView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
#else
private struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
#endif
