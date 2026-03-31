/* WeatherViewModel.swift
 * White Weather
 *
 * Observable state for a single location page. Owns the fetch lifecycle,
 * background image selection, and hourly windowing.
 * One instance per LocationPageView — not shared across pages.
 */

import Foundation
import CoreLocation
import Observation
import MapKit

// MARK: - WeatherSeason

/* Calendar season derived from the location's local date.
 * Uses meteorological seasons (month-based) for simplicity and reliability.
 */
enum WeatherSeason: String {
    case spring, summer, fall, winter

    /* Derives the season from a UTC date adjusted to the given timezone offset.
     *
     * @param date             UTC date to evaluate (typically now)
     * @param utcOffsetSeconds the location's UTC offset from Open-Meteo
     */
    static func from(date: Date = Date(), utcOffsetSeconds: Int) -> WeatherSeason {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .current
        let month = cal.component(.month, from: date)
        switch month {
        case 3...5:  return .spring
        case 6...8:  return .summer
        case 9...11: return .fall
        default:     return .winter   // 12, 1, 2
        }
    }
}

// MARK: - WeatherCondition

/* Broad sky/precipitation condition used to select the background image.
 * Resolution order: NOAA condition string → WMO weather code.
 */
enum WeatherCondition {
    case clear, mostlyClear, overcast, rain, snow

    /* Derives the condition from a NOAA tombstone or prose condition string.
     * Returns nil when the string is empty or unrecognised — caller falls back to WMO.
     */
    static func fromCondition(_ condition: String) -> WeatherCondition? {
        let c = condition.lowercased()
        guard !c.isEmpty else { return nil }
        let part = c.components(separatedBy: " then ").last ?? c

        if part.contains("blizzard") || part.contains("heavy snow") ||
           part.contains("snow")     || part.contains("flurr")      ||
           part.contains("sleet")   || part.contains("wintry mix")  { return .snow }
        if part.contains("thunder") || part.contains("tstm")  ||
           part.contains("heavy rain") || part.contains("shower") ||
           part.contains("rain")  || part.contains("drizzle")       { return .rain }
        if part.contains("fog")  || part.contains("mist")  ||
           part.contains("overcast")                                 { return .overcast }
        if part.contains("cloudy")                                   { return .overcast }
        if part.contains("mostly sunny") || part.contains("mostly clear") ||
           part.contains("partly sunny") || part.contains("partly cloudy") { return .mostlyClear }
        if part.contains("sunny") || part.contains("clear") ||
           part.contains("fair")  || part.contains("frost")          { return .clear }
        return nil
    }

    /* Derives the condition from an Open-Meteo WMO weather code. */
    static func fromWMO(code: Int) -> WeatherCondition {
        switch code {
        case 71...77, 85, 86:      return .snow
        case 51...67, 80...82,
             95...99:              return .rain
        case 3, 45, 48:            return .overcast
        case 1, 2:                 return .mostlyClear
        default:                   return .clear
        }
    }

    /* The condition suffix used in image asset names, e.g. "Clear", "Snow". */
    var assetSuffix: String {
        switch self {
        case .clear:       return "Clear"
        case .mostlyClear: return "MostlyClear"
        case .overcast:    return "Overcast"
        case .rain:        return "Rain"
        case .snow:        return "Snow"
        }
    }

    /* Snow backgrounds only exist for fall/spring/winter.
     * Summer snow falls back to overcast.
     */
    func adjusted(for season: WeatherSeason) -> WeatherCondition {
        if self == .snow && season == .summer { return .overcast }
        return self
    }
}

// MARK: - Background Image Resolution

/* Resolves the correct background image asset name from a season + condition pair.
 *
 * Naming convention: [season]Day[Condition]  e.g. "springDayClear"
 * Time-of-day is always "Day" for now (Night assets don't exist yet).
 *
 * Fallback chain when an asset doesn't exist yet:
 *   Snow      → Overcast → MostlyClear → Clear
 *   Overcast  → MostlyClear → Clear
 *   MostlyClear → Clear
 *   Rain      → Overcast → MostlyClear → Clear
 *   Clear     → (always exists — guaranteed safe)
 */
func backgroundImageName(season: WeatherSeason, condition: WeatherCondition) -> String {
    // Snow not available in summer — caller should have adjusted() already, but guard anyway.
    let cond = condition.adjusted(for: season)

    let candidate = "\(season.rawValue)Day\(cond.assetSuffix)"
    if UIImage(named: candidate) != nil { return candidate }

    // Fallback chain
    let fallbacks: [WeatherCondition]
    switch cond {
    case .snow:        fallbacks = [.overcast, .mostlyClear, .clear]
    case .rain:        fallbacks = [.overcast, .mostlyClear, .clear]
    case .overcast:    fallbacks = [.mostlyClear, .clear]
    case .mostlyClear: fallbacks = [.clear]
    case .clear:       fallbacks = []
    }

    for fallback in fallbacks {
        let name = "\(season.rawValue)Day\(fallback.assetSuffix)"
        if UIImage(named: name) != nil { return name }
    }

    // Last resort — summerDayClear is guaranteed to exist.
    return "summerDayClear"
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
    var weatherCondition: WeatherCondition = .clear
    var weatherSeason: WeatherSeason = .summer
    private var utcOffsetSeconds: Int = 0

    // Resolved asset name — use this in the view to load the background image.
    var backgroundImageName: String {
        NOAA_Weather.backgroundImageName(season: weatherSeason, condition: weatherCondition)
    }

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

        // Only set the location name from cache for saved locations whose name is
        // already reliable. For the current location, the geocoder always runs
        // and will overwrite this shortly — but pre-filling gives a name immediately
        // while the geocode is in-flight (better than showing “—”).
        // The geocoder result always wins, so a stale city name is only transient.
        if locationName.isEmpty {
            locationName = cached.locationName
        }

        // Only update the condition if the cache has a real condition string.
        // If empty, leave unchanged rather than snapping to a default.
        if let cond = WeatherCondition.fromCondition(cached.condition) {
            weatherCondition = cond
        }
        // Season is derived from current time + stored offset (offset unchanged from last fetch).
        weatherSeason = WeatherSeason.from(utcOffsetSeconds: utcOffsetSeconds)

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

        // For the current location (skipGeocode=false), always geocode — the coordinate
        // may have changed since the cached name was written, and we never want to show
        // a stale city name from a different location.
        // For saved locations (skipGeocode=true), the name is already correct from LocationStore.
        if !skipGeocode {
            Task { await geocodeLocationName(for: coordinate) }
        }

        do {
            let (cur, days, allHourly, sun, scraped, utcOffset) = try await WeatherRepository.shared.fetchAll(
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )

            current  = cur
            daily    = days
            sunEvent = sun
            hourly   = hourlyWindow(from: allHourly)

            let cond = WeatherCondition.fromCondition(scraped[todayKey()]?.dayCondition ?? "")
                     ?? WeatherCondition.fromWMO(code: cur.weatherCode)
            weatherCondition = cond
            weatherSeason    = WeatherSeason.from(utcOffsetSeconds: utcOffset)
            utcOffsetSeconds = utcOffset

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
            if locationName.isEmpty { locationName = "Unknown" }
            return
        }
        let city  = placemark.locality ?? ""
        let state = placemark.administrativeArea ?? ""
        locationName = city.isEmpty ? state : city
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
