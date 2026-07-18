import Testing
@testable import App

/// Fixture lines are verbatim from the real 2607 FAACIFP18 — the guard
/// against fixed-width column drift.
@Suite struct ARINC424Tests {
    @Test func parsesSIDCommonRouteLeg() throws {
        let line = "SUSAP KAUSK4DAEROZ25ALL   010AMUSEK4EA0E       IF                                 + 05000     18000                        270002104"
        guard case .leg(let leg)? = ARINC424.parse(line) else {
            Issue.record("expected leg")
            return
        }
        #expect(leg.airportId == "KAUS")
        #expect(leg.isSID)
        #expect(leg.procedureIdent == "AEROZ2")
        #expect(leg.transitionKind == .common)   // route type 5 = RNAV common
        #expect(leg.transitionIdent == nil)      // "ALL" normalizes to nil
        #expect(leg.sequence == 10)
        #expect(leg.fixIdent == "AMUSE")
        #expect(leg.fixSection == "EA")
        #expect(leg.pathTerminator == "IF")
        #expect(leg.altitudeDescription == "+")
        #expect(leg.altitude1Feet == 5000)
    }

    @Test func parsesSIDEnrouteTransitionWithVORFix() throws {
        let line = "SUSAP KAUSK4DAEROZ26SJT   020SJT  K4D 0VE      TF                                                                          270032104"
        guard case .leg(let leg)? = ARINC424.parse(line) else {
            Issue.record("expected leg")
            return
        }
        #expect(leg.transitionKind == .enroute)  // route type 6 = RNAV enroute
        #expect(leg.transitionIdent == "SJT")
        #expect(leg.fixIdent == "SJT")
        #expect(leg.fixSection == "D")           // VHF navaid
        #expect(leg.pathTerminator == "TF")
    }

    @Test func parsesSTAREnrouteTransition() throws {
        let line = "SUSAP KAUSK4EBLEWE51ACT   010ACT  K4D 0V       IF                                             18000                        270672302"
        guard case .leg(let leg)? = ARINC424.parse(line) else {
            Issue.record("expected leg")
            return
        }
        #expect(!leg.isSID)
        #expect(leg.procedureIdent == "BLEWE5")
        #expect(leg.transitionKind == .enroute)  // STAR route type 1
        #expect(leg.transitionIdent == "ACT")
        #expect(leg.altitude1Feet == nil)        // 18000 there is transition altitude, not alt1
    }

    @Test func parsesTerminalWaypoint() throws {
        let line = "SUSAP KAUSK4CALLOU K40    W     N30174456W097354238                       E0030     NAR           ALLOU                    268832605"
        guard case .fix(let fix)? = ARINC424.parse(line) else {
            Issue.record("expected fix")
            return
        }
        #expect(fix.key == ARINC424.FixKey(section: "PC", airportId: "KAUS", ident: "ALLOU"))
        // N30°17'44.56"
        #expect(abs(fix.latitude - (30 + 17.0 / 60 + 44.56 / 3600)) < 1e-9)
        #expect(abs(fix.longitude - -(97 + 35.0 / 60 + 42.38 / 3600)) < 1e-9)
    }

    @Test func parsesVORAndRunwayAndEnrouteWaypoint() throws {
        let vor = "SUSAD        CWK   K4011280VTHW N30224278W097314745    N30224278W097314745E0060005932     NARCENTEX                        251481605"
        guard case .fix(let cwk)? = ARINC424.parse(vor) else {
            Issue.record("expected VOR fix")
            return
        }
        #expect(cwk.key == ARINC424.FixKey(section: "D", airportId: nil, ident: "CWK"))
        #expect(abs(cwk.latitude - (30 + 22.0 / 60 + 42.78 / 3600)) < 1e-9)

        let runway = "SUSAP KAUSK4GRW18L   0090001750 N30121379W097392841         +0123800492000061150IIVNK3                                     274892104"
        guard case .fix(let threshold)? = ARINC424.parse(runway) else {
            Issue.record("expected runway fix")
            return
        }
        #expect(threshold.key == ARINC424.FixKey(section: "PG", airportId: "KAUS", ident: "RW18L"))
        #expect(abs(threshold.latitude - (30 + 12.0 / 60 + 13.79 / 3600)) < 1e-9)

        let enroute = "SUSAEAENRT   AMUSE K40    C   L N30272321W098173908                       E0034     NAR           AMUSE                    277932605"
        guard case .fix(let amuse)? = ARINC424.parse(enroute) else {
            Issue.record("expected enroute fix")
            return
        }
        #expect(amuse.key == ARINC424.FixKey(section: "EA", airportId: nil, ident: "AMUSE"))
    }

    @Test func skipsIrrelevantRecords() {
        // Airway record (ER) and header lines must parse to nil.
        #expect(ARINC424.parse("SUSAER       T545        0280AMUSEK4EA0E    RL                        006601010069 03000     17500                         632312605") == nil)
        #expect(ARINC424.parse("HDR01FAACIFP18      001") == nil)
    }
}
