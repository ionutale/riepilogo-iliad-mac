import Charts
import SwiftUI

struct HistoryWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String = ""

    private var accounts: [String] { model.cards.map(\.account) }
    @State private var points: [HistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("SIM", selection: $selected) {
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .onAppear { if selected.isEmpty { selected = accounts.first ?? "" } }

            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(x: .value("Data", point.date), y: .value("Restanti", point.remainingGB))
                }
                .chartYAxisLabel("GB rimasti")
                .frame(minHeight: 220)
            } else {
                Text("Storico insufficiente per un grafico (servono almeno 2 giorni di dati).")
                    .foregroundStyle(.secondary)
            }

            Table(points.suffix(14)) {
                TableColumn("Data") { Text(formatDate($0.date)) }
                TableColumn("Restanti") { Text(formatGB($0.remainingGB)) }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: selected) { points = await model.historyPoints(account: selected) }
    }
}