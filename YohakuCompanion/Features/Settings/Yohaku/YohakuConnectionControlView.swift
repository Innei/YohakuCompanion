import SwiftUI

struct YohakuConnectionControlView: View {
    let isBusy: Bool
    let onRemove: () -> Void

    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove connection")
                        .font(.subheadline.weight(.medium))
                    Text("Stops Live Desk and removes this Mac’s protected Yohaku credential.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("Remove…", role: .destructive) {
                    isShowingRemovalConfirmation = true
                }
                .disabled(isBusy)
            }
        }
        .confirmationDialog(
            "Remove This Mac from Yohaku?",
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Connection", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops Live Desk and removes the protected credential from this Mac. Pairing is required before this Mac can publish again.")
        }
    }
}
