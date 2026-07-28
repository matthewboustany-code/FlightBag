import SwiftUI
import FBModels

/// Live METAR/TAF with flight-category badge; falls back to the cached copy
/// with an explicit age stamp when offline.
struct WeatherSection: View {
    let station: ICAOIdentifier

    @Environment(AppEnvironment.self) private var environment
    @State private var weather: WeatherStore.StationWeather?
    @State private var isStale = false
    @State private var isLoading = true
    @AppStorage("weatherShowDecoded") private var showDecoded = false
    @AppStorage(UnitSystemPreference.defaultsKey) private var unitSystem = UnitSystemPreference.automatic.rawValue

    /// Units for the station being displayed, so an airport screen reads in
    /// local convention even when the pilot is elsewhere.
    private var units: UnitPreferences {
        (UnitSystemPreference(rawValue: unitSystem) ?? .automatic)
            .preferences(for: .forIdentifier(station))
    }

    var body: some View {
        Section {
            if isLoading && weather == nil {
                HStack {
                    ProgressView()
                    Text("Fetching weather…").foregroundStyle(.secondary)
                }
            } else if let metar = weather?.metar {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // VFR/MVFR/IFR/LIFR are FAA definitions. Other states
                        // set their own VMC/IMC minima, so showing the badge
                        // outside US airspace asserts a threshold that does
                        // not apply there.
                        if let category = metar.flightCategory,
                           Jurisdiction.forIdentifier(station).ruleSet.usesFlightCategories {
                            FlightCategoryBadge(category: category)
                        }
                        Spacer()
                        ageStamp
                    }
                    if showDecoded {
                        ForEach(WeatherDecoder.decode(metar, units: units), id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(metar.raw)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        decodedSummary(metar)
                    }
                    Picker("Format", selection: $showDecoded) {
                        Text("Raw").tag(false)
                        Text("Decoded").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("weather.format")
                }
                .padding(.vertical, 2)
                if let taf = weather?.taf {
                    DisclosureGroup("TAF") {
                        if showDecoded {
                            ForEach(WeatherDecoder.decodeTAF(taf.raw, units: units), id: \.header) { group in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.header)
                                        .font(.callout.weight(.semibold))
                                    ForEach(group.conditions, id: \.self) { condition in
                                        Text(condition)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } else {
                            Text(taf.raw)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("No weather reported for \(station.rawValue)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Weather")
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(.caption)
            }
        }
        // Re-reads when FIS-B uplink delivers new text for any station, so
        // weather appears in flight without tapping refresh.
        .task(id: RefreshKey(station: station, fisbVersion: environment.fisbWeatherVersion)) {
            await refresh()
        }
    }

    @ViewBuilder
    private var ageStamp: some View {
        HStack(spacing: 6) {
            if weather?.source == .fisb {
                Label("via ADS-B", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let fetchedAt = weather?.metar?.observationTime ?? weather?.fetchedAt {
                Text(isStale ? "Cached · \(fetchedAt, style: .relative) ago" : "Observed \(fetchedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(isStale ? .orange : .secondary)
            }
        }
    }

    private func decodedSummary(_ metar: Metar) -> some View {
        HStack(spacing: 16) {
            if let direction = metar.windDirectionDegrees, let speed = metar.windSpeedKt {
                let gust = metar.windGustKt.map { "G\($0)" } ?? ""
                Label("\(String(format: "%03d", direction))° @ \(speed)\(gust) kt", systemImage: "wind")
            } else if metar.windIsVariable, let speed = metar.windSpeedKt {
                Label("VRB @ \(speed) kt", systemImage: "wind")
            }
            if let visibility = metar.visibilitySM {
                Label(
                    units.formatVisibility(statuteMiles: visibility, isAtLeast: metar.visibilityIsAtLeast),
                    systemImage: "eye"
                )
            }
            if let temperature = metar.temperatureC {
                Label("\(Int(temperature.rounded()))°C", systemImage: "thermometer.medium")
            }
            if let altimeter = metar.altimeterHpa {
                Label(units.formatAltimeter(hPa: altimeter), systemImage: "gauge.with.needle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private struct RefreshKey: Equatable {
        let station: ICAOIdentifier
        let fisbVersion: Int
    }

    private func refresh() async {
        isLoading = true
        let result = await environment.weatherStore.weather(for: station)
        weather = result.weather
        isStale = result.isStale
        isLoading = false
    }
}

struct FlightCategoryBadge: View {
    let category: FlightCategory

    var body: some View {
        Text(category.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch category {
        case .vfr: .green
        case .mvfr: .blue
        case .ifr: .red
        case .lifr: .purple
        }
    }
}
