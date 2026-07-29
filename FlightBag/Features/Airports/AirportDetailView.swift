import SwiftUI
import FBModels

struct AirportDetailView: View {
    let airportId: String
    var onView: (String) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @State private var detail: AeroDatabase.AirportDetail?
    @State private var loadFailed = false
    @AppStorage(UnitSystemPreference.defaultsKey) private var unitSystem = UnitSystemPreference.automatic.rawValue

    var body: some View {
        Group {
            if let detail {
                List {
                    infoSection(detail)
                    WeatherSection(station: weatherStation(for: detail))
                    runwaysSection(detail)
                    frequenciesSection(detail)
                    // Plates and coded procedures are FAA products. Outside US
                    // airspace an empty list would read as "this airport has
                    // no approaches", which is not what we know.
                    if jurisdiction(for: detail).supports(.plates) {
                        PlatesSection(plates: detail.plates)
                        ProceduresSection(airport: detail.airport)
                    } else {
                        Section("Procedures") {
                            CapabilityNotice(capability: .plates)
                        }
                    }
                    NotamSection(
                        station: weatherStation(for: detail),
                        jurisdiction: jurisdiction(for: detail)
                    )
                }
            } else if loadFailed {
                ContentUnavailableView("Airport Not Found", systemImage: "questionmark.circle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(detail?.airport.displayIdentifier ?? airportId)
        // Registered here, outside the lazy List, so plate links always resolve.
        .navigationDestination(for: PlateMetadata.self) { plate in
            PlateViewerView(plate: plate)
        }
        .task(id: airportId) {
            guard let db = environment.aeroDatabase else {
                loadFailed = true
                return
            }
            do {
                detail = try await db.airportDetail(id: airportId)
                if let detail {
                    onView(detail.airport.displayIdentifier)
                } else {
                    loadFailed = true
                }
            } catch {
                loadFailed = true
            }
        }
    }

    /// METARs are reported under the ICAO identifier when one exists.
    private func weatherStation(for detail: AeroDatabase.AirportDetail) -> ICAOIdentifier {
        detail.airport.icaoId ?? ICAOIdentifier(detail.airport.id)
    }

    private func jurisdiction(for detail: AeroDatabase.AirportDetail) -> Jurisdiction {
        .forAirport(country: detail.airport.country, identifier: detail.airport.icaoId)
    }

    /// Units for the airport on screen, so a European field reads in metres
    /// even when the pilot's own base is in the US.
    private func units(for detail: AeroDatabase.AirportDetail) -> UnitPreferences {
        (UnitSystemPreference(rawValue: unitSystem) ?? .automatic)
            .preferences(for: jurisdiction(for: detail))
    }

    private func infoSection(_ detail: AeroDatabase.AirportDetail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.airport.name)
                    .font(.title3.bold())
                Text([detail.airport.city, detail.airport.state].compactMap(\.self).joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            if let elevation = detail.airport.elevationFeet {
                LabeledContent("Elevation", value: "\(units(for: detail).formatAltitude(feet: elevation)) MSL")
            }
            if let tpa = detail.trafficPatternAltitude {
                LabeledContent("Pattern Altitude", value: "\(units(for: detail).formatAltitude(feet: tpa)) MSL")
            }
            magneticVariationRow(detail)
            LabeledContent("Coordinates") {
                Text(String(format: "%.4f, %.4f", detail.airport.coordinate.latitude, detail.airport.coordinate.longitude))
                    .monospaced()
            }
            if detail.facilityUse == "PR" {
                Label("Private facility — prior permission required", systemImage: "lock")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Magnetic variation, published where NASR has it and computed from the
    /// World Magnetic Model everywhere else.
    ///
    /// The published figure wins when present: it is what the state charted
    /// the runways against, so preferring a computed value would put this row
    /// at odds with the runway headings just below it. Outside the US no
    /// published figure exists — OurAirports carries none — and before the
    /// model this row simply disappeared, which read as "this airport has no
    /// variation" rather than "we don't have it".
    @ViewBuilder
    private func magneticVariationRow(_ detail: AeroDatabase.AirportDetail) -> some View {
        if let published = detail.airport.magneticVariation {
            LabeledContent("Magnetic Variation", value: AngleFormat.variation(published))
        } else {
            let result = WorldMagneticModel.wmm2025.field(
                at: detail.airport.coordinate,
                on: Date(),
                altitudeFeet: Double(detail.airport.elevationFeet ?? 0)
            )
            LabeledContent("Magnetic Variation") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(AngleFormat.variation(result.field.declination))
                    Text(result.validity == .valid ? "Computed (WMM)" : "Computed (WMM, expired)")
                        .font(.caption2)
                        .foregroundStyle(result.validity == .valid ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private func runwaysSection(_ detail: AeroDatabase.AirportDetail) -> some View {
        Section("Runways") {
            if detail.airport.runways.isEmpty {
                Text("No runway data").foregroundStyle(.secondary)
            }
            ForEach(detail.airport.runways, id: \.self) { runway in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(runway.designator)
                            .font(.headline.monospaced())
                        Spacer()
                        if let length = runway.lengthFeet, let width = runway.widthFeet {
                            let prefs = units(for: detail)
                            Text("\(prefs.formatRunwayLength(feet: Double(length))) × \(prefs.formatRunwayLength(feet: Double(width)))")
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: 12) {
                        if let surface = runway.surface {
                            Text(surfaceName(surface))
                        }
                        ForEach(runway.ends.filter { $0.displacedThresholdFeet ?? 0 > 0 }, id: \.designator) { end in
                            Text("\(end.designator): displaced \(end.displacedThresholdFeet ?? 0)′")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func frequenciesSection(_ detail: AeroDatabase.AirportDetail) -> some View {
        Section("Frequencies") {
            if detail.airport.frequencies.isEmpty {
                Text("No published frequencies").foregroundStyle(.secondary)
            }
            ForEach(groupedFrequencies(detail.airport.frequencies), id: \.use) { group in
                LabeledContent(group.use) {
                    Text(group.values.joined(separator: "  "))
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func groupedFrequencies(_ frequencies: [Frequency]) -> [FrequencyDisplay.Group] {
        FrequencyDisplay.grouped(frequencies)
    }

    private func surfaceName(_ code: String) -> String {
        switch code.uppercased() {
        case "CONC": "Concrete"
        case "ASPH", "ASPH-CONC": "Asphalt"
        case "TURF": "Turf"
        case "GRVL": "Gravel"
        case "DIRT": "Dirt"
        case "WATER": "Water"
        default: code
        }
    }
}

enum FrequencyDisplay {
    struct Group {
        let use: String
        let values: [String]
    }

    /// Groups by use, ordered the way pilots expect (ATIS, clearance,
    /// ground, tower, approach…). Every published frequency is shown —
    /// VHF first, then UHF, so joint-use fields see both bands.
    static func grouped(_ frequencies: [Frequency]) -> [Group] {
        let order = ["ATIS", "CD", "GND", "TWR", "CTAF", "APP", "DEP", "APP/DEP", "EMERG"]
        return Dictionary(grouping: frequencies, by: \.use)
            .map { use, freqs in
                let sorted = freqs.sorted {
                    let aUHF = $0.kHz >= 138_000
                    let bUHF = $1.kHz >= 138_000
                    return aUHF == bUHF ? $0.kHz < $1.kHz : !aUHF
                }
                return Group(use: use, values: sorted.map(\.megahertzDisplay))
            }
            .sorted { a, b in
                let ai = order.firstIndex(of: a.use) ?? order.count
                let bi = order.firstIndex(of: b.use) ?? order.count
                return ai == bi ? a.use < b.use : ai < bi
            }
    }
}
