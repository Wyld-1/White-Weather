import Foundation
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
}

@Observable
@MainActor
final class WeatherViewModel {
    private var lastFetchTime: Date?
    private var lastFetchedCoordinate: CLLocationCoordinate2D?

    // Weather data
    var current: CurrentConditions?
    var daily: [DailyForecast] = []
    var hourly: [HourlyForecast] = []
    var sunEvent: SunEvent?

    // UI state
    var locationName: String = ""
    var background: WeatherBackground = .sun
    var isLoading = false
    var isAnalyzing = false   // true while AI night-severity analysis is running
    var errorMessage: String?

    // Chart scaling
    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double? { daily.first?.low }

    func load(coordinate: CLLocationCoordinate2D, skipGeocode: Bool = false, forceRefresh: Bool = false) async {
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

            // Phase 1: show weather immediately
            current = cur
            daily   = days
            sunEvent = sun
            background = WeatherBackground.from(code: cur.weatherCode)
            hourly = Array((days.first?.hourlyTemps ?? []).prefix(12))
            calculateGlobalBounds(days: days)
            isLoading = false
            lastFetchTime = Date()

            // Phase 2: AI night-severity analysis in background, concurrent across all days
            guard !scrapedPeriods.isEmpty else { return }
            isAnalyzing = true
            let severityMap = await NOAAScraper.shared.analyzeNightSeverity(for: scrapedPeriods)
            applyNightSeverity(severityMap, scrapedPeriods: scrapedPeriods)
            isAnalyzing = false

        } catch {
            errorMessage = "Failed to load weather: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Patches daily array in-place with AI results, updating only the night symbol.
    private func applyNightSeverity(
        _ map: [String: Bool],
        scrapedPeriods: [String: NOAAScraper.ScrapedPeriod]
    ) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        daily = daily.map { day in
            let key = fmt.string(from: day.date)
            guard let severe = map[key], severe,
                  let period = scrapedPeriods[key] else { return day }
            // Build night symbol from the actual night condition string
            let nightSym = noaaSFSymbol(condition: period.nightCondition, isDay: false)
                        ?? nightFallback(for: day.precipType)
            return DailyForecast(
                id: day.id, date: day.date, high: day.high, low: day.low,
                precipProbability: day.precipProbability,
                shortForecast: day.shortForecast,
                dayProse: day.dayProse, nightProse: day.nightProse,
                accumulation: day.accumulation,
                precipType: day.precipType,
                isNightSevere: true,
                daySymbol: day.daySymbol,
                nightSymbol: nightSym,
                hourlyTemps: day.hourlyTemps
            )
        }
    }

    private func nightFallback(for type: PrecipType) -> String {
        switch type {
        case .snow, .mixed: return "cloud.snow.fill"
        case .rain:         return "cloud.rain.fill"
        case .none:         return "cloud.bolt.rain.fill"
        }
    }

    func setLocationName(_ name: String) {
        self.locationName = name
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
}
