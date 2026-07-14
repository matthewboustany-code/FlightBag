import SwiftUI
import SwiftData
import PDFKit
import VisionKit
import UniformTypeIdentifiers

/// Per-flight documents: import files, scan paper with the camera, view
/// anything attached. Bytes live in the model via external storage, so
/// documents work offline and sync with the flight when CloudKit arrives.
struct DocumentsSection: View {
    @Bindable var flight: Flight
    @Environment(\.modelContext) private var modelContext

    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var importError: String?

    var body: some View {
        Section("Documents") {
            ForEach(flight.documents ?? []) { document in
                NavigationLink {
                    DocumentViewerView(document: document)
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(document.title)
                            Text(document.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: iconName(for: document))
                    }
                }
            }
            .onDelete { offsets in
                let documents = flight.documents ?? []
                for offset in offsets {
                    modelContext.delete(documents[offset])
                }
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Import Document", systemImage: "folder")
            }
            .accessibilityIdentifier("documents.import")

            if VNDocumentCameraViewController.isSupported {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                attachScans(images)
            }
            .ignoresSafeArea()
        }
    }

    private func iconName(for document: FlightDocument) -> String {
        document.contentType == UTType.pdf.identifier ? "doc.richtext" : "photo"
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension) ?? .data
                let document = FlightDocument(
                    title: url.deletingPathExtension().lastPathComponent,
                    contentType: type.identifier
                )
                document.data = data
                document.flight = flight
                flight.documents = (flight.documents ?? []) + [document]
            } catch {
                importError = "Couldn't import \(url.lastPathComponent)"
            }
        }
    }

    private func attachScans(_ images: [UIImage]) {
        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let document = FlightDocument(
                title: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))\(images.count > 1 ? " (\(index + 1))" : "")",
                contentType: UTType.jpeg.identifier
            )
            document.data = data
            document.flight = flight
            flight.documents = (flight.documents ?? []) + [document]
        }
    }
}

/// Displays an attached document: PDFKit for PDFs, scalable image otherwise.
struct DocumentViewerView: View {
    let document: FlightDocument

    var body: some View {
        Group {
            if let data = document.data {
                if document.contentType == UTType.pdf.identifier {
                    PDFDocumentView(data: data)
                } else if let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal])
                    }
                } else {
                    ContentUnavailableView("Can't display this document", systemImage: "doc.questionmark")
                }
            } else {
                ContentUnavailableView("Document is empty", systemImage: "doc")
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// VisionKit document camera; unavailable in the simulator, so callers hide
/// their scan button behind `isSupported`.
private struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let dismiss: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, dismiss: @escaping () -> Void) {
            self.onScan = onScan
            self.dismiss = dismiss
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            dismiss()
        }
    }
}
