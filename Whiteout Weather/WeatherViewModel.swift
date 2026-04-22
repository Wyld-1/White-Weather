/* WeatherViewModel.swift
 * Whiteout Weather
 *
 * Observable state for a single location page. Owns the fetch lifecycle,
 * background image selection, and hourly windowing.
 * One instance per LocationPageView — not shared across pages.
 */

import Foundation
internal import CoreLocation
import Observation
import MapKit
import SwiftUI

// MARK: - WeatherViewModel

@Observable
@MainActor
final class WeatherViewModel {
    private var lastFetchTime: Date?
    private var lastFetchedCoordinate: CLLocationCoordinate2D?

    var current: CurrentConditions?
    var daily: [DailyForecast] = []
    var hourly: [HourlyForecast] = []
    var hourlyTable: [NOAAHourlyTableEntry] = []  // rich per-hour table data
    var sunEvent: SunEvent?
    var alerts: [NWSAlert] = []

    var locationName: String = ""
    var weatherCondition: WeatherCondition = .clear
    private var utcOffsetSeconds: Int = 0

    // Current time-of-day slot — computed live from sunEvent so it stays accurate
    // as the day progresses without needing a re-fetch.
    var weatherTimeOfDay: WeatherTimeOfDay {
        // If we have a cached isDay value but no sunEvent yet (warm-start),
        // use it so the background doesn't flash to .day incorrectly.
        if sunEvent == nil, let cur = current {
            return WeatherTimeOfDay.from(isDay: cur.isDay)
        }
        return WeatherTimeOfDay.from(sun: sunEvent, utcOffsetSeconds: utcOffsetSeconds)
    }

    // Whether the current background is perceptually light-colored.
    // Used by PageDotsView to switch dot/icon color for legibility.
    var isLightBackground: Bool {
        switch weatherCondition {
        case .snow:    return true
        case .clear, .mostlyClear:
            // Day clear is bright blue — dark dots needed.
            // Night/sunrise clear is dark — white dots fine.
            return weatherTimeOfDay == .day
        default:       return false
        }
    }

    var isLoading = false
    var isSkiResort = false
    var isCurrentLocation = false  // true for the GPS page; drives the location.fill icon in the header
    var errorMessage: String?

    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double?  { daily.first?.low }

    /* SF symbol for the current-conditions header.
     * Always sourced from the "Now" hourly slot so the header matches
     * the hourly card exactly. Priority chain:
     *  1. resolvedSymbol on the Now hourly slot (Phase 2 table — most accurate)
     *  2. noaaSFSymbol from the Now slot's shortForecast (Phase 1 tombstone-derived)
     *  3. noaaSFSymbol from cur.description (NOAA station observation)
     *  4. wmoSFSymbol from the OM current weatherCode as last resort
     *
     * NOTE: the daily.daySymbol / nightSymbol shortcut was intentionally removed.
     * Those symbols are resolved at fetch time with isDay:true/false baked in,
     * causing a flash when Phase 2 arrives and can show the wrong icon at night.
     * Deriving from the Now slot here keeps header, hourly card, and background
     * in sync through both load phases.
     */
    var currentSFSymbol: String {
        guard let cur = current else { return "cloud.fill" }
        let cal = Calendar.current

        // Accurate day/night: sunEvent if available, OM flag as fallback.
        let isCurrentlyDay: Bool
        if let sun = sunEvent {
            let now = Date()
            isCurrentlyDay = now >= sun.sunrise && now < sun.sunset
        } else {
            isCurrentlyDay = cur.isDay
        }

        // Now slot — prefer Phase 2 resolvedSymbol, then Phase 1 shortForecast.
        if let nowHour = hourly.first(where: {
            cal.isDateInToday($0.time) &&
            cal.component(.hour, from: $0.time) == cal.component(.hour, from: Date())
        }) {
            if let sym = nowHour.resolvedSymbol { return sym }
            if let sym = noaaSFSymbol(condition: nowHour.shortForecast, isDay: isCurrentlyDay) { return sym }
        }

        // Station observation fallback
        if let sym = noaaSFSymbol(condition: cur.description, isDay: isCurrentlyDay) { return sym }
        return wmoSFSymbol(code: cur.weatherCode, isDay: isCurrentlyDay)
    }

    /* Populates minimal display state from cached widget data without a network fetch.
     * Called immediately on deep link open so the header renders while fresh data loads.
     * The full load() call replaces this a moment later.
     *
     * @param id  location ID ("current" or a SavedLocation UUID string)
     */
    func loadFromCache(id: String) {
        guard let cached = WidgetWeatherData.load(id: id) else { return }

        if locationName.isEmpty {
            locationName = cached.locationName
        }

        // Only update the condition if the cache has a real condition string.
        if let cond = WeatherCondition.fromCondition(cached.condition) {
            weatherCondition = cond
        }
        current = CurrentConditions(
            temperature:        cached.temperature,
            description:        cached.condition,
            windSpeed:          0,
            windGusts:          cached.windGusts ?? 0,
            windSpeedInstant:   0,
            windDirection:      0,
            windDirectionLabel: "",
            humidity:           0,
            weatherCode:        0,
            isDay:              cached.isDay
        )
    }

    /* Fetches weather data for a coordinate and updates all published state.
     * Skips the fetch if the same coordinate was loaded less than 15 minutes ago,
     * unless forceRefresh is true.
     *
     * @param coordinate   location to fetch
     * @param locationID   "current" or a SavedLocation UUID string (used for widget data keying)
     * @param skipGeocode  true for saved locations whose name is already known
     * @param forceRefresh bypasses the 15-minute staleness check
     */
    func load(
        coordinate: CLLocationCoordinate2D,
        locationID: String? = nil,
        skipGeocode: Bool = false,
        forceRefresh: Bool = false
    ) async {
        if !forceRefresh,
           let last = lastFetchedCoordinate,
           abs(last.latitude  - coordinate.latitude)  < 0.01,
           abs(last.longitude - coordinate.longitude) < 0.01,
           let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < 900 { return }

        lastFetchedCoordinate = coordinate
        isLoading = true
        errorMessage = nil

        if !skipGeocode {
            Task { await geocodeLocationName(for: coordinate) }
        }

        // ── Phase 1: fast fetches (OM + prose + alerts) ─────────────────────
        // Renders the full page immediately with WMO-backed hourly and tombstone symbol.
        do {
            let (cur, days, allHourly, sun, scraped, utcOffset, fetchedAlerts, _) =
                try await WeatherRepository.shared.fetchAll(
                    lat: coordinate.latitude,
                    lon: coordinate.longitude
                )

            current      = cur
            daily        = days
            sunEvent     = sun
            hourly       = hourlyWindow(from: allHourly)
            // Removes duplicate alerts
            var seen = Set<String>()
            alerts = fetchedAlerts.filter { seen.insert($0.event.lowercased()).inserted }
            utcOffsetSeconds = utcOffset

            // Phase 1 background condition.
            // Prefer the Now hourly slot's shortForecast so the background and the
            // header symbol (also Now-slot-derived) always agree on the same source.
            // Falls back to the tombstone condition, then WMO.
            let nowHourPhase1 = hourlyWindow(from: allHourly).first(where: {
                let cal = Calendar.current
                return cal.isDateInToday($0.time) &&
                    cal.component(.hour, from: $0.time) == cal.component(.hour, from: Date())
            })
            let todayData = scraped[todayKey()]
            if let nowHour = nowHourPhase1,
               let cond = WeatherCondition.fromCondition(nowHour.shortForecast) {
                weatherCondition = cond
            } else {
                let isCurrentlyDayPhase1 = cur.isDay
                let noaaCond: WeatherCondition?
                if isCurrentlyDayPhase1 {
                    noaaCond = WeatherCondition.fromCondition(todayData?.dayCondition ?? "")
                } else {
                    noaaCond = WeatherCondition.fromCondition(todayData?.nightCondition ?? "")
                           ?? WeatherCondition.fromCondition(todayData?.dayCondition ?? "")
                }
                weatherCondition = noaaCond ?? WeatherCondition.fromWMO(code: cur.weatherCode)
            }

            calculateGlobalBounds(days: days)
            saveCoordinates(id: locationID ?? "current", coord: coordinate)
            isLoading = false
            lastFetchTime = Date()

            // ── Phase 2: digital table (slow, ~3-8s) ───────────────────────
            // Patches hourly symbols and table data in place once the table arrives.
            // If it fails, phase 1 data stays — no regression.
            let tz = TimeZone(secondsFromGMT: utcOffset) ?? .current
            if let table = await WeatherRepository.shared.fetchTable(
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                tz: tz
            ), !table.isEmpty {
                hourlyTable = table
                let tableHourly = buildHourlyFromTable(
                    table,
                    sunrise: sunEvent?.sunrise,
                    sunset:  sunEvent?.sunset
                )
                hourly = hourlyWindow(from: tableHourly)

                // Rebuild daily.hourlyTemps with table data for temp graphs
                let cal = Calendar.current
                daily = daily.map { day in
                    let temps = tableHourly.filter { cal.isDate($0.time, inSameDayAs: day.date) }
                    guard !temps.isEmpty else { return day }
                    return DailyForecast(
                        id: day.id, date: day.date, high: day.high, low: day.low,
                        precipProbability: day.precipProbability,
                        shortForecast: day.shortForecast,
                        dayProse: day.dayProse, nightProse: day.nightProse,
                        accumulation: day.accumulation, precipType: day.precipType,
                        isNightSevere: day.isNightSevere,
                        daySymbol: day.daySymbol, nightSymbol: day.nightSymbol,
                        rowNightSymbol: nil,
                        hourlyTemps: temps,
                        timeZoneIdentifier: tz.identifier,
                        forecastBadge: day.forecastBadge
                    )
                }

                // Update background condition from table's current hour
                let nowCal = Calendar.current
                if let nowEntry = table.first(where: {
                    nowCal.isDateInToday($0.date) &&
                    nowCal.component(.hour, from: $0.date) == nowCal.component(.hour, from: Date())
                }) {
                    if let cond = WeatherCondition.fromCondition(nowEntry.shortForecast) {
                        weatherCondition = cond
                    }
                }
            }

        } catch {
            errorMessage = "Failed to load weather: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func setLocationName(_ name: String) { locationName = name }
    func setSkiResort(_ value: Bool)     { isSkiResort = value }

    // MARK: Private

    /* Filters all hourly data to the window from the current clock-hour through current hour + 24. */
    private func hourlyWindow(from all: [HourlyForecast]) -> [HourlyForecast] {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: now)) ?? now
        let end   = start.addingTimeInterval(24 * 3600)
        return all.filter { $0.time >= start && $0.time <= end }
    }

    private func todayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func calculateGlobalBounds(days: [DailyForecast]) {
        guard let minLow  = days.map({ $0.low  }).min(),
              let maxHigh = days.map({ $0.high }).max() else { return }
        globalLow  = (minLow  - 2).rounded(.down)
        globalHigh = (maxHigh + 2).rounded(.up)
    }

    /* Uses CLGeocoder to reverse-geocode to the nearest city/town name.
     * Always shows a city name for the current location page — never a POI or "My Location".
     *
     * @param coord  coordinate to reverse-geocode
     */
    private func geocodeLocationName(for coord: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            if locationName.isEmpty { locationName = "Unknown" }
            return
        }
        let city  = placemark.locality ?? ""
        let state = placemark.administrativeArea ?? ""
        // Use "City, ST" format to match the format LocationSearchView uses when
        // saving locations — keeps the display consistent across current and saved pages.
        if city.isEmpty {
            locationName = state
        } else if state.isEmpty {
            locationName = city
        } else {
            locationName = "\(city), \(state)"
        }
        // Propagate the freshly-geocoded name to the widget's App Group so it
        // always reflects the real current location, not a stale cached city.
        saveCoordinates(id: "current", coord: coord)
    }

    /* Writes this location's coordinate to the shared App Group container
     * so the widget can re-fetch independently without the app being open.
     *
     * For the current GPS location (id == "current") the name is written to a
     * dedicated key rather than the shared saved_location_names dictionary.
     * This eliminates the read-modify-write race where concurrent saved-location
     * fetches clobber the "current" entry in the shared dict.
     */
    private func saveCoordinates(id: String, coord: CLLocationCoordinate2D) {
        guard let defaults = UserDefaults(suiteName: WidgetWeatherData.groupID) else { return }
        var coords = defaults.dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
        coords[id] = "\(coord.latitude),\(coord.longitude)"
        defaults.set(coords, forKey: "saved_location_coords")

        if id == "current" {
            // Dedicated key — never touched by LocationStore or saved-location fetches.
            defaults.set(locationName, forKey: "current_location_name")
        } else {
            // Saved locations: write into the shared dict as before.
            // LocationStore.syncLocationRegistry() also manages this dict.
            var names = defaults.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]
            names[id] = locationName
            defaults.set(names, forKey: "saved_location_names")
        }
    }
}
