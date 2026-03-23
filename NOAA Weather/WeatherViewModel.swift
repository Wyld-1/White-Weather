import Foundation
import WidgetKit
import CoreLocation
import Observation
import MapKit

enum WeatherBackground {
    case sun, mostlySunny, clouds, drizzle, rain, snow

    static func from(code: Int) -> WeatherBackground {
        switch code {
        case 71...77, 85, 86:                   return .snow
        case 65, 66, 67, 82, 95...99:           return .rain      // heavy rain, freezing rain, thunderstorms
        case 51...64, 80, 81:                   return .drizzle   // light drizzle, light/moderate rain, light showers
        case 3, 45, 48:                         return .clouds    // overcast, fog
        case 1, 2:                              return .mostlySunny  // mainly clear, partly cloudy
        default:                                return .sun       // code 0: clear sky
        }
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

    // Derive background from a NOAA condition string (e.g. "Mostly Sunny", "Chance Snow Showers").
    // Returns nil if condition is empty or unrecognised — caller falls back to WMO code.
    static func fromCondition(_ condition: String) -> WeatherBackground? {
        let c = condition.lowercased()
        guard !c.isEmpty else { return nil }
        // Handle "X then Y" — use the dominant (post-then) part
        let part = c.components(separatedBy: " then ").last ?? c
        if part.contains("thunder") || part.contains("tstm")               { return .rain }
        if part.contains("blizzard") || part.contains("heavy snow")         { return .snow }
        if part.contains("snow") || part.contains("flurr") || part.contains("sleet") { return .snow }
        if part.contains("heavy rain") || part.contains("shower")           { return .rain }
        if part.contains("rain") || part.contains("drizzle")               { return .drizzle }
        if part.contains("fog") || part.contains("mist")                   { return .clouds }
        if part.contains("overcast") || part.contains("cloudy")            { return .clouds }
        if part.contains("mostly sunny") || part.contains("mostly clear")  { return .mostlySunny }
        if part.contains("partly sunny") || part.contains("partly cloudy") { return .mostlySunny }
        if part.contains("sunny") || part.contains("clear") || part.contains("fair") { return .sun }
        return nil
    }
}

@Observable
@MainActor
final class WeatherViewModel {
    private var lastFetchTime: Date?
    private var lastFetchedCoordinate: CLLocationCoordinate2D?
    var isSkiResort: Bool = false

    // Weather data
    var current: CurrentConditions?
    var daily: [DailyForecast] = []
    var hourly: [HourlyForecast] = []
    var sunEvent: SunEvent?

    // UI state
    var locationName: String = ""
    var background: WeatherBackground = .sun
    var isLoading = false
    var errorMessage: String?
    var activeLocationID: String?

    // Chart scaling
    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double? { daily.first?.low }

    func load(
        coordinate: CLLocationCoordinate2D,
        locationID: String? = nil,
        skipGeocode: Bool = false,
        forceRefresh: Bool = false
    ) async {
        self.activeLocationID = locationID
        
        if !forceRefresh,
           let last = lastFetchedCoordinate,
           abs(last.latitude - coordinate.latitude) < 0.01,
           abs(last.longitude - coordinate.longitude) < 0.01,
           let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < 900 { return }

        lastFetchedCoordinate = coordinate
        isLoading = true
        errorMessage = nil

        // Geocode concurrently — don't block weather fetch
        if !skipGeocode && locationName.isEmpty {
            Task { await updateLocationName(for: coordinate) }
        }

        do {
            let (cur, days, sun, scrapedPeriods) = try await WeatherRepository.shared.fetchAll(
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )

            // Show weather immediately
            current = cur
            daily   = days
            sunEvent = sun

            // Background + description from NOAA condition string, WMO code as fallback
            let todayCondition = scrapedPeriods[todayKey()]?.dayCondition ?? ""
            background = WeatherBackground.fromCondition(todayCondition)
                      ?? WeatherBackground.from(code: cur.weatherCode)

            // Hourly: current hour → 11pm today
            hourly = hourlyWindow(from: days.first?.hourlyTemps ?? [])
            calculateGlobalBounds(days: days)
            isLoading = false
            lastFetchTime = Date()
            
            updateWidget(id: activeLocationID ?? "current")
            
            isLoading = false
            lastFetchTime = Date()

        } catch {
            errorMessage = "Failed to load weather: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // Hourly window: current floored hour through current hour + 12.
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

    func setLocationName(_ name: String) {
        self.locationName = name
    }
    
    func setSkiResort(_ value: Bool) {
            self.isSkiResort = value
        }

    private func updateLocationName(for coord: CLLocationCoordinate2D) async {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        let search = MKLocalSearch(request: request)
        
        do {
            let response = try await search.start()
            if let mapItem = response.mapItems.first {
                let name = mapItem.name ?? ""
                
                // Use the localized address string if the granular components are being fussy
                // This is the "safe" way that works across all iOS versions
                let city = mapItem.placemark.locality ?? ""
                let state = mapItem.placemark.administrativeArea ?? ""
                
                if !name.isEmpty && Int(name) == nil && !name.contains(city) {
                    self.locationName = name // Best for Ski Resorts/Points of Interest
                } else {
                    self.locationName = city.isEmpty ? state : "\(city), \(state)"
                }
            }
        } catch {
            self.locationName = "My Location"
        }
    }

    private func calculateGlobalBounds(days: [DailyForecast]) {
        let highs = days.map { $0.high }
        let lows = days.map { $0.low }
        if let minL = lows.min(), let maxH = highs.max() {
            self.globalLow = (minL - 2).rounded(.down)
            self.globalHigh = (maxH + 2).rounded(.up)
        }
    }
    
    private func updateWidget(id: String) {
        guard let cur = current, let firstDay = daily.first else { return }
        
        let widgetData = WidgetWeatherData(
            id: id,
            temperature: cur.temperature,
            high: firstDay.high,
            low: firstDay.low,
            condition: cur.description,
            sfSymbol: firstDay.daySymbol,
            locationName: locationName,
            windGusts: cur.windGusts,
            isDay: cur.isDay,
            accumDisplayString: firstDay.accumulation.displayString,
            dayProse: firstDay.dayProse,
            nightProse: firstDay.nightProse,
            fetchedAt: Date()
        )
        
        widgetData.save()
        
        // Also update the "registry" of names so the intent can see them
        let defaults = UserDefaults(suiteName: WidgetWeatherData.groupID)
        var names = defaults?.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]
        names[id] = locationName
        defaults?.set(names, forKey: "saved_location_names")
        
        WidgetCenter.shared.reloadAllTimelines()
    }
}
