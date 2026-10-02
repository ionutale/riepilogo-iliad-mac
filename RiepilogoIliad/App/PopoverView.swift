import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.cards.isEmpty {
                Text("Nessun account configurato. Apri le impostazioni per aggiungere le SIM.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cards, id: \.account) { entry in
                SimCardView(entry: entry, threshold: model.settings.lowThresholdPercent)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.totals.hasData {
                Text("Ti restano \(formatGB(model.totals.remainingGB)) su \(formatGB(model.totals.allowanceGB)) (\(formatPct(model.totals.pct)))")
                    .font(.headline)
                if let name = model.totals.nextName, let days = model.totals.nextDays {
                    Text("Prossimo rinnovo: \(formatDays(days)) (\(name))")
                        .foregroundStyle(.secondary)
                }
                if model.totals.excluded > 0 {
                    Text("\(model.totals.excluded) SIM senza dati (escluse dal totale)")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Nessun dato ancora — attendo il primo aggiornamento")
                    .font(.headline)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Aggiorna ora") { model.refreshNow() }
                .disabled(model.snapshot.refreshing)
            if model.snapshot.refreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button("Storico") { openWindow(id: "history") }
            SettingsLink { Image(systemName: "gearshape") }
        }
    }
}

struct SimCardView: View {
    let entry: Entry
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.account).font(.subheadline.bold())
                Spacer()
                if entry.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if let good = entry.lastGood, let remaining = good.remainingGB, let allowance = good.allowanceGB {
                let used = good.usedGB ?? max(0, allowance - remaining)
                let usedPct = allowance > 0 ? used / allowance * 100 : 0
                Text("Restano \(formatGB(remaining)) su \(formatGB(allowance))")
                ProgressView(value: min(usedPct, 100), total: 100)
                    .tint(color(for: barClass(usedPct: usedPct)))
                Text("\(formatGB(used)) usati (\(formatPct(usedPct)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let renewal = good.renewalDate?.date {
                    Text("Rinnovo: \(formatDate(renewal)) — \(formatDays(daysBetween(today(in: TimeZone(identifier: "Europe/Rome")!), renewal)))")
                        .font(.caption)
                }
                if let credit = good.creditEUR {
                    Text("Credito: \(formatEUR(credit))").font(.caption)
                }
            } else {
                Text("Errore: \(entry.lastError ?? "nessun dato")")
                    .foregroundStyle(.red).font(.caption)
            }
            if let error = entry.lastError, entry.lastGood != nil {
                Text("Ultimo aggiornamento fallito: \(error)")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for barClass: String) -> Color {
        switch barClass {
        case "warn": .yellow
        case "danger": .red
        default: .green
        }
    }
}
