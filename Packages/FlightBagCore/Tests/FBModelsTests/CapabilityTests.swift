import Foundation
import Testing
@testable import FBModels

@Suite struct CapabilityTests {
    @Test func faaAirspaceSupportsEverything() {
        let us = Jurisdiction.forIdentifier(ICAOIdentifier("KAUS"))
        for capability in Capability.allCases {
            #expect(us.supports(capability))
        }
    }

    /// A whitelist, not a blacklist: anything added later is unavailable
    /// abroad until someone deliberately says otherwise.
    @Test func nonFAAJurisdictionsSupportNothingByDefault() {
        for identifier in ["EGLL", "EDDF", "CYYZ", "ZBAA", "YSSY"] {
            let jurisdiction = Jurisdiction.forIdentifier(ICAOIdentifier(identifier))
            for capability in Capability.allCases {
                #expect(jurisdiction.supports(capability) == false, "\(identifier) should not support \(capability)")
            }
        }
    }

    @Test func flightCategoryGateHasASingleSourceOfTruth() {
        // RuleSet.usesFlightCategories delegates to the capability set; the
        // two must not be able to disagree.
        for rules in RuleSet.allCases {
            #expect(rules.usesFlightCategories == rules.supports(.flightCategories))
        }
    }

    @Test func everyCapabilityExplainsItself() {
        for capability in Capability.allCases {
            let text = capability.unavailableExplanation
            #expect(!text.isEmpty)
            // An explanation that doesn't end in a sentence is a stub.
            #expect(text.hasSuffix(".") || text.hasSuffix("!"))
        }
    }

    @Test func rawValuesAreStable() {
        #expect(Capability.fisb.rawValue == "fisb")
        #expect(Capability.assistedFiling.rawValue == "assistedFiling")
        #expect(Capability.flightCategories.rawValue == "flightCategories")
    }
}
