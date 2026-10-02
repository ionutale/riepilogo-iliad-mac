import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: (model?.hasWarning ?? false)
                  ? "exclamationmark.triangle.fill"
                  : "antenna.radiowaves.left.and.right")
            if let totals = model?.totals, totals.hasData {
                Text(formatGB(totals.remainingGB))
            } else {
                // Spec §8: `—` when there is no data, so the menu bar reads as
                // "nothing to report yet" instead of as a blank/missing item.
                Text("—")
            }
        }
    }
}
