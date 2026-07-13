import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import GRDB
import FBModels

/// Downloads the FAA d-TPP cycle metafile and writes plate metadata.
/// Chart PDFs stay on FAA servers (`https://aeronav.faa.gov/d-tpp/{cycle}/{pdf}`)
/// for now — the URL is stored per row so it can later point at our CDN.
struct DTPPIngestor {
    let workDirectory: URL
    let logger: (String) -> Void

    func run(cycle: DataCycle, into builder: AeroDatabaseBuilder) async throws {
        let metafileURL = workDirectory.appendingPathComponent("d-tpp_metafile_\(cycle.id).xml")
        if !FileManager.default.fileExists(atPath: metafileURL.path) {
            let remote = URL(string: "https://aeronav.faa.gov/d-tpp/\(cycle.id)/xml_data/d-tpp_Metafile.xml")!
            logger("Downloading d-TPP metafile for \(cycle.id)…")
            var request = URLRequest(url: remote)
            request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw IngestError("d-TPP metafile download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try data.write(to: metafileURL)
        } else {
            logger("Using cached d-TPP metafile")
        }

        let parser = DTPPMetafileParser()
        let metafileData = try Data(contentsOf: metafileURL)
        let records = try parser.parse(data: metafileData)
        logger("d-TPP: \(records.count) charts")

        try await builder.dbQueue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO plate (airport_id, chart_code, chart_name, pdf_name, cycle, url)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        record.airportId,
                        record.chartCode,
                        record.chartName,
                        record.pdfName,
                        cycle.id,
                        "https://aeronav.faa.gov/d-tpp/\(cycle.id)/\(record.pdfName)",
                    ]
                )
            }
        }
    }
}

struct DTPPChartRecord {
    var airportId: String
    var chartCode: String
    var chartName: String
    var pdfName: String
}

/// Streaming parser for the d-TPP metafile:
/// state_code > city_name > airport_name(apt_ident=…) > record > chart fields.
final class DTPPMetafileParser: NSObject, XMLParserDelegate {
    private var records: [DTPPChartRecord] = []
    private var currentAirportId: String?
    private var currentElement = ""
    private var chartCode = ""
    private var chartName = ""
    private var pdfName = ""
    private var parseError: Error?

    func parse(data: Data) throws -> [DTPPChartRecord] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parseError ?? parser.parserError ?? IngestError("d-TPP metafile parse failed")
        }
        return records
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "airport_name" {
            currentAirportId = attributeDict["apt_ident"]
        } else if elementName == "record" {
            chartCode = ""; chartName = ""; pdfName = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "chart_code": chartCode += string
        case "chart_name": chartName += string
        case "pdf_name": pdfName += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        currentElement = ""
        if elementName == "record" {
            let code = chartCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = chartName.trimmingCharacters(in: .whitespacesAndNewlines)
            let pdf = pdfName.trimmingCharacters(in: .whitespacesAndNewlines)
            // DELETED_JOB entries have no PDF; skip anything unrenderable.
            if let airportId = currentAirportId, !pdf.isEmpty, !name.isEmpty, pdf.uppercased().hasSuffix(".PDF") {
                records.append(DTPPChartRecord(airportId: airportId, chartCode: code, chartName: name, pdfName: pdf))
            }
        } else if elementName == "airport_name" {
            currentAirportId = nil
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }
}
