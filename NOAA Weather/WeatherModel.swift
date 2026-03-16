//
//  WeatherModel.swift
//  NOAA Weather

import Foundation

// MARK: - Domain Models

struct CurrentConditions {
    let temperature: Double
    let description: String
    let windSpeed: Double         // mph
    let windGusts: Double         // mph
    let windDirection: Double     // degrees 0–360
    let windDirectionLabel: String // e.g. "WNW"
    let humidity: Double
    let weatherCode: Int
}

struct HourlyTempPoint: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int
}

struct HourlyForecast: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int
}

struct DailyForecast: Identifiable {
    let id = UUID()
    let dayName: String
    let fullDayName: String
    let weatherCode: Int              // Open-Meteo WMO code (for hourly graph, temps)
    let shortForecast: String         // human-readable from NOAA or WMO fallback
    let noaaCondition: String         // raw NOAA zone condition, e.g. "Partly Sunny"
    let detailedForecast: String      // full NOAA prose, e.g. "Snow accumulation 4–8 inches…"
    let snowAccumulation: String?     // e.g. "2 to 4 inches" if present, else nil
    let precipProbability: Int
    let high: Double?
    let low: Double?
    let windSpeed: Double
    let windDirection: String
    let hourlyTemps: [HourlyTempPoint]
}

struct SunEvent {
    let sunrise: Date
    let sunset: Date
    var nextIsRise: Bool { Date() < sunrise || Date() > sunset }
    var nextTime: Date { Date() < sunrise ? sunrise : sunset }
}

// MARK: - Open-Meteo

struct OpenMeteoResponse: Decodable {
    let utcOffsetSeconds: Int
    let current: CurrentBlock
    let hourly: HourlyBlock
    let daily: DailyBlock

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
    }

    struct CurrentBlock: Decodable {
        let time: String
        let temperature2m: Double
        let relativeHumidity2m: Double
        let windSpeed10m: Double
        let windGusts10m: Double
        let windDirection10m: Double
        let weatherCode: Int
        let isDay: Int
        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m = "wind_speed_10m"
            case windGusts10m = "wind_gusts_10m"
            case windDirection10m = "wind_direction_10m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct HourlyBlock: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Int]
        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case precipitationProbability = "precipitation_probability"
        }
    }

    struct DailyBlock: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double?]
        let temperature2mMin: [Double?]
        let precipitationProbabilityMax: [Int]
        let windSpeed10mMax: [Double]
        let windDirection10mDominant: [Double]
        let sunrise: [String]
        let sunset: [String]
        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case windSpeed10mMax = "wind_speed_10m_max"
            case windDirection10mDominant = "wind_direction_10m_dominant"
            case sunrise, sunset
        }
    }
}

actor OpenMeteoClient {
    static let shared = OpenMeteoClient()
    private let session: URLSession
    private init() {
        let c = URLSessionConfiguration.default; c.timeoutIntervalForRequest = 15
        session = URLSession(configuration: c)
    }

    func fetch(lat: Double, lon: Double) async throws -> OpenMeteoResponse {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",         value: "\(lat)"),
            .init(name: "longitude",        value: "\(lon)"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit",  value: "mph"),
            .init(name: "timezone",         value: "auto"),
            .init(name: "forecast_days",    value: "11"),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,is_day"),
            .init(name: "hourly",  value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily",   value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,wind_direction_10m_dominant,sunrise,sunset"),
        ]
        let (data, _) = try await session.data(from: comps.url!)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }
}

// MARK: - NOAA Web Scraper (SwiftSoup)

import SwiftSoup

/// One day's scraped NOAA zone forecast data
struct NOAADayForecast {
    let condition: String        // e.g. "Partly Sunny", "Mostly Cloudy"
    let detailedForecast: String // full prose from the detailed forecast table
    let snowAccumulation: String? // e.g. "2 to 4 inches" if mentioned, else nil
}

actor NOAAWebScraper {
    static let shared = NOAAWebScraper()
    private let session: URLSession
    private init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        session = URLSession(configuration: c)
    }

    /// Returns map of "yyyy-M-d" → NOAADayForecast scraped from forecast.weather.gov
    func fetch(lat: Double, lon: Double) async throws -> [String: NOAADayForecast] {
        let urlStr = "https://forecast.weather.gov/MapClick.php?lat=\(lat)&lon=\(lon)"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }

        let doc = try SwiftSoup.parse(html)
        var result: [String: NOAADayForecast] = [:]

        // ── 7-day forecast icons (short condition per period) ──────────────
        // Each period is a <div class="tombstone-container"> with an <img title="..."> and <p class="period-name">
        let tombstones = try doc.select("div.tombstone-container")
        // We'll parse these into a flat list of (periodName, condition)
        var periodConditions: [(name: String, condition: String)] = []
        for stone in tombstones {
            let img = try stone.select("img").first()
            let condition = try img?.attr("title") ?? ""
            let nameParts = try stone.select("p.period-name").first()?.text() ?? ""
            if !condition.isEmpty { periodConditions.append((nameParts, condition)) }
        }

        // ── Detailed forecast table ────────────────────────────────────────
        // <div id="detailed-forecast-body"> contains rows with period name + prose
        let detailRows = try doc.select("div#detailed-forecast-body div.row-forecast")
        var detailMap: [String: String] = [:] // period name → detail text
        for row in detailRows {
            let label = try row.select("b.forecast-label").first()?.text() ?? ""
            let body  = try row.select("div.forecast-text").first()?.text() ?? ""
            if !label.isEmpty { detailMap[label] = body }
        }

        // ── Map periods to calendar dates ──────────────────────────────────
        // NOAA labels: "Tonight", "Monday", "Monday Night", "Tuesday", etc.
        // We walk forward from today assigning dates.
        let cal = Calendar.current
        let now = Date()
        var dateMap: [String: Date] = [:]
        var cursor = cal.startOfDay(for: now)

        for (name, _) in periodConditions {
            let lower = name.lowercased()
            // Advance cursor for night periods
            if lower.contains("night") || lower == "tonight" {
                // same calendar day as the previous daytime
            } else if lower.contains("this afternoon") || lower.contains("today") || lower.contains("this evening") {
                cursor = cal.startOfDay(for: now)
            } else if !lower.contains("tonight") && dateMap[name] == nil {
                // It's a new daytime period — if we've already assigned today, advance
                if let lastDay = dateMap.values.max(), cal.isDate(lastDay, inSameDayAs: cursor) {
                    cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                }
            }
            dateMap[name] = cursor
        }

        // Rebuild with proper day advancement
        // Simpler approach: parse in order, track which day we're on
        dateMap = [:]
        var dayOffset = 0
        var lastWasNight = false

        for (name, _) in periodConditions {
            let lower = name.lowercased()
            let isNight = lower.contains("night") || lower == "tonight"

            if !isNight && lastWasNight {
                dayOffset += 1  // new day after a night period
            } else if !isNight && !lastWasNight && dayOffset > 0 {
                dayOffset += 1  // two consecutive day periods (shouldn't happen but guard)
            }
            lastWasNight = isNight

            let date = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
            dateMap[name] = date
        }

        // ── Build result ───────────────────────────────────────────────────
        for (name, condition) in periodConditions {
            guard let date = dateMap[name] else { continue }
            let lower = name.lowercased()
            let isNight = lower.contains("night") || lower == "tonight"
            // Only use daytime condition for the day's primary condition
            // (nights get merged into the day's detail)
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let key = "\(comps.year!)-\(comps.month!)-\(comps.day!)"

            let detail = detailMap[name] ?? ""
            let snow = extractSnowAccumulation(from: detail)

            if !isNight {
                // Daytime — set primary condition
                let existing = result[key]
                let combinedDetail: String
                if let ex = existing {
                    combinedDetail = ex.detailedForecast + "\n\n" + detail
                } else {
                    combinedDetail = detail
                }
                result[key] = NOAADayForecast(
                    condition: condition,
                    detailedForecast: combinedDetail,
                    snowAccumulation: snow ?? existing?.snowAccumulation
                )
            } else {
                // Night — append detail, keep daytime condition, update snow if newly found
                if let existing = result[key] {
                    result[key] = NOAADayForecast(
                        condition: existing.condition,
                        detailedForecast: existing.detailedForecast + (detail.isEmpty ? "" : "\n\n" + detail),
                        snowAccumulation: existing.snowAccumulation ?? snow
                    )
                } else {
                    // Night-only day (e.g. Tonight when fetched in afternoon)
                    result[key] = NOAADayForecast(
                        condition: condition,
                        detailedForecast: detail,
                        snowAccumulation: snow
                    )
                }
            }
        }

        return result
    }

    /// Extracts accumulation from NOAA prose.
    /// Snow: always shown if mentioned. Rain: only if >= 0.5".
    /// Ignores pure tenths (e.g. 0.1") for snow.
    private func extractSnowAccumulation(from text: String) -> String? {
        let lower = text.lowercased()
        let hasSnow = lower.contains("snow") || lower.contains("accumulation")
        let hasHeavyRain = lower.contains("heavy rain") || lower.contains("rainfall")
        guard hasSnow || hasHeavyRain else { return nil }

        // Patterns with capture group 1 = the amount
        let patterns = [
            "[Tt]otal (?:snow|nighttime) accumulation of (less than one inch)",
            "[Tt]otal (?:snow|nighttime) accumulation of (less than [0-9.]+ inches?)",
            "[Tt]otal (?:snow|nighttime) accumulation of ([0-9.]+ to [0-9.]+ inches?)",
            "[Tt]otal (?:snow|nighttime) accumulation of (around [0-9.]+ inches?)",
            "[Tt]otal (?:snow|nighttime) accumulation of ([0-9.]+ inches?)",
            "accumulation of (less than one inch)",
            "accumulation of (less than [0-9.]+ inches?)",
            "accumulation of ([0-9.]+ to [0-9.]+ inches?)",
            "accumulation of (around [0-9.]+ inches?)",
            "accumulation of ([0-9.]+ inches?)",
            "([0-9.]+ to [0-9.]+ inches?) (?:possible|expected)",
            "(less than one inch) (?:possible|expected)",
            "(less than [0-9.]+ inches?) (?:possible|expected)",
            "around ([0-9.]+) inches?",
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges > 1 else { continue }
            let captureNS = match.range(at: 1)
            guard captureNS.location != NSNotFound else { continue }
            let amount = nsText.substring(with: captureNS)
                .trimmingCharacters(in: .whitespaces)

            // For rain-only, suppress if < 0.5"
            if !hasSnow && hasHeavyRain {
                guard firstNumericValue(in: amount) >= 0.5 else { continue }
            }

            // Suppress snow amounts that are pure tenths (0.1") — not worth showing
            if hasSnow {
                let n = firstNumericValue(in: amount)
                if n > 0 && n < 0.2 && !amount.lowercased().contains("less") { continue }
            }

            return amount
        }
        return nil
    }

    private func firstNumericValue(in s: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?"),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return 0 }
        return Double(s[range]) ?? 0
    }
}

// MARK: - NOAA condition string → SF Symbol
// Maps the exact strings NOAA uses on forecast.weather.gov

func noaaSFSymbol(from condition: String, isDay: Bool) -> String {
    let c = condition.lowercased()
    // Thunder
    if c.contains("thunder")                              { return "cloud.bolt.rain.fill" }
    // Snow
    if c.contains("blizzard")                             { return "wind.snow" }
    if c.contains("heavy snow")                           { return "wind.snow" }
    if c.contains("snow shower") || c.contains("snow showers") { return "cloud.snow.fill" }
    if c.contains("snow") && c.contains("sleet")          { return "cloud.sleet.fill" }
    if c.contains("snow") && c.contains("rain")           { return "cloud.sleet.fill" }
    if c.contains("snow")                                 { return "cloud.snow.fill" }
    if c.contains("flurr")                                { return "cloud.snow.fill" }
    if c.contains("sleet") || c.contains("freezing rain") { return "cloud.sleet.fill" }
    if c.contains("ice pellet")                           { return "cloud.sleet.fill" }
    // Rain
    if c.contains("heavy rain")                           { return "cloud.heavyrain.fill" }
    if c.contains("rain shower") || c.contains("shower")  { return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill" }
    if c.contains("rain") || c.contains("drizzle")        { return "cloud.rain.fill" }
    // Fog
    if c.contains("fog") || c.contains("mist")            { return "cloud.fog.fill" }
    // Wind-only
    if c.contains("breezy") || c.contains("windy")        { return "wind" }
    // Clear / sunny
    if c.contains("sunny") && c.contains("partly")        { return isDay ? "cloud.sun.fill" : "cloud.moon.fill" }
    if c.contains("sunny") && c.contains("mostly")        { return isDay ? "sun.max.fill" : "moon.stars.fill" }
    if c.contains("sunny")                                { return isDay ? "sun.max.fill" : "moon.stars.fill" }
    if c.contains("clear") && c.contains("mostly")        { return isDay ? "sun.max.fill" : "moon.stars.fill" }
    if c.contains("clear")                                { return isDay ? "sun.max.fill" : "moon.stars.fill" }
    // Cloud gradations
    if c.contains("overcast")                             { return "cloud.fill" }
    if c.contains("mostly cloudy")                        { return isDay ? "cloud.sun.fill" : "cloud.moon.fill" }
    if c.contains("partly cloudy")                        { return isDay ? "cloud.sun.fill" : "cloud.moon.fill" }
    if c.contains("cloudy")                               { return "cloud.fill" }
    // Haze / smoke
    if c.contains("haz") || c.contains("smoke") || c.contains("dust") { return "sun.haze.fill" }
    // Fallback to WMO symbol — condition was empty or unrecognised
    return ""
}

// MARK: - WMO helpers

func wmoDescription(code: Int, isDay: Bool) -> String {
    switch code {
    case 0:       return "Clear"
    case 1:       return "Mostly Clear"
    case 2:       return "Partly Cloudy"
    case 3:       return "Cloudy"
    case 45, 48:  return "Foggy"
    case 51:      return "Light Drizzle"
    case 53:      return "Drizzle"
    case 55:      return "Heavy Drizzle"
    case 56, 57:  return "Freezing Drizzle"
    case 61:      return "Light Rain"
    case 63:      return "Rain"
    case 65:      return "Heavy Rain"
    case 66, 67:  return "Freezing Rain"
    case 71:      return "Light Snow"
    case 73:      return "Snow"
    case 75:      return "Heavy Snow"
    case 77:      return "Snow Grains"
    case 80:      return "Light Showers"
    case 81:      return "Showers"
    case 82:      return "Heavy Showers"
    case 85:      return "Snow Showers"
    case 86:      return "Heavy Snow Showers"
    case 95:      return "Thunderstorm"
    case 96, 99:  return "Thunderstorm with Hail"
    default:      return "—"
    }
}

func wmoSFSymbol(code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1:    return isDay ? "sun.max.fill"         : "moon.stars.fill"
    case 2:       return isDay ? "cloud.sun.fill"       : "cloud.moon.fill"
    case 3:       return "cloud.fill"
    case 45, 48:  return "cloud.fog.fill"
    case 51, 53:  return "cloud.drizzle.fill"
    case 55:      return "cloud.heavyrain.fill"
    case 56, 57:  return "cloud.sleet.fill"
    case 61:      return "cloud.drizzle.fill"
    case 63:      return "cloud.rain.fill"
    case 65:      return "cloud.heavyrain.fill"
    case 66, 67:  return "cloud.sleet.fill"
    case 71, 73:  return "cloud.snow.fill"
    case 75:      return "wind.snow"
    case 77:      return "cloud.snow.fill"
    case 80:      return isDay ? "cloud.sun.rain.fill"  : "cloud.moon.rain.fill"
    case 81:      return "cloud.rain.fill"
    case 82:      return "cloud.heavyrain.fill"
    case 85, 86:  return "cloud.snow.fill"
    case 95:      return "cloud.bolt.rain.fill"
    case 96, 99:  return "cloud.bolt.rain.fill"
    default:      return isDay ? "sun.max.fill"         : "moon.fill"
    }
}

func wmoPrecipSymbol(code: Int) -> String {
    switch code {
    case 71...77, 85, 86: return "snowflake"
    case 95...99:         return "cloud.bolt.fill"
    default:              return "drop.fill"
    }
}

func compassDirection(from degrees: Double) -> String {
    let d = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return d[Int((degrees + 11.25) / 22.5) % 16]
}

func parseOMDate(_ s: String, utcOffset: Int) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    f.timeZone = TimeZone(secondsFromGMT: utcOffset)
    return f.date(from: s) ?? Date()
}

func parseOMDay(_ s: String, utcOffset: Int) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(secondsFromGMT: utcOffset)
    return f.date(from: s) ?? Date()
}
