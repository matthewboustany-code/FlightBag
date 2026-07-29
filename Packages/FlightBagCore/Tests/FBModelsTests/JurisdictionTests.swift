import Foundation
import Testing
@testable import FBModels

@Suite struct JurisdictionTests {
    @Test func resolvesUnitedStatesFromIdentifier() {
        let us = Jurisdiction.forIdentifier(ICAOIdentifier("KAUS"))
        #expect(us.countryCode == "US")
        #expect(us.ruleSet == .faa)
        #expect(us.units == .faa)
    }

    @Test func resolvesEuropeanStates() {
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("EGLL")).countryCode == "GB")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("EDDF")).countryCode == "DE")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("LFPG")).countryCode == "FR")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("LIRF")).countryCode == "IT")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("EDDF")).ruleSet == .easa)
    }

    @Test func ukPrefixIsUkraineNotTheUnitedKingdom() {
        // UK** is Ukraine; the United Kingdom is EG**. This looks like a bug
        // every time someone reads the table, so pin it.
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("UKBB")).countryCode == "UA")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("EGLL")).countryCode == "GB")
    }

    @Test func singleLetterFallbackCatchesTheRest() {
        // Canada, Australia own a whole first letter.
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("CYYZ")).countryCode == "CA")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("YSSY")).countryCode == "AU")
        // Z** is China except the two-letter exceptions below it.
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("ZBAA")).countryCode == "CN")
        // U** is Russia except the post-Soviet two-letter blocks.
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("UUEE")).countryCode == "RU")
    }

    @Test func twoLetterExceptionsBeatSingleLetterFallback() {
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("ZKPY")).countryCode == "KP")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("ZMUB")).countryCode == "MN")
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("UAAA")).countryCode == "KZ")
    }

    @Test func usOutlyingAreasResolveToTheUnitedStates() {
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("PHNL")).ruleSet == .faa)
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("PANC")).ruleSet == .faa)
    }

    @Test func metricLevelStatesGetMetricUnits() {
        let china = Jurisdiction.forIdentifier(ICAOIdentifier("ZBAA"))
        #expect(china.ruleSet == .icaoMetric)
        #expect(china.units.altitude == .metres)
    }

    @Test func canadaKeepsInchesButIsNotFAA() {
        let canada = Jurisdiction.forIdentifier(ICAOIdentifier("CYYZ"))
        #expect(canada.ruleSet == .tcca)
        #expect(canada.units.altimeter == .inchesOfMercury)
        #expect(canada.ruleSet.usesFlightCategories == false)
    }

    @Test func unrecognisedAndMalformedIdentifiersFallBack() {
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("XXXX")) == .unknown)
        // Local US idents like "3R9" are not ICAO indicators.
        #expect(Jurisdiction.forIdentifier(ICAOIdentifier("3R9")) == .unknown)
        #expect(Jurisdiction.unknown.ruleSet == .icao)
    }

    // MARK: Rules

    @Test func onlyFixedTransitionAltitudeStatesReportOne() {
        #expect(RuleSet.faa.fixedTransitionAltitudeFeet == 18_000)
        #expect(RuleSet.tcca.fixedTransitionAltitudeFeet == 18_000)
        // Europe varies by aerodrome — nil is the correct answer, not a guess.
        #expect(RuleSet.easa.fixedTransitionAltitudeFeet == nil)
        #expect(RuleSet.icao.fixedTransitionAltitudeFeet == nil)
    }

    @Test func flightCategoriesAreFAAOnly() {
        #expect(RuleSet.faa.usesFlightCategories)
        for rules in RuleSet.allCases where rules != .faa {
            #expect(rules.usesFlightCategories == false)
        }
    }

    // MARK: Airport resolution

    @Test func countryCodeWinsOverIdentifier() {
        // The database row is authoritative; the prefix table is the fallback.
        let resolved = Jurisdiction.forAirport(country: "DE", identifier: ICAOIdentifier("KAUS"))
        #expect(resolved.countryCode == "DE")
    }

    @Test func fallsBackToIdentifierWhenCountryIsMissingOrEmpty() {
        #expect(Jurisdiction.forAirport(country: nil, identifier: ICAOIdentifier("EGLL")).countryCode == "GB")
        #expect(Jurisdiction.forAirport(country: "", identifier: ICAOIdentifier("EGLL")).countryCode == "GB")
        #expect(Jurisdiction.forAirport(country: nil, identifier: nil) == .unknown)
    }
}
