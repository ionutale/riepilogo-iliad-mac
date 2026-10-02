import Charts
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.hasNoAccounts {
                Text("Nessun account configurato. Apri le impostazioni per aggiungere le SIM.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cards, id: \.account) { entry in
                SimCardView(entry: entry,
                             sparkline: model.sparklines[entry.account] ?? [],
                             badge: model.badge(for: entry),
                             threshold: model.settings.lowThresholdPercent)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onChange(of: model.settings.refreshInterval) { model.rescheduleTimer() }
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
        HStack(spacing: 8) {
            Button("Aggiorna ora") { model.refreshNow() }
                .disabled(model.isRefreshing)
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            // Spec §8 footer: "last update". `lastCycle` is the end of the last
            // cycle, which is the only date the coordinator records — a cycle
            // that never ran leaves it nil and shows the placeholder.
            if let lastCycle = model.snapshot.lastCycle {
                Text("Aggiornato \(formatDateTime(lastCycle))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Mai aggiornato")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Storico") { openWindow(id: "history") }
            SettingsLink { Image(systemName: "gearshape") }
        }
    }
}

struct SimCardView: View {
    let entry: Entry
    let sparkline: [HistoryPoint]
    let badge: EntryBadge?
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.account).font(.subheadline.bold())
                Spacer()
                badgeView
            }
            if let good = entry.lastGood, let remaining = good.remainingGB, let allowance = good.allowanceGB {
                let used = good.usedGB ?? max(0, allowance - remaining)
                let usedPct = allowance > 0 ? used / allowance * 100 : 0
                Text("Restano \(formatGB(remaining)) su \(formatGB(allowance))")
                    // The low-data signal is about *remaining*, so it tints the
                    // remaining figure rather than the used-fill bar: the two
                    // thresholds are independent (spec §8 asks for both).
                    .foregroundStyle(isLowData(remaining: remaining, allowance: allowance,
                                               threshold: threshold) ? Color.orange : Color.primary)
                ProgressView(value: min(usedPct, 100), total: 100)
                    .tint(color(for: barClass(usedPct: usedPct)))
                Text("\(formatGB(used)) usati (\(formatPct(usedPct)))")
                    .font(.caption).foregroundStyle(.secondary)
                if sparkline.count >= 2 {
                    SparklineChart(points: sparkline)
                }
                if let renewal = good.renewalDate?.date {
                    Text("Rinnovo: \(formatDate(renewal)) — \(formatDays(daysBetween(today(in: romeTimeZone), renewal)))")
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

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .error:
            CardBadge(text: "errore", color: .red)
        case .stale:
            CardBadge(text: "dati non aggiornati", color: .orange)
        case nil:
            EmptyView()
        }
    }

    private func color(for barClass: String) -> Color {
        switch barClass {
        case "warn": .yellow
        case "danger": .red
        default: .green
        }
    }
}

/// Compact pill for the per-card error/stale badge.
private struct CardBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Seven-day trend of remaining data (spec §8). Renders nothing below two
/// points: a single value is a number, not a trend, and a flat line would read
/// as "no change" rather than "no data".
struct SparklineChart: View {
    let points: [HistoryPoint]

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Data", point.date), y: .value("Restanti", point.remainingGB))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .frame(height: 28)
        .accessibilityLabel("Andamento degli ultimi \(points.count) giorni")
    }

    /// A little headroom above and below so the line never touches the frame,
    /// and a non-degenerate range when every reading is the same value (which
    /// `automatic` would render as a meaningless zero-height domain).
    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.remainingGB)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.2, 0.5)
        return (low - pad)...(high + pad)
    }
}
