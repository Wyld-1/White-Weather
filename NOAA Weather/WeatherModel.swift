import Foundation
import SwiftSoup
import MapKit

// MARK: - 1. Domain Models

struct HourlyForecast: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int
}

struct DailyForecast: Identifiable {
    let id = UUID()
    let date: Date
    let high: Double
    let low: Double
    let precipProbability: Int
    
    let shortForecast: String
    let detailedForecast: String
    let snowAccumulation: String?
    let isRain: Bool
    
    let daySymbol: String
    let nightSymbol: String?
    
    let hourlyTemps: [HourlyForecast]
}

struct CurrentConditions {
    let temperature: Double
    let description: String
    let windSpeed: Double
    let windGusts: Double
    let windDirection: Double
    let windDirectionLabel: String
    let humidity: Double
    let weatherCode: Int
    let isDay: Bool
}

struct SunEvent {
    let sunrise: Date
    let sunset: Date
    var nextIsRise: Bool { Date() < sunrise || Date() > sunset }
    var nextTime: Date { Date() < sunrise ? sunrise : sunset }
}

// MARK: - 2. Data Transfer Objects (DTOs)

struct OpenMeteoResponse: Decodable {
    let utcOffsetSeconds: Int?
    let current: CurrentBlock?
    let hourly: HourlyBlock?
    let daily: DailyBlock?

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
    }

    struct CurrentBlock: Decodable {
        let time: String?
        let temperature2m: Double?
        let relativeHumidity2m: Double?
        let windSpeed10m: Double?
        let windGusts10m: Double?
        let windDirection10m: Double?
        let weatherCode: Int?
        let isDay: Int?
        
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code", isDay = "is_day"
            case temperature2m = "temperature_2m", relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m = "wind_speed_10m", windGusts10m = "wind_gusts_10m", windDirection10m = "wind_direction_10m"
        }
    }

    struct HourlyBlock: Decodable {
        let time: [String]?
        let temperature2m: [Double]?
        let weatherCode: [Int]?
        let precipitationProbability: [Int]?
        
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code"
            case temperature2m = "temperature_2m", precipitationProbability = "precipitation_probability"
        }
    }

    struct DailyBlock: Decodable {
        let time: [String]?
        let weatherCode: [Int]?
        let temperature2mMax: [Double?]?
        let temperature2mMin: [Double?]?
        let precipitationProbabilityMax: [Int?]?
        let sunrise: [String]?
        let sunset: [String]?
        
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code", sunrise, sunset
            case temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }
}

// MARK: - 3. The Orchestrator (Repository)

actor WeatherRepository {
    static let shared = WeatherRepository()
    private let isoFormatter = ISO8601DateFormatter()
    
    func fetchAll(lat: Double, lon: Double) async throws -> (CurrentConditions, [DailyForecast], SunEvent) {
        async let omTask = OpenMeteoClient.shared.fetch(lat: lat, lon: lon)
        async let noaaTask = NOAAScraper.shared.fetchProse(lat: lat, lon: lon)
        
        let (om, noaa) = try await (omTask, noaaTask)
        
        let current = CurrentConditions(
            temperature: om.current?.temperature2m ?? 0,
            description: wmoDescription(code: om.current?.weatherCode ?? 0, isDay: om.current?.isDay == 1),
            windSpeed: om.current?.windSpeed10m ?? 0,
            windGusts: om.current?.windGusts10m ?? 0,
            windDirection: om.current?.windDirection10m ?? 0,
            windDirectionLabel: compassDirection(from: om.current?.windDirection10m ?? 0),
            humidity: om.current?.relativeHumidity2m ?? 0,
            weatherCode: om.current?.weatherCode ?? 0,
            isDay: om.current?.isDay == 1
        )
        
        var allHourly: [HourlyForecast] = []
        if let hTime = om.hourly?.time {
            for i in 0..<hTime.count {
                allHourly.append(HourlyForecast(
                    time: isoFormatter.date(from: hTime[i] + ":00Z") ?? Date(),
                    temperature: om.hourly?.temperature2m?[i] ?? 0,
                    weatherCode: om.hourly?.weatherCode?[i] ?? 0,
                    precipitationProbability: om.hourly?.precipitationProbability?[i] ?? 0
                ))
            }
        }
        
        var dailyModels: [DailyForecast] = []
        let cal = Calendar.current
        
        if let dTime = om.daily?.time {
            for i in 0..<dTime.count {
                let dateKey = dTime[i]
                let date = parseOMDate(dateKey)
                let noaaData = noaa[dateKey]
                
                let dayCode = om.daily?.weatherCode?[i] ?? 0
                let daySymbol = wmoSFSymbol(code: dayCode, isDay: true)
                
                var nightSymbol: String? = nil
                if noaaData?.isNightSevere == true {
                    nightSymbol = wmoSFSymbol(code: dayCode, isDay: false)
                }
                
                // Authority check: Use NOAA precip % if found, else fall back to OpenMeteo
                let finalPrecip = noaaData?.precipChance ?? (om.daily?.precipitationProbabilityMax?[i] ?? 0)
                
                dailyModels.append(DailyForecast(
                    date: date,
                    high: om.daily?.temperature2mMax?[i] ?? 0,
                    low: om.daily?.temperature2mMin?[i] ?? 0,
                    precipProbability: finalPrecip,
                    shortForecast: noaaData?.condition ?? wmoDescription(code: dayCode, isDay: true),
                    detailedForecast: noaaData?.prose ?? "No detailed forecast available.",
                    snowAccumulation: noaaData?.accumulation,
                    isRain: noaaData?.isRain ?? false,
                    daySymbol: daySymbol,
                    nightSymbol: nightSymbol,
                    hourlyTemps: allHourly.filter { cal.isDate($0.time, inSameDayAs: date) }
                ))
            }
        }
        
        let sun = SunEvent(
            sunrise: isoFormatter.date(from: (om.daily?.sunrise?.first ?? "") + ":00Z") ?? Date(),
            sunset: isoFormatter.date(from: (om.daily?.sunset?.first ?? "") + ":00Z") ?? Date()
        )
        
        return (current, dailyModels, sun)
    }
    
    private func parseOMDate(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s) ?? Date()
    }
}

// MARK: - 4. Network Clients

actor OpenMeteoClient {
    static let shared = OpenMeteoClient()
    private let session = URLSession(configuration: .default)

    func fetch(lat: Double, lon: Double) async throws -> OpenMeteoResponse {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: "\(lat)"),
            .init(name: "longitude", value: "\(lon)"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "11"),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset")
        ]
        let (data, _) = try await session.data(from: comps.url!)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }
}

actor NOAAScraper {
    static let shared = NOAAScraper()
    
    struct ScrapedPeriod {
        let condition: String
        let prose: String
        let accumulation: String?
        let isRain: Bool
        let isNightSevere: Bool
        let precipChance: Int?
    }

    func fetchProse(lat: Double, lon: Double) async throws -> [String: ScrapedPeriod] {
        let url = URL(string: "https://forecast.weather.gov/MapClick.php?lat=\(lat)&lon=\(lon)")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return [:] }
        
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("#detailed-forecast-body .row-forecast")
        
        var result: [String: ScrapedPeriod] = [:]
        let cal = Calendar.current
        var cursor = cal.startOfDay(for: Date())
        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "EEEE"

        for row in rows {
            let label = try row.select(".forecast-label").text()
            let text = try row.select(".forecast-text").text()
            let lowerLabel = label.lowercased()
            let lowerText = text.lowercased()
            let isNight = lowerLabel.contains("night") || lowerLabel.contains("tonight")
            
            if !isNight {
                let expectedDayName = dayFormatter.string(from: cursor).lowercased()
                if !lowerLabel.contains(expectedDayName) {
                    cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                }
            }
            
            let key = dateToKey(cursor)
            let accum = extractAccumulation(from: text)
            let isRain = lowerText.contains("precipitation") || lowerText.contains("rainfall") || lowerText.contains("rain")
            let precipChance = extractPrecipChance(from: text)
            
            // False positive fix: Only trigger severe icon if accumulation is significant
            let isSignificant = accum != nil && !accum!.contains("<1") && !accum!.contains("0.1")
            let currentPeriodIsSevere = isNight && (lowerText.contains("thunder") ||
                                                  (lowerText.contains("heavy") && isSignificant) ||
                                                  (lowerText.contains("snow") && isSignificant))
            
            if let existing = result[key] {
                result[key] = ScrapedPeriod(
                    condition: existing.condition,
                    prose: existing.prose + "\n\n\(label): \(text)",
                    accumulation: existing.accumulation ?? accum,
                    isRain: existing.isRain || isRain,
                    isNightSevere: existing.isNightSevere || currentPeriodIsSevere,
                    precipChance: precipChance ?? existing.precipChance
                )
            } else {
                result[key] = ScrapedPeriod(
                    condition: label,
                    prose: "\(label): \(text)",
                    accumulation: accum,
                    isRain: isRain,
                    isNightSevere: currentPeriodIsSevere,
                    precipChance: precipChance
                )
            }
        }
        return result
    }
    
    private func dateToKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private func extractPrecipChance(from text: String) -> Int? {
        let pattern = "Chance of precipitation is ([0-9]+)%"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func extractAccumulation(from text: String) -> String? {
        let lower = text.lowercased()
        // 1. Handle fractions
        if lower.contains("amounts between") {
            if lower.contains("quarter and half") { return "0.25–0.5\"" }
            if lower.contains("tenth and a quarter") { return "0.1–0.25\"" }
            if lower.contains("half and three quarters") { return "0.5–0.75\"" }
        }
        // 2. Handle "less than"
        if lower.contains("less than one inch") || lower.contains("less than an inch") { return "<1\"" }
        
        // 3. Handle numeric ranges
        let pattern = #"([0-9]+(?:\.[0-9]+)?)(?:\s+to\s+([0-9]+(?:\.[0-9]+)?))?\s*inch"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let firstValue = (text as NSString).substring(with: match.range(at: 1))
            let secondRange = match.range(at: 2)
            if secondRange.location != NSNotFound {
                let secondValue = (text as NSString).substring(with: secondRange)
                return "\(firstValue)–\(secondValue)\""
            } else {
                return "\(firstValue)\""
            }
        }
        return nil
    }
}

// MARK: - Helpers

nonisolated func wmoDescription(code: Int, isDay: Bool) -> String {
    switch code {
    case 0...1: return "Clear"
    case 2: return "Partly Cloudy"
    case 3: return "Cloudy"
    case 45, 48: return "Fog"
    case 51...55: return "Drizzle"
    case 61...65: return "Rain"
    case 71...77: return "Snow"
    case 80...82: return "Showers"
    case 95...99: return "Thunderstorms"
    default: return "Overcast"
    }
}

nonisolated func wmoSFSymbol(code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
    case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51...65: return "cloud.rain.fill"
    case 71...77: return "cloud.snow.fill"
    case 80...82: return "cloud.heavyrain.fill"
    case 95...99: return "cloud.bolt.rain.fill"
    default: return "cloud.fill"
    }
}

nonisolated func wmoPrecipSymbol(code: Int) -> String {
    switch code {
    case 71...77: return "snowflake"
    case 95...99: return "cloud.bolt.fill"
    default: return "drop.fill"
    }
}

nonisolated func compassDirection(from degrees: Double) -> String {
    let d = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return d[Int((degrees + 11.25) / 22.5) % 16]
}
