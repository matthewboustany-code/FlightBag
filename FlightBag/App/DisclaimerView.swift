import SwiftUI

/// First-run acknowledgment. Shown once, blocking, before any aviation data
/// is displayed.
struct DisclaimerView: View {
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
                .padding(.top, 40)

            Text("Advisory Use Only")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text("FlightBag is a situational-awareness aid. It is **not certified** for primary navigation and must not be used as a sole source of flight information.")
                } icon: {
                    Image(systemName: "location.slash")
                }
                Label {
                    Text("Charts, weather, NOTAMs, and airport data may be incomplete, delayed, or expired. Always verify against official sources before and during flight.")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                Label {
                    Text("The pilot in command is solely responsible for preflight action and the safe operation of the aircraft under 14 CFR 91.103 and 91.3.")
                } icon: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
            }
            .frame(maxWidth: 480)

            Spacer()

            Button {
                onAcknowledge()
            } label: {
                Text("I Understand and Agree")
                    .frame(maxWidth: 480)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    DisclaimerView(onAcknowledge: {})
}
