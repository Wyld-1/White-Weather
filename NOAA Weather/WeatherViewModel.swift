//
//  WeatherViewModel.swift
//  NOAA Weather

import Foundation
import CoreLocation

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
    var current: CurrentConditions?
    var hourly: [HourlyForecast] = []
    var daily: [DailyForecast] = []
    var locationName: String = ""
    var background: WeatherBackground = .sun
    var dailyHigh: Double?
    var dailyLow: Double?
    var isLoading = false
    var errorMessage: String?
    var sunEvent: SunEvent?
    var globalLow: Double = 0
    var globalHigh: Double = 100

    private var lastFetchedCoordinate: CLLocationCoordinate2D?
    private var lastCoord: CLLocationCoordinate2D?

    /// Force a fresh fetch regardless of the dedup guard.
    /// Preserves the current locationName so geocoding doesn't re-run (and can't cancel).
    func refresh(coordinate: CLLocationCoordinate2D) async {
        lastFetchedCoordinate = nil
        // Detach from the caller's task so SwiftUI's refreshable cancellation
        // doesn't propagate into our network requests.
        await Task.detached(priority: .userInitiated) { [weak self] in
            await self?.load(coordinate: coordinate, skipGeocode: true)
        }.value
    }

    /// Override the display name (used for ski resorts / saved locations with known names).
    func setLocationName(_ name: String) {
        locationName = name
    }

    func load(coordinate: CLLocationCoordinate2D, skipGeocode: Bool = false) async {
        if let last = lastFetchedCoordinate,
           abs(last.latitude  - coordinate.latitude)  < 0.01,
           abs(last.longitude - coordinate.longitude) < 0.01 { return }
        lastFetchedCoordinate = coordinate
        isLoading = true
        errorMessage = nil

        // Reverse geocode only on first load and only if no override name is set
        if !skipGeocode && locationName.isEmpty {
            if let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)),
               let place = placemarks.first {
                locationName = [place.locality, place.administrativeArea]
                    .compactMap { $0 }.joined(separator: ", ")
            }
        }

        do {
            let lat = coordinate.latitude
            let lon = coordinate.longitude

            // Fetch Open-Meteo and NOAA webpage concurrently; NOAA is best-effort
            async let omFetch    = OpenMeteoClient.shared.fetch(lat: lat, lon: lon)
            async let noaaFetch  = NOAAWebScraper.shared.fetch(lat: lat, lon: lon)

            let om = try await omFetch
            let noaaData = (try? await noaaFetch) ?? [:]

            let offset = om.utcOffsetSeconds
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: offset) ?? .current

            // ── Current ──────────────────────────────────────────────
            let c = om.current
            current = CurrentConditions(
                temperature: c.temperature2m,
                description: wmoDescription(code: c.weatherCode, isDay: c.isDay == 1),
                windSpeed: c.windSpeed10m,
                windGusts: c.windGusts10m,
                windDirection: c.windDirection10m,
                windDirectionLabel: compassDirection(from: c.windDirection10m),
                humidity: c.relativeHumidity2m,
                weatherCode: c.weatherCode
            )
            background = WeatherBackground.from(code: c.weatherCode)

            // ── Hourly (next 12) ──────────────────────────────────────
            let now = Date()
            let h = om.hourly
            var allHourly: [HourlyForecast] = []
            for i in 0..<h.time.count {
                let t = parseOMDate(h.time[i], utcOffset: offset)
                guard t >= now.addingTimeInterval(-3600) else { continue }
                allHourly.append(HourlyForecast(
                    time: t,
                    temperature: h.temperature2m[i],
                    weatherCode: h.weatherCode[i],
                    precipitationProbability: h.precipitationProbability[i]
                ))
            }
            hourly = Array(allHourly.prefix(12))

            // Group all hourly by local day key for graphs
            let hourlyByDay = Dictionary(grouping: allHourly) { dayKey(for: $0.time, cal: cal) }

            // ── Daily (today + 9 more = 10 days) ─────────────────────
            let d = om.daily
            var days: [DailyForecast] = []

            for i in 0..<d.time.count {
                let dayDate = parseOMDay(d.time[i], utcOffset: offset)

                // Skip any days before today (Open-Meteo always starts at today,
                // but guard just in case of timezone edge cases)
                guard cal.isDateInToday(dayDate) || dayDate > now else { continue }
                guard days.count < 10 else { break }

                let key = dayKey(for: dayDate, cal: cal)

                // Day label
                let name: String
                let fullName: String
                if cal.isDateInToday(dayDate) {
                    name = "Today"; fullName = "Today"
                } else {
                    let fmt = DateFormatter()
                    fmt.timeZone = cal.timeZone
                    fmt.dateFormat = "EEE";  name     = fmt.string(from: dayDate)
                    fmt.dateFormat = "EEEE"; fullName = fmt.string(from: dayDate)
                }

                let code = d.weatherCode[i]

                let tempPoints: [HourlyTempPoint] = (hourlyByDay[key] ?? []).map {
                    HourlyTempPoint(time: $0.time, temperature: $0.temperature,
                                    weatherCode: $0.weatherCode,
                                    precipitationProbability: $0.precipitationProbability)
                }

                let noaa = noaaData[key]
                let noaaCondition = noaa?.condition ?? ""
                // Use NOAA condition for short label if available, otherwise WMO
                let shortLabel = noaaCondition.isEmpty ? wmoDescription(code: code, isDay: true) : noaaCondition

                days.append(DailyForecast(
                    dayName: name,
                    fullDayName: fullName,
                    weatherCode: code,
                    shortForecast: shortLabel,
                    noaaCondition: noaaCondition,
                    detailedForecast: noaa?.detailedForecast ?? "",
                    snowAccumulation: noaa?.snowAccumulation,
                    precipProbability: d.precipitationProbabilityMax[i],
                    high: d.temperature2mMax[i],
                    low: d.temperature2mMin[i],
                    windSpeed: d.windSpeed10mMax[i],
                    windDirection: compassDirection(from: d.windDirection10mDominant[i]),
                    hourlyTemps: tempPoints
                ))
            }
            daily = days

            // ── Global scale ──────────────────────────────────────────
            let highs = daily.compactMap { $0.high }
            let lows  = daily.compactMap { $0.low }
            if !highs.isEmpty && !lows.isEmpty {
                globalLow  = (lows.min()!  - 2).rounded()
                globalHigh = (highs.max()! + 2).rounded()
            }
            dailyHigh = daily.first?.high
            dailyLow  = daily.first?.low

            // ── Sunrise/sunset ────────────────────────────────────────
            if let sr = d.sunrise.first, let ss = d.sunset.first {
                sunEvent = SunEvent(
                    sunrise: parseOMDate(sr, utcOffset: offset),
                    sunset:  parseOMDate(ss, utcOffset: offset)
                )
            }

        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
            print("WeatherViewModel error: \(error)")
        }

        isLoading = false
    }

    private func dayKey(for date: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
}
