// WeatherModel.swift
// White Weather

import Foundation
import SwiftSoup

// MARK: - Domain Models

struct HourlyForecast: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int
}

struct DailyForecast: Identifiable {
    let id: UUID
    let date: Date
    let high: Double
    let low: Double
    let precipProbability: Int
    let shortForecast: String      // e.g. "Mostly Sunny", "Chance Snow Showers"
    let dayProse: String           // Full NOAA day period text
    let nightProse: String         // Full NOAA night period text
    let accumulation: AccumulationRange
    let precipType: PrecipType
    let isNightSevere: Bool        // Day and night conditions are notably different
    let daySymbol: String          // SF symbol for the day period
    let nightSymbol: String?       // SF symbol for night — only set when isNightSevere
    let hourlyTemps: [HourlyForecast]
}

struct CurrentConditions {
    let temperature: Double
    let description: String        // NOAA condition string if available, else WMO
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
    var nextTime: Date  { Date() < sunrise ? sunrise : sunset }
}

// MARK: - Open-Meteo Response DTOs

struct OpenMeteoResponse: Decodable, Sendable {
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
            case weatherCode      = "weather_code"
            case isDay            = "is_day"
            case temperature2m    = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m     = "wind_speed_10m"
            case windGusts10m     = "wind_gusts_10m"
            case windDirection10m = "wind_direction_10m"
        }
    }

    struct HourlyBlock: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Int]
        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode             = "weather_code"
            case temperature2m           = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
        }
    }

    struct DailyBlock: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double?]         // nullable at forecast boundary
        let temperature2mMin: [Double?]
        let precipitationProbabilityMax: [Int?]
        let sunrise: [String]
        let sunset: [String]
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code", sunrise, sunset
            case temperature2mMax           = "temperature_2m_max"
            case temperature2mMin           = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }
}

// MARK: - Weather Repository

actor WeatherRepository {
    static let shared = WeatherRepository()

    func fetchAll(lat: Double, lon: Double) async throws -> (
        CurrentConditions, [DailyForecast], [HourlyForecast], SunEvent, [String: NOAAScraper.ScrapedPeriod]
    ) {
        async let omFetch   = OpenMeteoClient.shared.fetch(lat: lat, lon: lon)
        async let noaaFetch = NOAAScraper.shared.fetchProse(lat: lat, lon: lon)

        let om   = try await omFetch
        let noaa = (try? await noaaFetch) ?? [:]
        let tz   = TimeZone(secondsFromGMT: om.utcOffsetSeconds) ?? .current

        let current  = buildCurrentConditions(om: om, noaa: noaa, tz: tz)
        let allHourly = buildHourly(om: om, tz: tz)
        let (daily, sun) = buildDaily(om: om, noaa: noaa, allHourly: allHourly, tz: tz, current: current)

        return (current, daily, allHourly, sun, noaa)
    }

    private func buildCurrentConditions(
        om: OpenMeteoResponse,
        noaa: [String: NOAAScraper.ScrapedPeriod],
        tz: TimeZone
    ) -> CurrentConditions {
        let todayKey = dateString(from: Date(), tz: tz)
        let todayData = noaa[todayKey]

        // Prefer day condition; fall back to tonight's if it's already afternoon
        let condition = [todayData?.dayCondition, todayData?.nightCondition]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? ""

        let c = om.current
        return CurrentConditions(
            temperature:        c.temperature2m,
            description:        condition.isEmpty
                                    ? wmoDescription(code: c.weatherCode, isDay: c.isDay == 1)
                                    : extractConditionLabel(from: condition),
            windSpeed:          c.windSpeed10m,
            windGusts:          c.windGusts10m,
            windDirection:      c.windDirection10m,
            windDirectionLabel: compassDirection(from: c.windDirection10m),
            humidity:           c.relativeHumidity2m,
            weatherCode:        c.weatherCode,
            isDay:              c.isDay == 1
        )
    }

    private func buildHourly(om: OpenMeteoResponse, tz: TimeZone) -> [HourlyForecast] {
        let fmt = localDateFormatter(format: "yyyy-MM-dd'T'HH:mm", tz: tz)
        return om.hourly.time.enumerated().compactMap { i, str in
            guard let date = fmt.date(from: str) else { return nil }
            return HourlyForecast(
                time:                      date,
                temperature:               om.hourly.temperature2m[i],
                weatherCode:               om.hourly.weatherCode[i],
                precipitationProbability:  om.hourly.precipitationProbability[i]
            )
        }
    }

    private func buildDaily(
        om: OpenMeteoResponse,
        noaa: [String: NOAAScraper.ScrapedPeriod],
        allHourly: [HourlyForecast],
        tz: TimeZone,
        current: CurrentConditions
    ) -> ([DailyForecast], SunEvent) {
        let dayFmt = localDateFormatter(format: "yyyy-MM-dd", tz: tz)
        let sunFmt = localDateFormatter(format: "yyyy-MM-dd'T'HH:mm", tz: tz)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz

        var days: [DailyForecast] = []
        for i in 0..<om.daily.time.count {
            let dateStr = om.daily.time[i]
            guard let date  = dayFmt.date(from: dateStr),
                  let high  = om.daily.temperature2mMax[i],
                  let low   = om.daily.temperature2mMin[i] else { continue }

            let noaaData  = noaa[dateStr]
            let wmoCode   = om.daily.weatherCode[i]
            let isToday   = i == 0

            // If today's day prose is missing (late afternoon), use tonight's
            let dayProse  = (isToday && (noaaData?.dayProse ?? "").isEmpty)
                ? (noaaData?.nightProse ?? "") : (noaaData?.dayProse ?? "")
            let dayCond   = (isToday && (noaaData?.dayCondition ?? "").isEmpty)
                ? (noaaData?.nightCondition ?? "") : (noaaData?.dayCondition ?? "")

            let daySymbol = noaaSFSymbol(condition: dayCond, isDay: isToday ? current.isDay : true)
                         ?? wmoSFSymbol(code: wmoCode, isDay: true)

            let nightSymbol: String? = noaaData?.isNightSevere == true
                ? (noaaSFSymbol(condition: noaaData?.nightCondition ?? "", isDay: false) ?? "cloud.moon.fill")
                : nil

            let condLabel = !dayCond.isEmpty ? dayCond : wmoDescription(code: wmoCode, isDay: true)

            days.append(DailyForecast(
                id:               UUID(),
                date:             date,
                high:             high,
                low:              low,
                precipProbability: noaaData?.precipChance ?? 0,
                shortForecast:    extractConditionLabel(from: condLabel),
                dayProse:         dayProse,
                nightProse:       noaaData?.nightProse ?? "",
                accumulation:     noaaData?.accumulation ?? .none,
                precipType:       noaaData?.precipType ?? .none,
                isNightSevere:    noaaData?.isNightSevere ?? false,
                daySymbol:        daySymbol,
                nightSymbol:      nightSymbol,
                hourlyTemps:      allHourly.filter { cal.isDate($0.time, inSameDayAs: date) }
            ))
        }

        let sunrise = sunFmt.date(from: om.daily.sunrise.first ?? "") ?? Date()
        let sunset  = sunFmt.date(from: om.daily.sunset.first  ?? "") ?? Date()
        return (days, SunEvent(sunrise: sunrise, sunset: sunset))
    }

    private func dateString(from date: Date, tz: TimeZone) -> String {
        localDateFormatter(format: "yyyy-MM-dd", tz: tz).string(from: date)
    }

    private func localDateFormatter(format: String, tz: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; f.timeZone = tz; return f
    }
}

// MARK: - NOAA Scraper

actor NOAAScraper {
    static let shared = NOAAScraper()

    struct ScrapedPeriod {
        let condition: String       // display condition ("Partly Sunny")
        let dayProse: String
        let nightProse: String
        let dayCondition: String
        let nightCondition: String
        let accumulation: AccumulationRange
        let precipType: PrecipType
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
        let tombstones = try scrapeTombstones(doc)
        return try buildPeriods(doc, tombstones: tombstones)
    }

    // MARK: Scraping

    private func scrapeTombstones(_ doc: Document) throws -> [String: String] {
        var result: [String: String] = [:]
        for stone in try doc.select("div.tombstone-container") {
            let name      = (try? stone.select("p.period-name").first()?.text()) ?? ""
            let condition = (try? stone.select("img").first()?.attr("title")) ?? ""
            if !name.isEmpty && !condition.isEmpty {
                result[name.lowercased()] = condition
            }
        }
        return result
    }

    private func buildPeriods(_ doc: Document, tombstones: [String: String]) throws -> [String: ScrapedPeriod] {
        struct RawDay {
            var dayLabel: String = ""
            var dayText: String = ""
            var nightText: String = ""
            var dayCondition: String = ""
            var nightCondition: String = ""
            var precipChance: Int? = nil
        }

        var raw: [String: RawDay] = [:]
        var orderedKeys: [String] = []
        let cal = Calendar.current
        var cursor = cal.startOfDay(for: Date())
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE"

        for row in try doc.select("#detailed-forecast-body .row-forecast") {
            let label = (try? row.select(".forecast-label").text()) ?? ""
            let text  = (try? row.select(".forecast-text").text()) ?? ""
            let lower = label.lowercased()
            let isNight = lower.contains("night") || lower == "tonight"

            if !isNight {
                let expected = dayFmt.string(from: cursor).lowercased()
                let isToday  = lower.contains("today") || lower.contains("this afternoon") || lower.contains("this morning")
                if !isToday && !lower.contains(expected) {
                    cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                }
            }

            let key = dateKey(cursor)
            if raw[key] == nil { raw[key] = RawDay(); orderedKeys.append(key) }

            if isNight {
                raw[key]!.nightText      = text
                raw[key]!.nightCondition = tombstones[lower] ?? ""
            } else {
                raw[key]!.dayLabel     = label
                raw[key]!.dayText      = text
                raw[key]!.dayCondition = tombstones[lower] ?? ""
            }

            if let chance = extractPrecipChance(from: text), raw[key]!.precipChance == nil {
                raw[key]!.precipChance = chance
            }
        }

        var result: [String: ScrapedPeriod] = [:]
        for key in orderedKeys {
            guard let day = raw[key] else { continue }
            let combined = day.dayText + " " + day.nightText
            result[key] = ScrapedPeriod(
                condition:      day.dayCondition.isEmpty ? day.dayLabel : day.dayCondition,
                dayProse:       day.dayText,
                nightProse:     day.nightText,
                dayCondition:   day.dayCondition,
                nightCondition: day.nightCondition,
                accumulation:   regexAccumRangeIsolated(from: day.dayText) + regexAccumRangeIsolated(from: day.nightText),
                precipType:     PrecipType.from(dayCondition: day.dayCondition, nightCondition: day.nightCondition, prose: combined),
                isNightSevere:  conditionsAreNightSevere(day: day.dayCondition, night: day.nightCondition),
                precipChance:   day.precipChance
            )
        }
        return result
    }

    // MARK: Helpers

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private func extractPrecipChance(from text: String) -> Int? {
        // Matches: "A 20 percent chance of rain", "40% chance of snow", "Chance of precipitation is 60%"
        let pattern = "([0-9]+)\\s*(?:%|percent)\\s+chance|chance of [a-z ]+ is ([0-9]+)(?:%|\\s*percent)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for i in 1...2 {
            let r = match.range(at: i)
            if r.location != NSNotFound, let range = Range(r, in: text) { return Int(text[range]) }
        }
        return nil
    }

    // Accumulation regex — only fires when snow/ice trigger words are present.
    private func regexAccumRangeIsolated(from text: String) -> AccumulationRange {
        let lower = text.lowercased()
        let triggers = ["snow", "accumulation", "flurr", "blizzard", "wintry mix", "sleet"]
        guard triggers.contains(where: { lower.contains($0) }) else { return .none }

        // "Less than" fraction phrases — most specific first
        if ["less than a quarter", "under a quarter", "less than 0.25"].contains(where: { lower.contains($0) })          { return AccumulationRange(low: nil, high: 0.25) }
        if ["less than a half", "less than half an", "under a half", "less than half inch", "less than 0.5", "under 0.5"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: nil, high: 0.5) }
        if ["less than three quarter", "less than 0.75", "under three quarter"].contains(where: { lower.contains($0) })  { return AccumulationRange(low: nil, high: 0.75) }
        if ["less than one inch", "less than an inch", "less than 1 inch", "under one inch", "under an inch"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: nil, high: 1.0) }

        if let hi = firstMatch("(?:less than|under) ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init)         { return AccumulationRange(low: nil, high: hi) }
        if let hi = firstMatch("up to ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init)                       { return AccumulationRange(low: nil, high: hi) }
        if ["around an inch", "around one inch", "about an inch", "near an inch"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: 1.0, high: 1.0) }
        if let v  = firstMatch("(?:around|about|near) ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init)       { return AccumulationRange(low: v, high: v) }

        // "X to Y inches"
        if let pair = firstMatch("([0-9]+(?:\\.[0-9]+)?)\\s+to\\s+([0-9]+(?:\\.[0-9]+)?)\\s+inch", in: text, groups: 2) {
            let parts = pair.components(separatedBy: "|")
            if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) { return AccumulationRange(low: lo, high: hi) }
        }

        if let v  = firstMatch("([0-9]+(?:\\.[0-9]+)?)\\s+inch", in: text).flatMap(Double.init)                          { return AccumulationRange(low: v, high: v) }
        return .none
    }

    // Returns the first capture group, or "g1|g2|..." when groups > 1.
    private func firstMatch(_ pattern: String, in text: String, groups: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        if groups == 1 {
            let r = match.range(at: 1)
            guard r.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: r)
        }
        var parts: [String] = []
        for g in 1...groups {
            let r = match.range(at: g)
            guard r.location != NSNotFound else { return nil }
            parts.append((text as NSString).substring(with: r))
        }
        return parts.joined(separator: "|")
    }
}

// MARK: - Open-Meteo Client

actor OpenMeteoClient {
    static let shared = OpenMeteoClient()

    func fetch(lat: Double, lon: Double) async throws -> OpenMeteoResponse {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude",          value: "\(lat)"),
            .init(name: "longitude",         value: "\(lon)"),
            .init(name: "temperature_unit",  value: "fahrenheit"),
            .init(name: "wind_speed_unit",   value: "mph"),
            .init(name: "timezone",          value: "auto"),
            .init(name: "forecast_days",     value: "11"),
            .init(name: "current",           value: "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,is_day"),
            .init(name: "hourly",            value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily",             value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }
}

// MARK: - Weather Category

// Used to compare day vs. night conditions for isNightSevere.
enum WeatherCategory: Hashable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, storm
}

nonisolated func weatherCategory(from condition: String) -> WeatherCategory {
    let c = (condition.lowercased().components(separatedBy: " then ").last ?? condition.lowercased())
    if c.contains("thunder") || c.contains("tstm")                           { return .storm }
    if c.contains("blizzard") || c.contains("heavy snow") || c.contains("snow") ||
       c.contains("flurr") || c.contains("sleet") || c.contains("wintry mix") { return .snow }
    if c.contains("heavy rain") || c.contains("shower") || c.contains("rain") { return .rain }
    if c.contains("drizzle")                                                   { return .drizzle }
    if c.contains("fog") || c.contains("mist")                                { return .fog }
    if c.contains("overcast") || c.contains("cloudy")                         { return .cloudy }
    if c.contains("partly sunny") || c.contains("partly cloudy") ||
       c.contains("mostly cloudy")                                             { return .partlyCloudy }
    return .clear
}

nonisolated func conditionsAreNightSevere(day: String, night: String) -> Bool {
    guard !night.isEmpty else { return false }
    let d = weatherCategory(from: day)
    let n = weatherCategory(from: night)
    guard d != n else { return false }

    let severePairs: Set<Set<WeatherCategory>> = [
        [.clear, .storm], [.clear, .snow], [.clear, .rain], [.clear, .fog],
        [.partlyCloudy, .storm], [.partlyCloudy, .snow],
        [.cloudy, .storm], [.cloudy, .snow],
        [.drizzle, .storm], [.drizzle, .snow],
        [.rain, .snow], [.rain, .storm],
        [.snow, .storm], [.snow, .clear], [.storm, .clear],
    ]
    return severePairs.contains([d, n])
}

// MARK: - Condition String Helpers

// Extracts a short condition label from any NOAA string.
// Handles tombstone strings ("Mostly Sunny") and prose ("Tonight: Mostly clear, with a low...").
// Always returns title-cased output.
nonisolated func extractConditionLabel(from text: String) -> String {
    guard !text.isEmpty else { return text }
    var working = text

    // "Otherwise, mostly sunny" — use the "otherwise" clause
    if let range = working.lowercased().range(of: "otherwise, ") {
        working = String(working[range.upperBound...])
    }

    // Strip period prefix: "Tonight: ", "Monday: ", "This Afternoon: "
    if let colonRange = working.range(of: ": ") {
        let prefix = String(working[..<colonRange.lowerBound])
        if prefix.split(separator: " ").count <= 2 {
            working = String(working[colonRange.upperBound...])
        }
    }

    // Cut at the first comma — everything after is temps, wind, etc.
    working = working.components(separatedBy: ",").first ?? working

    // Cut at transitional phrases
    for keyword in [" becoming ", " then ", " before "] {
        if let range = working.lowercased().range(of: keyword) {
            working = String(working[..<range.lowerBound])
        }
    }

    return working.trimmingCharacters(in: .whitespaces)
        .split(separator: " ")
        .map { w in String(w).prefix(1).uppercased() + String(w).dropFirst().lowercased() }
        .joined(separator: " ")
}

// MARK: - WMO Code Helpers

nonisolated func wmoDescription(code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1:    return "Clear"
    case 2:       return "Partly Cloudy"
    case 3:       return "Cloudy"
    case 45, 48:  return "Fog"
    case 51...65: return "Rain"
    case 71...77: return "Snow"
    case 80...82: return "Showers"
    case 95...99: return "Thunderstorms"
    default:      return "Overcast"
    }
}

nonisolated func wmoSFSymbol(code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1:    return isDay ? "sun.max.fill"       : "moon.stars.fill"
    case 2:       return isDay ? "cloud.sun.fill"     : "cloud.moon.fill"
    case 3:       return "cloud.fill"
    case 45, 48:  return "cloud.fog.fill"
    case 51...65: return "cloud.rain.fill"
    case 71...77: return "cloud.snow.fill"
    case 80...82: return "cloud.heavyrain.fill"
    case 95...99: return "cloud.bolt.rain.fill"
    default:      return isDay ? "cloud.sun.fill"     : "cloud.moon.fill"
    }
}

nonisolated func compassDirection(from degrees: Double) -> String {
    let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return dirs[Int((degrees + 11.25) / 22.5) % 16]
}
