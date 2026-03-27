// wildcat_NOAA_Weather_widgets.swift
// White Weather — Widget Extension

import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), data: .placeholder)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> WeatherEntry {
        let id = configuration.location?.id ?? "current"
        return WeatherEntry(date: Date(), data: WidgetWeatherData.load(id: id) ?? .placeholder)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<WeatherEntry> {
        let id  = configuration.location?.id ?? "current"
        let now = Date()
        let cached = WidgetWeatherData.load(id: id)

        // Use cache if it's less than 30 minutes old
        if let cached, now.timeIntervalSince(cached.fetchedAt) < 1800 {
            return Timeline(entries: [WeatherEntry(date: now, data: cached)],
                            policy: .after(cached.fetchedAt.addingTimeInterval(1800)))
        }

        // Resolve coordinates — from cache or from the location registry
        var lat = cached?.lat
        var lon = cached?.lon
        if lat == nil || lon == nil {
            let registry = UserDefaults(suiteName: WidgetWeatherData.groupID)?
                .dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
            if let coords = registry[id]?.split(separator: ","), coords.count == 2 {
                lat = Double(coords[0]); lon = Double(coords[1])
            }
        }

        // Fetch fresh data if we have coordinates
        if let lat, let lon {
            do {
                let (cur, days, _, _, _) = try await WeatherRepository.shared.fetchAll(lat: lat, lon: lon)
                guard let firstDay = days.first else { throw URLError(.badServerResponse) }
                let fresh = WidgetWeatherData(
                    id:                 id,
                    lat:                lat,
                    lon:                lon,
                    temperature:        cur.temperature,
                    high:               firstDay.high,
                    low:                firstDay.low,
                    condition:          cur.description,
                    sfSymbol:           firstDay.daySymbol,
                    precipProbability:  firstDay.precipProbability,
                    locationName:       cached?.locationName ?? "—",
                    windGusts:          cur.windGusts,
                    isDay:              cur.isDay,
                    accumDisplayString: firstDay.accumulation.displayString.isEmpty ? nil : firstDay.accumulation.displayString,
                    dayProse:           firstDay.dayProse,
                    nightProse:         firstDay.nightProse,
                    fetchedAt:          now
                )
                fresh.save()
                return Timeline(entries: [WeatherEntry(date: now, data: fresh)],
                                policy: .after(now.addingTimeInterval(1800)))
            } catch {
                // Fetch failed — use stale cache if available, retry in 15 min
            }
        }

        return Timeline(entries: [WeatherEntry(date: now, data: cached ?? .placeholder)],
                        policy: .after(now.addingTimeInterval(900)))
    }
}

struct WeatherEntry: TimelineEntry {
    let date: Date
    let data: WidgetWeatherData
}

// MARK: - Widget Configuration

struct wildcat_NOAA_Weather_widgets: Widget {
    let kind = "wildcat_NOAA_Weather_widgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            WidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(condition: entry.data.condition, isDay: entry.data.isDay)
                }
        }
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

// MARK: - Entry View Router

struct WidgetEntryView: View {
    let entry: WeatherEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: LockScreenWidget(data: entry.data)
            case .systemMedium:      MediumWidget(entry: entry)
            default:                 SmallWidget(entry: entry)
            }
        }
        .widgetURL(URL(string: "wildcat-weather://location/\(entry.data.id)"))
    }
}

// MARK: - Lock Screen Widget (.accessoryCircular)
// Gauge from low → high with current temp. SF symbol in the center.

struct LockScreenWidget: View {
    let data: WidgetWeatherData

    var body: some View {
        Gauge(value: data.temperature, in: data.low...max(data.high, data.low + 1)) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: data.sfSymbol)
        } minimumValueLabel: {
            Text("\(Int(data.low))")
        } maximumValueLabel: {
            Text("\(Int(data.high))")
        }
        .gaugeStyle(.accessoryCircular)
    }
}

// MARK: - Small Widget (.systemSmall)

struct SmallWidget: View {
    let entry: WeatherEntry

    var body: some View {
        WeatherInfoPanel(data: entry.data)
            .foregroundStyle(.white)
    }
}

// MARK: - Medium Widget (.systemMedium)
// Left half: WeatherInfoPanel. Right half: NOAA prose forecast.

struct MediumWidget: View {
    let entry: WeatherEntry

    var body: some View {
        HStack(spacing: 0) {
            WeatherInfoPanel(data: entry.data)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1)
                .padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("FORECAST")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.5))

                Text(entry.data.dayProse.isEmpty ? entry.data.nightProse : entry.data.dayProse)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white)
                    .lineLimit(6)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Shared Info Panel
// Used by both the small and medium widgets.

struct WeatherInfoPanel: View {
    let data: WidgetWeatherData

    private var hasWindAlert: Bool { (data.windGusts ?? 0) >= 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: location indicator + wind alert badge
            HStack {
                if data.id == "current" {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                }
                Spacer()
                if hasWindAlert {
                    Image(systemName: "wind.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.yellow)
                }
            }

            // SF symbol
            Image(systemName: data.sfSymbol)
                .renderingMode(.original)
                .font(.system(size: 36))
                .padding(.top, 2)
                .frame(maxWidth: .infinity)

            // Precip probability — shown when > 0
            if data.precipProbability > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.cyan)
                    Text("\(data.precipProbability)%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .padding(.top, 4)
                .padding(.bottom, -4)
                .frame(maxWidth: .infinity)
            }

            Spacer()

            // Current temperature
            Text("\(Int(data.temperature.rounded()))°")
                .font(.system(size: 38, weight: .medium, design: .rounded))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)

            // Accumulation or H/L
            if let accum = data.accumDisplayString, !accum.isEmpty {
                HStack(spacing: 4) {
                    Text(accum)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.cyan.opacity(0.9))
                    Text("\(Int(data.low.rounded()))° | \(Int(data.high.rounded()))°")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                Text("L:\(Int(data.low.rounded()))°  H:\(Int(data.high.rounded()))°")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Widget Background Gradient

struct WidgetBackground: View {
    let condition: String
    let isDay: Bool

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var colors: [Color] {
        let c = condition.lowercased()
        if c.contains("snow") || c.contains("sleet") || c.contains("flurr") {
            return [Color(white: 0.88), Color(white: 0.65)]
        }
        if c.contains("rain") || c.contains("drizzle") || c.contains("storm") || c.contains("thunder") {
            return [Color(red: 0.12, green: 0.18, blue: 0.28), Color(red: 0.30, green: 0.38, blue: 0.50)]
        }
        if !isDay {
            return [Color(red: 0.02, green: 0.05, blue: 0.15), Color(red: 0.08, green: 0.10, blue: 0.25)]
        }
        if c.contains("clear") || c.contains("sunny") || c.contains("fair") {
            return [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.85, green: 0.75, blue: 0.40)]
        }
        // Cloudy / overcast / default
        return [Color(white: 0.50), Color(white: 0.30)]
    }
}
