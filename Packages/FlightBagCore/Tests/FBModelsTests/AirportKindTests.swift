import Testing
@testable import FBModels

/// `kind` exists so a query can ask "is this an airport?" without knowing
/// which authority wrote the row. These pin the two dialects it reconciles.
struct AirportKindTests {
    @Test func mapsNASRSiteTypeCodes() {
        #expect(AirportKind.fromNASR(siteTypeCode: "A") == .airport)
        #expect(AirportKind.fromNASR(siteTypeCode: "H") == .heliport)
        #expect(AirportKind.fromNASR(siteTypeCode: "C") == .seaplaneBase)
        #expect(AirportKind.fromNASR(siteTypeCode: "B") == .balloonport)
        #expect(AirportKind.fromNASR(siteTypeCode: "G") == .gliderport)
        #expect(AirportKind.fromNASR(siteTypeCode: "U") == .ultralight)
    }

    /// small/medium/large is a size split, not a category one. Collapsing all
    /// three is the point: if only `large_airport` counted, most of the world's
    /// usable aerodromes would vanish from the map.
    @Test func mapsOurAirportsTypes() {
        #expect(AirportKind.fromOurAirports(type: "small_airport") == .airport)
        #expect(AirportKind.fromOurAirports(type: "medium_airport") == .airport)
        #expect(AirportKind.fromOurAirports(type: "large_airport") == .airport)
        #expect(AirportKind.fromOurAirports(type: "heliport") == .heliport)
        #expect(AirportKind.fromOurAirports(type: "seaplane_base") == .seaplaneBase)
        #expect(AirportKind.fromOurAirports(type: "balloonport") == .balloonport)
    }

    /// The regression this column was added for: EGLL and KAUS are both
    /// airports, and before `kind` the only available test matched one of them.
    @Test func heathrowAndAustinAgreeOnBeingAirports() {
        #expect(AirportKind.fromOurAirports(type: "large_airport") == .airport)
        #expect(AirportKind.fromNASR(siteTypeCode: "A") == .airport)
    }

    /// An unfamiliar or missing value must never land on `.airport` — that
    /// would put a closed strip or a future category on the map as if it were
    /// a usable aerodrome.
    @Test func unknownValuesFallBackToOtherRatherThanAirport() {
        #expect(AirportKind.fromNASR(siteTypeCode: nil) == .other)
        #expect(AirportKind.fromNASR(siteTypeCode: "") == .other)
        #expect(AirportKind.fromNASR(siteTypeCode: "Z") == .other)
        #expect(AirportKind.fromOurAirports(type: nil) == .other)
        #expect(AirportKind.fromOurAirports(type: "spaceport") == .other)
        // OurAirports' "closed" is filtered before insert, but if one ever
        // reaches here it must not read as an airport.
        #expect(AirportKind.fromOurAirports(type: "closed") == .other)
    }

    @Test func mappingIsCaseInsensitive() {
        #expect(AirportKind.fromNASR(siteTypeCode: "a") == .airport)
        #expect(AirportKind.fromOurAirports(type: "LARGE_AIRPORT") == .airport)
    }
}
