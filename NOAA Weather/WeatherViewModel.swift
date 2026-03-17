import Foundation
import CoreLocation
import Observation
import MapKit

enum WeatherBackground {
    case sun, clouds, rain, snow
    
    static func from(code: Int) -> WeatherBackground {
        switch code {
        case 71...77, 85, 86:           return .snow
        case 51...67, 80...82, 95...99: return .rain
        case 2, 3, 45, 48:              return .clouds
        default:                        return .sun
        }
    }
    
    var videoName: String {
        switch self {
        case .sun: return "sun"; case .clouds: return "clouds"
        case .rain: return "rain"; case .snow: return "snow"
        }
    }
}

@Observable
@MainActor
final class WeatherViewModel {
    // Current State
    var current: CurrentConditions?
    var daily: [DailyForecast] = []
    var hourly: [HourlyForecast] = []
    var sunEvent: SunEvent?
    
    // UI Metadata
    var locationName: String = ""
    var background: WeatherBackground = .sun
    var isLoading = false
    var errorMessage: String?
    
    // Scaling for Charts
    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double? { daily.first?.low }

    private var lastFetchedCoordinate: CLLocationCoordinate2D?

    /// Main entry point for the UI to request data
    func load(coordinate: CLLocationCoordinate2D, skipGeocode: Bool = false) async {
        // 1. Dedup logic: Don't re-fetch if we are within ~1km of the last fetch
        if let last = lastFetchedCoordinate,
           abs(last.latitude - coordinate.latitude) < 0.01,
           abs(last.longitude - coordinate.longitude) < 0.01 { return }
        
        lastFetchedCoordinate = coordinate
        isLoading = true
        errorMessage = nil

        // 2. Geocoding (City Name)
        if !skipGeocode {
            // 1. Run the MapKit search
            await updateLocationName(for: coordinate)
            
            if self.locationName.isEmpty {
                self.locationName = "Unknown location"
            }
        }

        do {
            // 3. Use our new Orchestrator to get everything at once
            let (cur, days, sun) = try await WeatherRepository.shared.fetchAll(
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )

            // 4. Update Properties
            self.current = cur
            self.daily = days
            self.sunEvent = sun
            self.background = WeatherBackground.from(code: cur.weatherCode)
            
            // Prepare Hourly slice (next 12 hours)
            if let firstDay = days.first {
                self.hourly = Array(firstDay.hourlyTemps.prefix(12))
            }
            
            // 5. Calculate Global Min/Max for unified chart scaling
            calculateGlobalBounds(days: days)

        } catch {
            self.errorMessage = "Failed to load weather: \(error.localizedDescription)"
        }

        self.isLoading = false
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
