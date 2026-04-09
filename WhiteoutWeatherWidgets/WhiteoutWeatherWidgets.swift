// WhiteoutWeatherWidgets.swift
// Whiteout Weather — Widget Extension

import WidgetKit
import SwiftUI
import CoreLocation
import UIKit

// MARK: - Timeline Provider

// Stale threshold: cache older than 20 minutes triggers a live fetch.
// Keeps the widget from hammering the network on every WidgetKit ping
// while still staying reasonably fresh when iOS wakes it up.
private let cacheStaleInterval: TimeInterval = 20 * 60

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), data: .placeholder)
    }

    // snapshot() runs when the user is browsing the widget gallery or adding
    // the widget. Return cached data instantly if it's fresh; otherwise fetch
    // so the preview reflects real conditions rather than stale data.
    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> WeatherEntry {
        let id = configuration.location?.id ?? "current"
        let cached = WidgetWeatherData.load(id: id)

        // Use cache if it's fresh enough for a preview.
        if let cached,
           Date().timeIntervalSince(cached.fetchedAt) < cacheStaleInterval {
            return WeatherEntry(date: Date(), data: cached)
        }

        // Cache is stale or absent — run a real fetch so the preview is accurate.
        // Fall back to stale cache or placeholder if the fetch fails.
        return await fetchEntry(id: id, cached: cached) ?? WeatherEntry(date: Date(), data: cached ?? .placeholder)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<WeatherEntry> {
        let id  = configuration.location?.id ?? "current"
        let now = Date()
        let cached = WidgetWeatherData.load(id: id)

        // Skip a live fetch if the cache is still fresh AND the location hasn't changed.
        // WidgetKit calls timeline() on its own schedule AND whenever the app
        // calls reloadAllTimelines() (e.g. on foreground). The staleness guard
        // prevents a network hit every single time the user unlocks their phone.
        // Exception: if the App Group has fresher coordinates than the cache
        // (e.g. the device moved to a new city), force a re-fetch immediately.
        let appGroupCoords = UserDefaults(suiteName: WidgetWeatherData.groupID)?
            .dictionary(forKey: "saved_location_coords") as? [String: String]
        let registryCoordString = appGroupCoords?[id]
        let cacheCoordString = cached.map { "\($0.lat),\($0.lon)" }
        let locationUnchanged = registryCoordString == nil || registryCoordString == cacheCoordString

        if let cached,
           locationUnchanged,
           Date().timeIntervalSince(cached.fetchedAt) < cacheStaleInterval {
            // Return the cached entry and ask WidgetKit to check back when it expires.
            let nextRefresh = cached.fetchedAt.addingTimeInterval(cacheStaleInterval)
            return Timeline(
                entries: [WeatherEntry(date: now, data: cached)],
                policy: .after(nextRefresh)
            )
        }

        // Fetch fresh data.
        if let entry = await fetchEntry(id: id, cached: cached) {
            // Refresh again in 30 minutes, and also whenever these entries are consumed.
            let nextRefresh = now.addingTimeInterval(1800)
            return Timeline(entries: [entry], policy: .after(nextRefresh))
        }

        // Fetch failed — show stale cache and retry in 15 minutes.
        return Timeline(
            entries: [WeatherEntry(date: now, data: cached ?? .placeholder)],
            policy: .after(now.addingTimeInterval(900))
        )
    }
}

// MARK: - Shared Fetch Logic

/* Fetches live weather for a location ID and returns a WeatherEntry.
 * Uses WeatherRepository.shared.fetchAll() — the exact same pipeline as the
 * main app — so symbol, condition, temperature, and high/low are always derived
 * by identical logic. Returns nil if coordinates can't be resolved or the fetch
 * throws. Writes the result to the shared App Group cache on success.
 */
private func fetchEntry(id: String, cached: WidgetWeatherData?) async -> WeatherEntry? {
    let now = Date()

    // Resolve coordinates — ALWAYS prefer the App Group registry over cache.
    // The device may have moved since the cache was written ("current" location),
    // so we must read the freshest coordinates the main app has published.
    // Cache lat/lon is used only as a last resort when the App Group has nothing.
    let sharedDefaults = UserDefaults(suiteName: WidgetWeatherData.groupID)
    let registry = sharedDefaults?.dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
    var lat: Double?
    var lon: Double?
    if let coords = registry[id]?.split(separator: ","), coords.count == 2 {
        lat = Double(coords[0]); lon = Double(coords[1])
    }
    if lat == nil || lon == nil {
        lat = cached?.lat
        lon = cached?.lon
    }
    guard let lat, let lon else { return nil }

    do {
        // fetchAll() runs the full NOAA + Open-Meteo pipeline — same as the main app.
        let (cur, days, allHourly, _, _, _, alerts) = try await WeatherRepository.shared.fetchAll(lat: lat, lon: lon)
        guard let firstDay = days.first else { return nil }

        // Location name — prefer the dedicated current_location_name key for "current"
        // (written by the main app's geocoder), then the saved names registry,
        // then a fresh geocode, then stale cache as last resort.
        let savedNames = sharedDefaults?.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]
        var resolvedName: String
        if id == "current",
           let dedicatedName = sharedDefaults?.string(forKey: "current_location_name"),
           !dedicatedName.isEmpty {
            resolvedName = dedicatedName
        } else if let appName = savedNames[id], !appName.isEmpty {
            resolvedName = appName
        } else if let geocoded = await geocodeCityName(lat: lat, lon: lon) {
            resolvedName = geocoded
        } else {
            resolvedName = cached?.locationName ?? "—"
        }

        // SF symbol — mirrors WeatherViewModel.currentSFSymbol exactly:
        //   1. wmoSFSymbol from the current-hour WMO code
        //   2. noaaSFSymbol from cur.description when WMO returns a generic fallback
        let cal = Calendar.current
        let nowHour = allHourly.first(where: {
            cal.isDateInToday($0.time) &&
            cal.component(.hour, from: $0.time) == cal.component(.hour, from: Date())
        })
        let nowCode  = nowHour?.weatherCode ?? cur.weatherCode
        let nowIsDay = nowHour.map {
            let h = cal.component(.hour, from: $0.time)
            return h >= 6 && h < 20
        } ?? cur.isDay
        let wmoSym = wmoSFSymbol(code: nowCode, isDay: nowIsDay)
        let genericWMO: Set<String> = ["cloud.fill", "cloud.sun.fill", "cloud.moon.fill"]
        let currentSymbol: String = {
            if genericWMO.contains(wmoSym),
               let noaaSym = noaaSFSymbol(condition: cur.description, isDay: nowIsDay) {
                return noaaSym
            }
            return wmoSym
        }()

        // Alert icon for the widget header slot.
        let topAlert = alerts.first
        let alertCfg = topAlert.map { NWSAlert.displayConfig(for: $0.event) }
        let alertRGBA = alertCfg.map { UIColor($0.color).rgbaComponents }

        let fresh = WidgetWeatherData(
            id:                 id,
            lat:                lat,
            lon:                lon,
            temperature:        cur.temperature,       // NOAA station temp preferred by buildCurrentConditions
            high:               firstDay.high,         // resolvedHigh from NOAA prose in buildDaily
            low:                firstDay.low,          // resolvedLow  from NOAA prose in buildDaily
            condition:          cur.description,       // NOAA-resolved label (not wmoDescription)
            sfSymbol:           currentSymbol,
            precipProbability:  firstDay.precipProbability,
            locationName:       resolvedName,
            windGusts:          cur.windGusts,
            isDay:              cur.isDay,
            accumDisplayString: firstDay.accumulation.hasAccumulation ? firstDay.accumulation.displayString() : nil,
            dayProse:           firstDay.dayProse,
            nightProse:         firstDay.nightProse,
            fetchedAt:          now,
            alertSymbol:        alertCfg?.symbol,
            alertColorRed:      alertRGBA?.r,
            alertColorGreen:    alertRGBA?.g,
            alertColorBlue:     alertRGBA?.b
        )
        fresh.save()
        return WeatherEntry(date: now, data: fresh)
    } catch {
        return nil
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

struct WhiteoutWeatherWidgets: Widget {
    let kind = "WhiteoutWeatherWidgets"

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
// Gauge from low to high with current temp. SF symbol in the center.

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

    private var alertColor: Color? {
        guard let r = data.alertColorRed,
              let g = data.alertColorGreen,
              let b = data.alertColorBlue else { return nil }
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // TOP: Header (Pinned)
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
                if let symbol = data.alertSymbol, let color = alertColor {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(color)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2)

            // GAP A: Equal to Gap B
            Spacer(minLength: 10)

            // MIDDLE: The Bundle (Centered between Header and Temp)
            VStack(spacing: 2) {
                let hasPrecip = data.precipProbability >= 20
                
                Image(systemName: data.sfSymbol)
                    .renderingMode(.original)
                    // Downsize icon slightly if precip is present (42 -> 34)
                    .font(.system(size: hasPrecip ? 34 : 42))
                    .frame(width: 45, height: hasPrecip ? 34 : 42)
                    .shadow(color: .black.opacity(0.3), radius: 2)

                if hasPrecip {
                    Spacer(minLength: 2)
                    
                    HStack(spacing: 2) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 10))
                        Text("\(data.precipProbability)%")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.cyan)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)

            // GAP B: Equal to Gap A
            Spacer(minLength: 10)

            Text("\(Int(settings.temperature(data.temperature).rounded()))°")
                .font(.system(size: 38, weight: .medium, design: .rounded))
                .shadow(color: .black.opacity(0.25), radius: 2)
                .frame(maxWidth: .infinity)

            // Separates Temp from Footer
            //Spacer(minLength: 0)

            // BOTTOM: H/L or Accumulation (Pinned)
            VStack(alignment: .leading, spacing: 2) {
                if let accum = data.accumDisplayString, !accum.isEmpty {
                    HStack(spacing: 4) {
                        Text(accum)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.cyan.opacity(0.9))
                        Text("\(Int(settings.temperature(data.low).rounded()))° | \(Int(settings.temperature(data.high).rounded()))°")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                } else {
                    Text("L:\(Int(settings.temperature(data.low).rounded()))°  H:\(Int(settings.temperature(data.high).rounded()))°")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2)
        }
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142, alignment: .top)
    }
}

// MARK: - Widget Background Gradient

struct WidgetBackground: View {
    let condition: String
    let isDay: Bool

    var body: some View {
        let resolvedCondition = WeatherCondition.fromCondition(condition) ?? .clear
        let resolvedTime = WeatherTimeOfDay.from(isDay: isDay)
        let colors = weatherGradientColors(condition: resolvedCondition, timeOfDay: resolvedTime)
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - UIColor RGBA Helper

/* Extracts linear sRGB components from any SwiftUI Color via UIColor.
 * Used to store alert colors in WidgetWeatherData (which must be Codable).
 * SwiftUI.Color itself is not Codable, so we persist raw doubles and rebuild.
 */
extension UIColor {
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
