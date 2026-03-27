// WeatherViewModel.swift
// White Weather

import Foundation
import CoreLocation
import Observation
import MapKit

// MARK: - Weather Background

enum WeatherBackground {
    case sun, mostlySunny, clouds, drizzle, rain, snow

    // Derive from WMO weather code (Open-Meteo fallback).
    static func from(code: Int) -> WeatherBackground {
        switch code {
        case 71...77, 85, 86:        return .snow
        case 65...67, 82, 95...99:   return .rain      // heavy rain, freezing, thunder
        case 51...64, 80, 81:        return .drizzle    // light drizzle, light showers
        case 3, 45, 48:              return .clouds     // overcast, fog
        case 1, 2:                   return .mostlySunny
        default:                     return .sun        // code 0: clear sky
        }
    }

    // Derive from a NOAA condition string. Returns nil if unrecognised — caller falls back to WMO.
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
    var errorMessage: String?

    var globalLow: Double = 0
    var globalHigh: Double = 100
    var dailyHigh: Double? { daily.first?.high }
    var dailyLow: Double?  { daily.first?.low }

    // Warm-start from cached widget data. Called immediately on deep link open,
    // before the network fetch, so the UI has something to show right away.
    func loadFromCache(id: String) {
        guard let cached = WidgetWeatherData.load(id: id) else { return }
        // Synthesise minimal display state from the flat cache struct.
        // The real fetch will replace this moments later.
        locationName = cached.locationName
        background   = WeatherBackground.fromCondition(cached.condition)
                    ?? WeatherBackground.from(code: 0)
        // We don't reconstruct the full DailyForecast array — just set the
        // current conditions so the header renders immediately.
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
            Task { await updateLocationName(for: coordinate) }
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

            // Save coordinates to the shared container so the widget can
            // re-fetch independently. We do NOT trigger a widget reload here —
            // the widget manages its own timeline.
            saveCoordinatesToSharedContainer(id: locationID ?? "current", coord: coordinate)

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

    private func updateLocationName(for coord: CLLocationCoordinate2D) async {
        let req = MKLocalSearch.Request()
        req.region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else {
            locationName = "My Location"; return
        }
        let name  = item.name ?? ""
        let city  = item.placemark.locality ?? ""
        let state = item.placemark.administrativeArea ?? ""
        locationName = (!name.isEmpty && Int(name) == nil && !name.contains(city))
            ? name : (city.isEmpty ? state : "\(city), \(state)")
    }

    // Writes the coordinate for this location ID to the shared App Group container.
    // The widget reads this when it needs to fetch fresh data independently.
    private func saveCoordinatesToSharedContainer(id: String, coord: CLLocationCoordinate2D) {
        guard let defaults = UserDefaults(suiteName: WidgetWeatherData.groupID) else { return }
        var coords = defaults.dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
        coords[id] = "\(coord.latitude),\(coord.longitude)"
        defaults.set(coords, forKey: "saved_location_coords")
    }
}
