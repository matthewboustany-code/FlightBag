import Foundation
import CoreGraphics
import CoreLocation
import Testing
import FBModels
@testable import FlightBag

/// Real-chart fixtures: DoD-produced RNAV plates for KNIP and KNUW (cycle
/// 2607), which carry no embedded georeferencing. Candidate lists are the
/// surveyed NASR fixes/navaids/runway ends near each field, straight from
/// aero.sqlite — the same data the resolver feeds the matcher.
@Suite struct ApproachFixGeoreferenceTests {
    private static func C(_ id: String, _ lat: Double, _ lon: Double) -> ApproachFixGeoreference.Candidate {
        ApproachFixGeoreference.Candidate(identifier: id, latitude: lat, longitude: lon)
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "pdf"))
    }

    // MARK: Fixture candidate sets

    static let knipCandidates: [ApproachFixGeoreference.Candidate] = [
        // The plate's own procedure fixes.
        C("DUBTE", 30.23194722, -81.6202),
        C("DONNO", 30.23216388, -81.57186944),
        C("DUWOT", 30.23253888, -81.47568055),
        C("ITEGE", 30.10855, -81.75546111),
        C("JETSO", 29.90892222, -81.11269444),
        C("MADEN", 30.01849166, -81.69680555),
        C("SUBER", 30.45680277, -81.11262777),
        // Nearby decoys (nearest NASR fixes to the field).
        C("JUZSO", 30.21692777, -81.67435833),
        C("HIVIN", 30.23145277, -81.69975833),
        C("GRUEN", 30.23165833, -81.65421388),
        C("HEMBO", 30.2273, -81.62579444),
        C("JARPU", 30.227, -81.73206111),
        C("ZEMID", 30.28355277, -81.67061666),
        C("WABIB", 30.23270277, -81.74145),
        C("CFKDC", 30.17995277, -81.71115),
        C("APUPE", 30.23129444, -81.74749722),
        C("CFMKR", 30.20404722, -81.74729444),
        C("IVANZ", 30.23116666, -81.77001111),
        C("COGMO", 30.22175, -81.77005833),
        C("YIPUV", 30.225, -81.77057777),
        C("BUMPH", 30.22063055, -81.77218888),
        C("OZICO", 30.31716388, -81.675025),
        C("BLABR", 30.27978611, -81.76123611),
        C("HANUB", 30.31202777, -81.71701388),
        C("WANDU", 30.24633611, -81.77828611),
        C("FIGGY", 30.31425, -81.72255833),
        C("NOBUE", 30.21914444, -81.57275555),
        C("RINRT", 30.27563888, -81.58299722),
        C("IKUDE", 30.14803055, -81.732725),
        C("WORER", 30.14065277, -81.7145),
        C("GONYO", 30.21912222, -81.78905555),
        C("MAVBL", 30.13499444, -81.68510555),
        C("ODOFY", 30.33183333, -81.68982222),
        C("HIRUD", 30.29535277, -81.76865),
        C("OSTAF", 30.21626388, -81.79468611),
        C("KIRNE", 30.342575, -81.67506944),
        C("UHUCI", 30.32433888, -81.60475277),
        C("GURDE", 30.34122777, -81.64843888),
        C("EXKAF", 30.11669166, -81.67369444),
        C("WUKSO", 30.14021944, -81.59596944),
        C("CIROT", 30.14948611, -81.77959722),
        C("WINOV", 30.24863055, -81.54130555),
        C("MOSEL", 30.17544444, -81.54992222),
        C("HATFI", 30.21603888, -81.83170555),
        C("PARIY", 30.3048, -81.81128055),
        C("PAWPA", 30.35880555, -81.61365),
        C("AZELO", 30.30088055, -81.53931944),
        // Navaids.
        C("CRG", 30.33887919, -81.50992733),
        C("JA", 30.46504247, -81.80164788),
        C("NIP", 30.23485, -81.67505555),
        C("NRB", 30.38861469, -81.42307647),
        C("RYD", 29.96691666, -81.65766666),
        // Runway thresholds.
        C("RW10", 30.23158888, -81.69293611),
        C("RW28", 30.23173333, -81.66443055),
        C("RW14", 30.24256666, -81.67883416),
        C("RW32", 30.23100833, -81.66537222),
    ]

    static let knuwCandidates: [ApproachFixGeoreference.Candidate] = [
        // The plate's own procedure fixes.
        C("SOBEE", 48.53258888, -122.784525),
        C("ZONGU", 48.44253333, -122.72014444),
        C("FIDPO", 48.21116944, -122.55571388),
        C("WADPA", 48.11152222, -122.77461111),
        // Nearby decoys.
        C("JOVPO", 48.367375, -122.66895277),
        C("MEVRE", 48.36965, -122.66816388),
        C("KIGVE", 48.35393611, -122.61933333),
        C("NAVOE", 48.32923611, -122.63863333),
        C("JOGIP", 48.34969444, -122.69330555),
        C("FAXUT", 48.40935277, -122.69316388),
        C("ISLND", 48.41730277, -122.68902777),
        C("TOCUY", 48.34798333, -122.76478055),
        C("ZIGOG", 48.26504166, -122.60337777),
        C("MANKE", 48.26925277, -122.58469444),
        C("LEDEY", 48.35135, -122.51195277),
        C("TOTKE", 48.35715277, -122.50436666),
        C("ZATAX", 48.34647777, -122.80650833),
        C("LATRE", 48.26081388, -122.59090833),
        C("VUCUS", 48.25154444, -122.680375),
        C("KOYED", 48.33066666, -122.8072),
        C("ELLEK", 48.44821666, -122.71561666),
        C("KLSHN", 48.46198888, -122.64914722),
        C("COKMU", 48.41057777, -122.817475),
        C("NEPDE", 48.31880277, -122.8419),
        C("JEKPO", 48.25181388, -122.78045555),
        C("FAGAN", 48.20369722, -122.67781666),
        C("WANAK", 48.20288888, -122.67979444),
        C("LETEC", 48.48746944, -122.75221944),
        C("MALLS", 48.50603888, -122.59918611),
        C("SINVE", 48.51270277, -122.62076944),
        C("ROSFE", 48.20580555, -122.77461944),
        C("SLEGS", 48.51122777, -122.57536944),
        C("INAXE", 48.28696666, -122.88977222),
        C("MADEE", 48.34491666, -122.40133611),
        C("DULJE", 48.24810555, -122.45263888),
        C("JIRGU", 48.38772777, -122.91145),
        C("BBELT", 48.490925, -122.48893888),
        C("MIGLE", 48.34821388, -122.38709444),
        C("CANUN", 48.19780833, -122.52064722),
        C("CRUDN", 48.52935833, -122.62076944),
        C("JAVTO", 48.39894722, -122.39483888),
        C("IWANY", 48.45505277, -122.43361666),
        // Navaids.
        C("AW", 48.07611997, -122.15391163),
        C("CVV", 48.24469444, -122.72441666),
        C("FHR", 48.51213586, -123.02386227),
        C("NUW", 48.35493447, -122.66178811),
        C("PAE", 47.91983322, -122.27780177),
        // Runway thresholds.
        C("RW07", 48.35130541, -122.67288038),
        C("RW25", 48.35246413, -122.64003061),
        C("RW14", 48.36170344, -122.66250877),
        C("RW32", 48.34188527, -122.64841891),
    ]

    // MARK: Star detection

    @Test func detectsKNIPPlanviewStars() throws {
        let url = try Self.fixtureURL("KNIP-RNAV-Z-28")
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let stars = ApproachFixGeoreference.starCenters(in: ApproachFixGeoreference.filledPolygons(of: page))
        #expect(stars.count >= 8)
        // DUBTE and DUWOT star symbols at their drawn positions.
        for expected in [CGPoint(x: 131.8, y: 373.7), CGPoint(x: 190.4, y: 374.0)] {
            #expect(stars.contains { hypot($0.x - expected.x, $0.y - expected.y) < 1.5 })
        }
    }

    // MARK: Real-chart registration

    @Test func registersKNIP() throws {
        let url = try Self.fixtureURL("KNIP-RNAV-Z-28")
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let stars = ApproachFixGeoreference.starCenters(in: ApproachFixGeoreference.filledPolygons(of: page))
        let fit = try #require(ApproachFixGeoreference.register(stars: stars, candidates: Self.knipCandidates))

        #expect(fit.inlierIdentifiers.count >= 7)
        for id in ["DUBTE", "DONNO", "DUWOT", "ITEGE"] {
            #expect(fit.inlierIdentifiers.contains(id))
        }
        #expect(abs(fit.transform.rotationDegrees) < 0.5)
        #expect(fit.transform.scale > 200 && fit.transform.scale < 280)
        #expect(fit.rmsMeters / fit.transform.scale < 0.6)  // sub-point residual
    }

    @Test func registersKNUW() throws {
        let url = try Self.fixtureURL("KNUW-RNAV-14")
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let stars = ApproachFixGeoreference.starCenters(in: ApproachFixGeoreference.filledPolygons(of: page))
        let fit = try #require(ApproachFixGeoreference.register(stars: stars, candidates: Self.knuwCandidates))

        #expect(fit.inlierIdentifiers.count >= 5)
        for id in ["SOBEE", "ZONGU", "FIDPO", "WADPA"] {
            #expect(fit.inlierIdentifiers.contains(id))
        }
        #expect(abs(fit.transform.rotationDegrees) < 0.5)
        #expect(fit.rmsMeters / fit.transform.scale < 0.6)
    }

    @Test func knipEndToEndMatchCoversTheFinalApproach() throws {
        let url = try Self.fixtureURL("KNIP-RNAV-Z-28")
        let georef = try #require(ApproachFixGeoreference.match(url: url, candidates: Self.knipCandidates))
        #expect(georef.pageIndex == 1)
        // The georeferenced region must cover the final approach course:
        // runway threshold through the IF.
        let lats = georef.corners.map(\.latitude)
        let lons = georef.corners.map(\.longitude)
        for (lat, lon) in [(30.23173333, -81.66443055), (30.23253888, -81.47568055)] {
            #expect(lat > lats.min()! && lat < lats.max()!)
            #expect(lon > lons.min()! && lon < lons.max()!)
        }
    }

    // MARK: Rejection

    @Test func rejectsMismatchedCandidates() throws {
        // KNIP's chart against KNUW's fixes: no consistent constellation.
        let url = try Self.fixtureURL("KNIP-RNAV-Z-28")
        #expect(ApproachFixGeoreference.match(url: url, candidates: Self.knuwCandidates) == nil)
    }

    @Test func rejectsTooFewStars() throws {
        let stars = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 150, y: 300), CGPoint(x: 90, y: 250)]
        #expect(ApproachFixGeoreference.register(stars: stars, candidates: Self.knipCandidates) == nil)
    }

    // MARK: Synthetic round-trip

    @Test func recoversAKnownTransform() throws {
        // Fixes on an irregular constellation, page points derived through
        // a known north-up transform (scale 240 m/pt), plus decoy stars
        // that match nothing.
        let scale = 240.0
        let origin = CLLocationCoordinate2D(latitude: 35.0, longitude: -100.0)
        let projection = ApproachFixGeoreference.LocalProjection(
            originLatitude: origin.latitude, originLongitude: origin.longitude
        )
        let meterPositions: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(9_000, 1_500), SIMD2(19_000, 800), SIMD2(-6_000, -11_000),
            SIMD2(-15_000, 7_000), SIMD2(4_000, -19_000),
        ]
        let candidates = meterPositions.enumerated().map { index, m -> ApproachFixGeoreference.Candidate in
            let coordinate = projection.coordinate(fromMeters: m)
            return ApproachFixGeoreference.Candidate(
                identifier: "FIX\(index)", latitude: coordinate.latitude, longitude: coordinate.longitude
            )
        }
        // Page points: p = (m - t) / scale with y shared (rotation 0).
        let stars = meterPositions.map { CGPoint(x: ($0.x + 30_000) / scale, y: ($0.y + 30_000) / scale) }
            + [CGPoint(x: 40, y: 500), CGPoint(x: 300, y: 40)]  // decoys

        let fit = try #require(ApproachFixGeoreference.register(stars: stars, candidates: candidates))
        #expect(fit.inlierIdentifiers.count == 6)
        #expect(abs(fit.transform.scale - scale) < 2)
        #expect(abs(fit.transform.rotationDegrees) < 0.2)
        #expect(fit.rmsMeters < 30)
    }
}

private final class BundleToken {}
