// wildcat_NOAA_Weather_widgets.swift
// White Weather — Widget Extension

import WidgetKit
import SwiftUI
import CoreLocation

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
                let (cur, days, _, _, _, _) = try await WeatherRepository.shared.fetchAll(lat: lat, lon: lon)
                guard let firstDay = days.first else { throw URLError(.badServerResponse) }

                // Geocode to get the nearest city name independently of the main app.
                // Re-use the cached name if geocoding fails.
                let defaults = UserDefaults(suiteName: WidgetWeatherData.groupID)
                let savedNames = defaults?.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]

                // Fallback chain for current location:
                //   1. Dedicated "current_location_name" key (written by main app geocoder,
                //      never clobbered by saved-location fetches)
                //   2. Widget's own geocoder (runs independently in the extension)
                //   3. Stale widget cache
                // For saved locations: saved_location_names dict -> geocoder -> stale cache.
                var resolvedName: String = "—"

                if id == "current",
                   let dedicatedName = defaults?.string(forKey: "current_location_name"),
                   !dedicatedName.isEmpty {
                    resolvedName = dedicatedName
                } else if let appName = savedNames[id], !appName.isEmpty {
                    resolvedName = appName
                } else if let geocoded = await geocodeCityName(lat: lat, lon: lon) {
                    resolvedName = geocoded
                } else {
                    resolvedName = cached?.locationName ?? "—"
                }

                // Resolve the widget SF symbol from the NOAA current description
                // (e.g. "Rain" → cloud.rain.fill) rather than the forecast day symbol.
                let currentSymbol = noaaSFSymbol(condition: cur.description, isDay: cur.isDay)
                                 ?? wmoSFSymbol(code: cur.weatherCode, isDay: cur.isDay)

                let fresh = WidgetWeatherData(
                    id:                 id,
                    lat:                lat,
                    lon:                lon,
                    temperature:        cur.temperature,
                    high:               firstDay.high,
                    low:                firstDay.low,
                    condition:          cur.description,
                    sfSymbol:           currentSymbol,
                    precipProbability:  firstDay.precipProbability,
                    locationName:       resolvedName,
                    windGusts:          cur.windGusts,
                    isDay:              cur.isDay,
                    accumDisplayString: firstDay.accumulation.hasAccumulation ? firstDay.accumulation.displayString() : nil,
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

/* Reverse-geocodes a coordinate to the nearest city name using CLGeocoder.
 * Returns nil if geocoding fails, so the caller can fall back gracefully.
 */
private func geocodeCityName(lat: Double, lon: Double) async -> String? {
    let location  = CLLocation(latitude: lat, longitude: lon)
    let geocoder  = CLGeocoder()
    guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
    let city  = placemark.locality ?? ""
    let state = placemark.administrativeArea ?? ""
    return city.isEmpty ? (state.isEmpty ? nil : state) : city
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
        //.contentMarginsDisabled()
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
    private let settings = AppSettings.shared

    var body: some View {
        let temp = settings.temperature(data.temperature)
        let lo   = settings.temperature(data.low)
        let hi   = settings.temperature(data.high)
        Gauge(value: temp, in: lo...max(hi, lo + 1)) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: data.sfSymbol)
        } minimumValueLabel: {
            Text("\(Int(lo))")
        } maximumValueLabel: {
            Text("\(Int(hi))")
        }
        .gaugeStyle(.accessoryCircular)
    }
}

// MARK: - Small Widget (.systemSmall)

struct SmallWidget: View {
    let entry: WeatherEntry

    var body: some View {
        WeatherInfoPanel(data: entry.data)
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
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Shared Info Panel
// Used by both the small and medium widgets.

struct WeatherInfoPanel: View {
    let data: WidgetWeatherData
    private let settings = AppSettings.shared
    private var hasWindAlert: Bool { (data.windGusts ?? 0) >= 40.0 }

    var body: some View {
        // Outer VStack: location header pinned top, H/L pinned bottom,
        // everything in between fills available space evenly.
        VStack(alignment: .leading, spacing: 0) {

            // ── TOP: location name + wind alert ──────────────────────────
            HStack(spacing: 4) {
                if data.id == "current" {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(data.locationName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if hasWindAlert {
                    Image(systemName: "wind.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.yellow)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2)

            // ── MIDDLE: symbol + precip + temperature ────────────────────
            VStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 8)

                VStack(spacing: 0) {
                    Image(systemName: data.sfSymbol)
                        .renderingMode(.original)
                        .font(.system(size: data.precipProbability >= 20 ? 45 : 50))
                        .scaledToFit()
                        .frame(height: data.precipProbability >= 20 ? 45 : 50)
                        .shadow(color: .black.opacity(0.3), radius: 2)

                    if data.precipProbability >= 20 {
                        HStack(spacing: 4) {
                            Image(systemName: "drop.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.cyan)
                            Text("\(data.precipProbability)%")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.cyan)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .top)

                Spacer(minLength: 8)

                Text("\(Int(settings.temperature(data.temperature).rounded()))°")
                    .font(.system(size: 38, weight: .medium, design: .rounded))
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── BOTTOM: H/L or accumulation ──────────────────────────────
            Group {
                if let accum = data.accumDisplayString, !accum.isEmpty {
                    HStack(spacing: 4) {
                        Text(accum)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.cyan.opacity(0.9))
                        Text("\(Int(settings.temperature(data.low).rounded()))° | \(Int(settings.temperature(data.high).rounded()))°")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2)
                } else {
                    Text("L:\(Int(settings.temperature(data.low).rounded()))°  H:\(Int(settings.temperature(data.high).rounded()))°")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142, alignment: .top)
    }
}

// MARK: - Widget Background Gradient

struct WidgetBackground: View {
    let condition: String
    let isDay: Bool

    var body: some View {
        // Default to .clear if the string doesn't match
        let resolvedCondition = WeatherCondition.fromCondition(condition) ?? .clear
        
        let resolvedTime = WeatherTimeOfDay.from(isDay: isDay)
        
        let colors = weatherGradientColors(condition: resolvedCondition, timeOfDay: resolvedTime)
        
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
