import Foundation

/// The geomagnetic field at a place and time.
///
/// Components follow the standard geomagnetic frame: X north, Y east, Z down,
/// all in nanotesla. `declination` is the one a pilot cares about — the angle
/// from true north to magnetic north, east positive, which is the sign
/// convention `Airport.magneticVariation` already uses.
public struct MagneticField: Sendable, Hashable {
    /// Degrees, east positive. Add to a true course to get a magnetic course.
    public var declination: Double
    /// Dip angle in degrees, positive downward (northern hemisphere).
    public var inclination: Double
    /// Horizontal intensity, nT.
    public var horizontalIntensity: Double
    /// Total intensity, nT.
    public var totalIntensity: Double
    public var northComponent: Double
    public var eastComponent: Double
    public var downComponent: Double

    public init(
        declination: Double,
        inclination: Double,
        horizontalIntensity: Double,
        totalIntensity: Double,
        northComponent: Double,
        eastComponent: Double,
        downComponent: Double
    ) {
        self.declination = declination
        self.inclination = inclination
        self.horizontalIntensity = horizontalIntensity
        self.totalIntensity = totalIntensity
        self.northComponent = northComponent
        self.eastComponent = eastComponent
        self.downComponent = downComponent
    }
}

/// The World Magnetic Model — magnetic variation anywhere on earth, computed
/// rather than looked up.
///
/// Why this exists: `Airport.magneticVariation` comes from NASR, so it is
/// populated for US airports and nil for the ~66 000 aerodromes that arrive
/// from OurAirports, which publishes none. Without a model, every magnetic
/// course outside the US is simply missing — and a navlog that silently falls
/// back to true course is the dangerous kind of wrong, since the number still
/// looks like a heading you could fly.
///
/// The model is a degree-12 spherical harmonic expansion evaluated per NOAA's
/// WMM technical report. Coefficients live in `WMM2025Coefficients.swift`;
/// this file is the maths and holds no data of its own.
///
/// Linux-clean and dependency-free, so the server can compute the same
/// variation the app does.
public struct WorldMagneticModel: Sendable {
    public struct GaussCoefficient: Sendable, Hashable {
        public let n: Int
        public let m: Int
        /// nT at the model epoch.
        public let g: Double
        public let h: Double
        /// Secular variation, nT/year.
        public let gDot: Double
        public let hDot: Double

        public init(n: Int, m: Int, g: Double, h: Double, gDot: Double, hDot: Double) {
            self.n = n
            self.m = m
            self.g = g
            self.h = h
            self.gDot = gDot
            self.hDot = hDot
        }
    }

    /// How far the requested date sits from the model's supported range.
    ///
    /// WMM is fitted to a five-year window and its error grows quickly past
    /// the end of it — NOAA replaces the model rather than extending it. The
    /// value is still returned when expired, because a slightly stale
    /// variation beats none at all, but it is labelled so the UI can say the
    /// data needs updating instead of presenting it as current.
    public enum Validity: Sendable, Hashable {
        case valid
        /// The date precedes the model's window.
        case beforeModel
        /// The date is past the model's expiry — update the app.
        case expired
    }

    public struct Result: Sendable, Hashable {
        public var field: MagneticField
        public var validity: Validity

        public init(field: MagneticField, validity: Validity) {
            self.field = field
            self.validity = validity
        }
    }

    /// Decimal year the coefficients are referenced to.
    public let epoch: Double
    /// First and last decimal year the model is fitted for.
    public let validFrom: Double
    public let validUntil: Double
    let coefficients: [GaussCoefficient]
    let maxDegree: Int

    /// Flattened coefficient lookup, indexed by `index(n, m)`, so the
    /// summation reads a contiguous array rather than searching per term.
    private let table: [GaussCoefficient?]

    init(epoch: Double, validFrom: Double, validUntil: Double, coefficients: [GaussCoefficient]) {
        self.epoch = epoch
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.coefficients = coefficients
        let degree = coefficients.map(\.n).max() ?? 0
        self.maxDegree = degree

        var table = [GaussCoefficient?](repeating: nil, count: Self.index(degree, degree) + 1)
        for coefficient in coefficients {
            table[Self.index(coefficient.n, coefficient.m)] = coefficient
        }
        self.table = table
    }

    /// The model FlightBag ships. NOAA's WMM2025, valid 2025.0 through 2030.0.
    public static let wmm2025 = WorldMagneticModel(
        epoch: 2025.0,
        validFrom: 2025.0,
        validUntil: 2030.0,
        coefficients: wmm2025Coefficients
    )

    // MARK: - WGS84

    /// Semi-major axis, km.
    private static let semiMajorAxisKm = 6378.137
    /// Semi-minor axis, km.
    private static let semiMinorAxisKm = 6356.7523142
    /// Geomagnetic reference radius, km. Fixed by the model definition — this
    /// is not the same as the ellipsoid axis and must not be conflated with it.
    private static let geomagneticRadiusKm = 6371.2

    private static let eccentricitySquared =
        (semiMajorAxisKm * semiMajorAxisKm - semiMinorAxisKm * semiMinorAxisKm)
        / (semiMajorAxisKm * semiMajorAxisKm)

    // MARK: - Evaluation

    /// Magnetic variation in degrees, east positive — the common case.
    ///
    /// `altitudeFeet` is height above the WGS84 ellipsoid. It barely moves the
    /// answer at the altitudes an aircraft flies (hundredths of a degree), so
    /// callers without a figure can leave it at zero without meaningful loss.
    public func declination(
        at coordinate: Coordinate,
        on date: Date,
        altitudeFeet: Double = 0
    ) -> Double {
        field(at: coordinate, on: date, altitudeFeet: altitudeFeet).field.declination
    }

    public func field(
        at coordinate: Coordinate,
        on date: Date,
        altitudeFeet: Double = 0
    ) -> Result {
        field(
            at: coordinate,
            decimalYear: Self.decimalYear(from: date),
            altitudeKm: altitudeFeet * 0.0003048
        )
    }

    /// The evaluation everything else funnels into. Takes a decimal year
    /// directly, which is the form NOAA's test vectors use.
    public func field(
        at coordinate: Coordinate,
        decimalYear: Double,
        altitudeKm: Double = 0
    ) -> Result {
        let validity: Validity
        if decimalYear < validFrom {
            validity = .beforeModel
        } else if decimalYear > validUntil {
            validity = .expired
        } else {
            validity = .valid
        }

        let geodeticLatitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180

        // Geodetic → geocentric. The model is defined on a sphere, so the
        // latitude fed to the harmonics is not the latitude on the chart.
        let sinLatitude = sin(geodeticLatitude)
        let cosLatitude = cos(geodeticLatitude)
        let radiusOfCurvature = Self.semiMajorAxisKm
            / (1 - Self.eccentricitySquared * sinLatitude * sinLatitude).squareRoot()
        let projectedXY = (radiusOfCurvature + altitudeKm) * cosLatitude
        let projectedZ = (radiusOfCurvature * (1 - Self.eccentricitySquared) + altitudeKm) * sinLatitude
        let radius = (projectedXY * projectedXY + projectedZ * projectedZ).squareRoot()
        let sinGeocentricLatitude = projectedZ / radius
        let cosGeocentricLatitude = projectedXY / radius
        let geocentricLatitude = asin(sinGeocentricLatitude)

        let (legendre, legendreDerivative) = Self.schmidtLegendre(
            sinLatitude: sinGeocentricLatitude,
            cosLatitude: cosGeocentricLatitude,
            maxDegree: maxDegree
        )

        let yearsFromEpoch = decimalYear - epoch
        let radiusRatio = Self.geomagneticRadiusKm / radius

        // Precompute sin/cos of m·longitude by recursion rather than calling
        // the trig functions once per order.
        var sinLongitude = [Double](repeating: 0, count: maxDegree + 1)
        var cosLongitude = [Double](repeating: 0, count: maxDegree + 1)
        cosLongitude[0] = 1
        if maxDegree >= 1 {
            sinLongitude[1] = sin(longitude)
            cosLongitude[1] = cos(longitude)
            for m in 2...max(2, maxDegree) where m <= maxDegree {
                sinLongitude[m] = sinLongitude[m - 1] * cosLongitude[1] + cosLongitude[m - 1] * sinLongitude[1]
                cosLongitude[m] = cosLongitude[m - 1] * cosLongitude[1] - sinLongitude[m - 1] * sinLongitude[1]
            }
        }

        var north = 0.0
        var east = 0.0
        var down = 0.0

        for n in 1...maxDegree {
            let attenuation = pow(radiusRatio, Double(n + 2))
            for m in 0...n {
                guard let coefficient = table[Self.index(n, m)] else { continue }
                let g = coefficient.g + yearsFromEpoch * coefficient.gDot
                let h = coefficient.h + yearsFromEpoch * coefficient.hDot
                let index = Self.index(n, m)

                let inPhase = g * cosLongitude[m] + h * sinLongitude[m]
                let quadrature = g * sinLongitude[m] - h * cosLongitude[m]

                down -= attenuation * inPhase * Double(n + 1) * legendre[index]
                east += attenuation * Double(m) * quadrature * legendre[index]
                north -= attenuation * inPhase * legendreDerivative[index]
            }
        }

        // The east component carries a 1/cos(latitude) that is singular at the
        // poles; within ~1e-10 of them it needs the separate expansion below.
        if abs(cosGeocentricLatitude) > 1e-10 {
            east /= cosGeocentricLatitude
        } else {
            east = polarEastComponent(
                sinGeocentricLatitude: sinGeocentricLatitude,
                longitude: longitude,
                radiusRatio: radiusRatio,
                yearsFromEpoch: yearsFromEpoch
            )
        }

        // Rotate the geocentric result back into the geodetic frame the
        // coordinate was given in.
        let rotation = geocentricLatitude - geodeticLatitude
        let rotatedNorth = north * cos(rotation) - down * sin(rotation)
        let rotatedDown = north * sin(rotation) + down * cos(rotation)

        let horizontal = (rotatedNorth * rotatedNorth + east * east).squareRoot()
        let total = (horizontal * horizontal + rotatedDown * rotatedDown).squareRoot()

        let field = MagneticField(
            declination: atan2(east, rotatedNorth) * 180 / .pi,
            inclination: atan2(rotatedDown, horizontal) * 180 / .pi,
            horizontalIntensity: horizontal,
            totalIntensity: total,
            northComponent: rotatedNorth,
            eastComponent: east,
            downComponent: rotatedDown
        )
        return Result(field: field, validity: validity)
    }

    /// East component at a geographic pole, where the general series divides
    /// by a vanishing cosine. Only the order-1 terms survive.
    private func polarEastComponent(
        sinGeocentricLatitude: Double,
        longitude: Double,
        radiusRatio: Double,
        yearsFromEpoch: Double
    ) -> Double {
        var polarLegendre = [Double](repeating: 0, count: maxDegree + 1)
        polarLegendre[0] = 1
        var previousNorm = 1.0
        var east = 0.0

        for n in 1...maxDegree {
            let norm = previousNorm * Double(2 * n - 1) / Double(n)
            let schmidtNorm = norm * (Double(2 * n) / Double(n + 1)).squareRoot()
            previousNorm = norm

            if n == 1 {
                polarLegendre[n] = polarLegendre[n - 1]
            } else {
                let k = Double((n - 1) * (n - 1) - 1) / Double((2 * n - 1) * (2 * n - 3))
                polarLegendre[n] = sinGeocentricLatitude * polarLegendre[n - 1] - k * polarLegendre[n - 2]
            }

            guard let coefficient = table[Self.index(n, 1)] else { continue }
            let g = coefficient.g + yearsFromEpoch * coefficient.gDot
            let h = coefficient.h + yearsFromEpoch * coefficient.hDot
            east += pow(radiusRatio, Double(n + 2))
                * (g * sin(longitude) - h * cos(longitude))
                * polarLegendre[n]
                * schmidtNorm
        }
        return east
    }

    // MARK: - Associated Legendre functions

    /// Flat index for degree `n`, order `m`. The table is triangular: order
    /// never exceeds degree.
    static func index(_ n: Int, _ m: Int) -> Int {
        n * (n + 1) / 2 + m
    }

    /// Schmidt semi-normalized associated Legendre functions and their
    /// derivatives with respect to colatitude, evaluated by the standard
    /// recursion in the WMM technical report.
    ///
    /// Returned as `(P, dP)`, both indexed by `index(n, m)`.
    static func schmidtLegendre(
        sinLatitude: Double,
        cosLatitude: Double,
        maxDegree: Int
    ) -> ([Double], [Double]) {
        let count = index(maxDegree, maxDegree) + 1
        var p = [Double](repeating: 0, count: count)
        var dp = [Double](repeating: 0, count: count)

        p[0] = 1
        dp[0] = 0

        for n in 1...maxDegree {
            for m in 0...n {
                let i = index(n, m)
                if n == m {
                    let previous = index(n - 1, m - 1)
                    p[i] = cosLatitude * p[previous]
                    dp[i] = cosLatitude * dp[previous] + sinLatitude * p[previous]
                } else if n == 1, m == 0 {
                    p[i] = sinLatitude * p[0]
                    dp[i] = sinLatitude * dp[0] - cosLatitude * p[0]
                } else if m > n - 2 {
                    let previous = index(n - 1, m)
                    p[i] = sinLatitude * p[previous]
                    dp[i] = sinLatitude * dp[previous] - cosLatitude * p[previous]
                } else {
                    let twoBack = index(n - 2, m)
                    let previous = index(n - 1, m)
                    let k = Double((n - 1) * (n - 1) - m * m)
                        / Double((2 * n - 1) * (2 * n - 3))
                    p[i] = sinLatitude * p[previous] - k * p[twoBack]
                    dp[i] = sinLatitude * dp[previous] - cosLatitude * p[previous] - k * dp[twoBack]
                }
            }
        }

        // Convert from the recursion's normalization to Schmidt
        // semi-normalized, which is what the Gauss coefficients assume.
        var norm = [Double](repeating: 0, count: count)
        norm[0] = 1
        for n in 1...maxDegree {
            norm[index(n, 0)] = norm[index(n - 1, 0)] * Double(2 * n - 1) / Double(n)
            for m in 1...n {
                let doubled = m == 1 ? 2.0 : 1.0
                norm[index(n, m)] = norm[index(n, m - 1)]
                    * (Double(n - m + 1) * doubled / Double(n + m)).squareRoot()
            }
        }

        for i in 0..<count {
            p[i] *= norm[i]
            // The recursion differentiates with respect to latitude; the
            // summation wants colatitude, hence the sign flip.
            dp[i] *= -norm[i]
        }

        return (p, dp)
    }

    // MARK: - Dates

    /// Calendar date → decimal year, the form the model is parameterised in.
    /// Always UTC: the model has no notion of local time, and letting the
    /// device's time zone shift the epoch would make results device-dependent.
    public static func decimalYear(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let components = calendar.dateComponents([.year], from: date)
        guard
            let year = components.year,
            let startOfYear = calendar.date(from: DateComponents(year: year)),
            let startOfNextYear = calendar.date(from: DateComponents(year: year + 1))
        else {
            return 0
        }

        let yearLength = startOfNextYear.timeIntervalSince(startOfYear)
        guard yearLength > 0 else { return Double(year) }
        return Double(year) + date.timeIntervalSince(startOfYear) / yearLength
    }
}
