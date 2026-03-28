/* WeatherViewModel.swift
 * White Weather
 *
 * Observable state for a single location page. Owns the fetch lifecycle,
 * background video selection, and hourly windowing.
 * One instance per LocationPageView — not shared across pages.
 */

import Foundation
import CoreLocation
import Observation
import MapKit

// MARK: - WeatherBackground

/* Maps weather conditions to background video assets.
 * Resolution order: NOAA condition string → WMO code.
 */
enum WeatherBackground {
    case sun, mostlySunny, clouds, drizzle, rain, snow

    /* @param code  Open-Meteo WMO weather code */
    static func from(code: Int) -> WeatherBackground {
        switch code {
        case 71...77, 85, 86:        return .snow
        case 65...67, 82, 95...99:   return .rain      // heavy rain, freezing, thunder
        case 51...64, 80, 81:        return .drizzle    // light drizzle, light showers
        case 3, 45, 48:              return .clouds     // overcast, fog
        case 1, 2:                   return .mostlySunny
        default:                     return .sun
        }
    }

    /* Derives the background from a NOAA condition string.
     * Returns nil if the condition is empty or unrecognised — caller falls back to WMO.
     *
     * @param condition  tombstone or extracted condition label
     */
    static func fromCondition(_ condition: String) -> WeatherBackground? {
        let c = condition.lowercased()
        guard !c.isEmpty else { return nil }
        let part = c.components(separatedBy: " then ").last ?? c

        if part.contains("blizzard") || part.contains("heavy snow") ||
           part.contains("snow") || part.contains("flurr") || part.contains("sleet") { return .snow }
        if part.contains("thunder") || part.contains("tstm") ||
           part.contains("heavy rain") || part.contains("shower")                    { return .rain }
        if part.contains("rain") || part.contains("drizzle")                         { return .drizzle }
        if part.contains("fog") || part.contains("mist") ||
           part.contains("overcast") || part.contains("cloudy")                      { return .clouds }
        if part.contains("mostly sunny") || part.contains("mostly clear") ||
           part.contains("partly sunny") || part.contains("partly cloudy")           { return .mostlySunny }
        if part.contains("sunny") || part.contains("clear") ||
           part.contains("fair") || part.contains("frost")                           { return .sun }
        return nil
    }

    var videoName: String {
        switch self {
        case .sun:         return "sun"
        case .mostlySunny: return "mostlysunny"
        case .clouds:      return "clouds"
        case .drizzle:     return "drizzle"
        case .rain:        return "rain"
        case .snow:        return "snow"
        }
    }
}

// MARK: - WeatherViewModel

@Observable
@MainActor
final class WeatherViewModel {
    private var lastFetchTime: Date?
    private var lastFetchedCoordinate: CLLocationCoordinate2D?

    var current: CurrentConditions?
    var daily: [DailyForecast] = []
    var hourly: [HourlyForecast] = []
    var sunEvent: SunEvent?

    var locationName: String = ""
    var background: WeatherBackground = .sun
    var isLoading = false
    var isSkiResort = false
    var isCurrentLocation = false  // true for the GPS page; drives the location.fill icon in the header
    var errorMessage: String?

    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double?  { daily.first?.low }

    /* Populates minimal display state from cached widget data without a network fetch.
     * Called immediately on deep link open so the header renders while fresh data loads.
     * The full load() call replaces this a moment later.
     *
     * @param id  location ID ("current" or a SavedLocation UUID string)
     */
    func loadFromCache(id: String) {
        guard let cached = WidgetWeatherData.load(id: id) else { return }
        
        // Don't overwrite ski resrot names
        if id == "current" {
            locationName = cached.locationName
        }
        background   = WeatherBackground.fromCondition(cached.condition)
                    ?? WeatherBackground.from(code: 0)
        current = CurrentConditions(
            temperature:        cached.temperature,
            description:        cached.condition,
            windSpeed:          0,
            windGusts:          cached.windGusts ?? 0,
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

        if !skipGeocode && locationName.isEmpty {
            Task { await geocodeLocationName(for: coordinate) }
        }

        do {
            let (cur, days, allHourly, sun, scraped) = try await WeatherRepository.shared.fetchAll(
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )

            current  = cur
            daily    = days
            sunEvent = sun
            hourly   = hourlyWindow(from: allHourly)

            background = WeatherBackground.fromCondition(scraped[todayKey()]?.dayCondition ?? "")
                      ?? WeatherBackground.from(code: cur.weatherCode)

            calculateGlobalBounds(days: days)
            saveCoordinates(id: locationID ?? "current", coord: coordinate)

            isLoading = false
            lastFetchTime = Date()

        } catch {
            errorMessage = "Failed to load weather: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func setLocationName(_ name: String) { locationName = name }
    func setSkiResort(_ value: Bool)     { isSkiResort = value }

    // MARK: Private

    /* Filters all hourly data to the window from the current clock-hour through current hour + 12. */
    private func hourlyWindow(from all: [HourlyForecast]) -> [HourlyForecast] {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: now)) ?? now
        let end   = start.addingTimeInterval(12 * 3600)
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
            locationName = "Unknown"; return
        }
        let city  = placemark.locality ?? ""
        let state = placemark.administrativeArea ?? ""
        locationName = city.isEmpty ? state : city
    }

    /* Writes this location's coordinate to the shared App Group container
     * so the widget can re-fetch independently without the app being open.
     */
    private func saveCoordinates(id: String, coord: CLLocationCoordinate2D) {
        guard let defaults = UserDefaults(suiteName: WidgetWeatherData.groupID) else { return }
        var coords = defaults.dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
        coords[id] = "\(coord.latitude),\(coord.longitude)"
        defaults.set(coords, forKey: "saved_location_coords")
        
        var names = defaults.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]
        names[id] = locationName
        defaults.set(names, forKey: "saved_location_names")
    }
}
