import SwiftUI
import FBModels

/// Explains why a feature isn't available here, instead of showing nothing.
///
/// An empty plates list or a blank advisory layer reads as "there are none",
/// which is the dangerous interpretation when the truth is "FlightBag has no
/// data for this country". Saying so costs one line and removes the ambiguity.
struct CapabilityNotice: View {
    let capability: Capability

    var body: some View {
        Label(capability.unavailableExplanation, systemImage: "globe")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// Shows `content` where the jurisdiction supports the capability, and a
    /// short explanation where it doesn't.
    @ViewBuilder
    func gated(
        _ capability: Capability,
        by jurisdiction: Jurisdiction,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if jurisdiction.supports(capability) {
            content()
        } else {
            CapabilityNotice(capability: capability)
        }
    }
}
