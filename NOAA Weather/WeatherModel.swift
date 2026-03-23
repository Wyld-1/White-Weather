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

    let shortForecast: String       // NOAA condition label or WMO fallback
    let dayProse: String
    let nightProse: String
    let accumulation: AccumulationRange  // (.none when no accumulation — show temp bar)

    let precipType: PrecipType      // drives drop vs snowflake icon
    let isNightSevere: Bool         // drives dual symbol display

    let daySymbol: String
    let nightSymbol: String?        // only set when isNightSevere

    let hourlyTemps: [HourlyForecast]
}

struct CurrentConditions {
    let temperature: Double
    let description: String  // NOAA condition string if available, else WMO
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

// MARK: - Open-Meteo DTOs
// Fields are non-optional where the API always returns them.
// Optional only where the field may genuinely be absent (e.g. precipitation on clear days).

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
            case time, weatherCode = "weather_code", isDay = "is_day"
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m = "wind_speed_10m"
            case windGusts10m = "wind_gusts_10m"
            case windDirection10m = "wind_direction_10m"
        }
    }

    struct HourlyBlock: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Int]
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code"
            case temperature2m = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
        }
    }

    struct DailyBlock: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double?]   // nullable — API returns null at forecast boundary
        let temperature2mMin: [Double?]
        let precipitationProbabilityMax: [Int?]
        let sunrise: [String]
        let sunset: [String]
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code", sunrise, sunset
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }
}

// MARK: - Weather Repository (Orchestrator)

actor WeatherRepository {
    static let shared = WeatherRepository()

    // Returns weather data
    func fetchAll(lat: Double, lon: Double) async throws -> (
        CurrentConditions, [DailyForecast], SunEvent, [String: NOAAScraper.ScrapedPeriod]
    ) {
        // Fetch Open-Meteo and NOAA concurrently. NOAA is best-effort.
        async let omTask   = OpenMeteoClient.shared.fetch(lat: lat, lon: lon)
        async let noaaTask = NOAAScraper.shared.fetchProse(lat: lat, lon: lon)

        let om   = try await omTask
        let noaa = (try? await noaaTask) ?? [:]

        // utcOffsetSeconds from Open-Meteo is the local offset when timezone=auto
        let offset = om.utcOffsetSeconds
        let tz     = TimeZone(secondsFromGMT: offset) ?? .current

        // Current conditions
        let todayFmtKey: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
            return f.string(from: Date())
        }()
        
        // --- FALLBACK LOGIC FOR MISSING "TODAY" ---
        let noaaToday = noaa[todayFmtKey]
        let dayCond = noaaToday?.dayCondition ?? ""
        let nightCond = noaaToday?.nightCondition ?? ""
        
        // Use night condition if day is missing (standard for late afternoon)
        let effectiveTodayCondition = !dayCond.isEmpty ? dayCond : nightCond
        
        let c = om.current
        let descriptionLabel = effectiveTodayCondition.isEmpty
            ? wmoDescription(code: c.weatherCode, isDay: c.isDay == 1)
            : extractConditionLabel(from: effectiveTodayCondition)

        let current = CurrentConditions(
            temperature:        c.temperature2m,
            description:        descriptionLabel,
            windSpeed:          c.windSpeed10m,
            windGusts:          c.windGusts10m,
            windDirection:      c.windDirection10m,
            windDirectionLabel: compassDirection(from: c.windDirection10m),
            humidity:           c.relativeHumidity2m,
            weatherCode:        c.weatherCode,
            isDay:              c.isDay == 1
        )

        // Hourly — use local timezone for parsing
        let hourlyFmt = localDateFormatter(format: "yyyy-MM-dd'T'HH:mm", tz: tz)
        let allHourly: [HourlyForecast] = om.hourly.time.enumerated().compactMap { i, timeStr in
            guard let date = hourlyFmt.date(from: timeStr) else { return nil }
            return HourlyForecast(
                time: date,
                temperature: om.hourly.temperature2m[i],
                weatherCode: om.hourly.weatherCode[i],
                precipitationProbability: om.hourly.precipitationProbability[i]
            )
        }

        // Daily Parsing with Prose Fallback
        let dayFmt = localDateFormatter(format: "yyyy-MM-dd", tz: tz)
        let sunFmt = localDateFormatter(format: "yyyy-MM-dd'T'HH:mm", tz: tz)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz

        var dailyModels: [DailyForecast] = []
        for i in 0..<om.daily.time.count {
            let dateStr = om.daily.time[i]
            guard let date = dayFmt.date(from: dateStr),
                  let high = om.daily.temperature2mMax[i],
                  let low  = om.daily.temperature2mMin[i] else { continue }

            let noaaData = noaa[dateStr]
            
            // If today's day prose is missing, use tonight's prose as the main text
            let effectiveDayProse = (i == 0 && (noaaData?.dayProse ?? "").isEmpty)
                ? (noaaData?.nightProse ?? "Forecast unavailable")
                : (noaaData?.dayProse ?? "")
                
            let effectiveDayCond = (i == 0 && (noaaData?.dayCondition ?? "").isEmpty)
                ? (noaaData?.nightCondition ?? "")
                : (noaaData?.dayCondition ?? "")

            let daySymbol = noaaSFSymbol(condition: effectiveDayCond, isDay: i == 0 ? current.isDay : true)
                         ?? wmoSFSymbol(code: om.daily.weatherCode[i], isDay: true)

            let nightSymbol: String? = noaaData?.isNightSevere == true
                ? (noaaSFSymbol(condition: noaaData?.nightCondition ?? "", isDay: false) ?? "cloud.moon.fill")
                : nil

            dailyModels.append(DailyForecast(
                id:              UUID(),
                date:            date,
                high:            high,
                low:             low,
                precipProbability: noaaData?.precipChance ?? (om.daily.precipitationProbabilityMax[i] ?? 0),
                shortForecast:   extractConditionLabel(from: !effectiveDayCond.isEmpty ? effectiveDayCond : wmoDescription(code: om.daily.weatherCode[i], isDay: true)),
                dayProse:        effectiveDayProse,
                nightProse:      noaaData?.nightProse ?? "",
                accumulation:    noaaData?.accumulation ?? .none,
                precipType:      noaaData?.precipType ?? .none,
                isNightSevere:   noaaData?.isNightSevere ?? false,
                daySymbol:       daySymbol,
                nightSymbol:     nightSymbol,
                hourlyTemps:     allHourly.filter { cal.isDate($0.time, inSameDayAs: date) }
            ))
        }

        // Sunrise/sunset — parse with local timezone
        let sunrise = sunFmt.date(from: om.daily.sunrise.first ?? "") ?? Date()
        let sunset  = sunFmt.date(from: om.daily.sunset.first  ?? "") ?? Date()
        let sun = SunEvent(sunrise: sunrise, sunset: sunset)

        return (current, dailyModels, sun, noaa)
    }

    // Returns an appropriate night SF Symbol based on precip type when severity is flagged.
    private func nightSFSymbol(for type: PrecipType) -> String {
        switch type {
        case .snow, .mixed: return "cloud.snow.fill"
        case .rain:         return "cloud.rain.fill"
        case .none:         return "cloud.bolt.rain.fill"  // severe but unclear — thunder default
        }
    }

    private func localDateFormatter(format: String, tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = tz
        return f
    }
}

// MARK: - NOAA Scraper

actor NOAAScraper {
    static let shared = NOAAScraper()

    struct ScrapedPeriod {
        let condition: String       // day condition string ("Partly Sunny")
        let dayProse: String
        let nightProse: String
        let dayCondition: String    // tombstone condition for day
        let nightCondition: String  // tombstone condition for night
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

        // Scrape tombstone condition strings ("Partly Sunny", "Chance Snow Showers", etc.)
        // These come from the 7-day icon strip: <div class="tombstone-container"> <img title="..."> <p class="period-name">
        var tombstoneConditions: [String: String] = [:]  // periodName → condition
        for stone in try doc.select("div.tombstone-container") {
            let name      = (try? stone.select("p.period-name").first()?.text()) ?? ""
            let condition = (try? stone.select("img").first()?.attr("title")) ?? ""
            if !name.isEmpty && !condition.isEmpty {
                tombstoneConditions[name.lowercased()] = condition
            }
        }

        // Collect day/night prose from detailed forecast table
        struct RawDay {
            var dayLabel: String = ""
            var dayText:  String = ""
            var nightText: String = ""
            var dayCondition: String = ""   // from tombstone
            var nightCondition: String = "" // from tombstone
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
            if raw[key] == nil {
                raw[key] = RawDay()
                orderedKeys.append(key)
            }

            // Match label to tombstone condition ("Monday Night" → "monday night")
            let tombstone = tombstoneConditions[lower] ?? ""

            if isNight {
                raw[key]!.nightText      = text
                raw[key]!.nightCondition = tombstone
            } else {
                raw[key]!.dayLabel     = label
                raw[key]!.dayText      = text
                raw[key]!.dayCondition = tombstone
            }

            if let chance = extractPrecipChance(from: text), raw[key]!.precipChance == nil {
                raw[key]!.precipChance = chance
            }
        }

        var result: [String: ScrapedPeriod] = [:]
        for key in orderedKeys {
            guard let day = raw[key] else { continue }

            let dayAccum = regexAccumRangeIsolated(from: day.dayText)
            let nightAccum = regexAccumRangeIsolated(from: day.nightText)
            let totalAccumulation = await dayAccum + nightAccum

            let combined = day.dayText + " " + day.nightText

            let precipType = await PrecipType.from(
                dayCondition:   day.dayCondition,
                nightCondition: day.nightCondition,
                prose:          combined
            )

            let isNightSevere = conditionsAreNightSevere(
                day:   day.dayCondition,
                night: day.nightCondition
            )

            result[key] = ScrapedPeriod(
                condition: day.dayCondition.isEmpty ? day.dayLabel : day.dayCondition,
                dayProse: day.dayText,
                nightProse: day.nightText,
                dayCondition: day.dayCondition,
                nightCondition: day.nightCondition,
                accumulation: totalAccumulation, // Summed value
                precipType: precipType,
                isNightSevere: isNightSevere,
                precipChance: day.precipChance
            )
        }
        return result
    }

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private func extractPrecipChance(from text: String) -> Int? {
        let pattern = "Chance of precipitation is ([0-9]+)%"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    // Regex-based accumulation extraction. Only fires on snow/accumulation triggers.
    private func regexAccumRangeIsolated(from text: String) -> AccumulationRange {
        let lower = text.lowercased()

        // Must contain a snow/accumulation trigger to proceed
        let snowTriggers = ["snow", "accumulation", "flurr", "blizzard", "wintry mix", "sleet"]
        guard snowTriggers.contains(where: { lower.contains($0) }) else { return .none }

        // "less than" / "under" patterns — upper bound only.
        // Check fractional English phrases first (most specific), then numeric.
        let lessThanQuarterPhrases = ["less than a quarter", "under a quarter", "less than 0.25"]
        let lessThanHalfPhrases    = ["less than a half", "less than half an", "under a half",
                                      "less than half inch", "less than 0.5", "under 0.5"]
        let lessThanThreeQtrPhrases = ["less than three quarter", "less than 0.75", "under three quarter"]
        let lessThanOnePhrases     = ["less than one inch", "less than an inch", "less than 1 inch",
                                      "under one inch", "under an inch"]

        if lessThanQuarterPhrases.contains(where: { lower.contains($0) }) {
            return AccumulationRange(low: nil, high: 0.25)
        }
        if lessThanHalfPhrases.contains(where: { lower.contains($0) }) {
            return AccumulationRange(low: nil, high: 0.5)
        }
        if lessThanThreeQtrPhrases.contains(where: { lower.contains($0) }) {
            return AccumulationRange(low: nil, high: 0.75)
        }
        if lessThanOnePhrases.contains(where: { lower.contains($0) }) {
            return AccumulationRange(low: nil, high: 1.0)
        }
        // "less than X inch" with a numeric value
        if let match = firstRegexMatch("(?:less than|under) ([0-9]+(?:\\.[0-9]+)?) inch", in: text),
           let hi = Double(match) {
            return AccumulationRange(low: nil, high: hi)
        }

        // "up to X inches"
        if let match = firstRegexMatch("up to ([0-9]+(?:\\.[0-9]+)?) inch", in: text),
           let hi = Double(match) {
            return AccumulationRange(low: nil, high: hi)
        }

        // "around X" / "about X" / "near X" inches
        if let match = firstRegexMatch("(?:around|about|near) ([0-9]+(?:\\.[0-9]+)?) inch", in: text),
           let v = Double(match) {
            return AccumulationRange(low: v, high: v)
        }

        // "X to Y inches" — standard range
        if let match = firstRegexMatch(
            "([0-9]+(?:\\.[0-9]+)?)\\s+to\\s+([0-9]+(?:\\.[0-9]+)?)\\s+inch",
            in: text, groupCount: 2) {
            let parts = match.components(separatedBy: "|")
            if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) {
                return AccumulationRange(low: lo, high: hi)
            }
        }

        // "X inch" — single value
        if let match = firstRegexMatch("([0-9]+(?:\\.[0-9]+)?)\\s+inch", in: text),
           let v = Double(match) {
            return AccumulationRange(low: v, high: v)
        }

        return .none
    }

    // Returns first capture group(s) from a regex match.
    // If groupCount > 1, returns "group1|group2" joined by pipe.
    private func firstRegexMatch(_ pattern: String, in text: String, groupCount: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        if groupCount == 1 {
            let r = match.range(at: 1)
            guard r.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: r)
        } else {
            var parts: [String] = []
            for g in 1...groupCount {
                let r = match.range(at: g)
                guard r.location != NSNotFound else { return nil }
                parts.append((text as NSString).substring(with: r))
            }
            return parts.joined(separator: "|")
        }
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
            .init(name: "current",  value: "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,is_day"),
            .init(name: "hourly",   value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily",    value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset")
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }
}

// MARK: - Weather Category (for isNightSevere comparison)

enum WeatherCategory: Hashable {
    case clear        // sunny, clear, fair, mostly sunny
    case partlyCloudy // partly sunny, partly cloudy, mostly cloudy
    case cloudy       // overcast, cloudy
    case fog
    case drizzle      // light rain, drizzle
    case rain         // rain, showers, heavy rain
    case snow         // snow, flurries, sleet, wintry mix
    case storm        // thunderstorm
}

// Classify a NOAA condition string into a broad weather category.
nonisolated func weatherCategory(from condition: String) -> WeatherCategory {
    let c = condition.lowercased()
    // Handle "X then Y" — dominant part is after "then"
    let part = c.components(separatedBy: " then ").last ?? c
    if part.contains("thunder") || part.contains("tstm")                  { return .storm }
    if part.contains("blizzard") || part.contains("heavy snow")            { return .snow }
    if part.contains("snow") || part.contains("flurr") || part.contains("sleet") ||
       part.contains("wintry mix")                                         { return .snow }
    if part.contains("heavy rain") || part.contains("shower")             { return .rain }
    if part.contains("rain")                                               { return .rain }
    if part.contains("drizzle")                                            { return .drizzle }
    if part.contains("fog") || part.contains("mist")                      { return .fog }
    if part.contains("overcast") || part.contains("cloudy")               { return .cloudy }
    if part.contains("partly sunny") || part.contains("partly cloudy") ||
       part.contains("mostly cloudy")                                      { return .partlyCloudy }
    return .clear  // sunny, mostly sunny, clear, fair, or unknown
}

// True when day and night conditions are notably different.
// Symmetric: heavy snow day + clear night is just as notable as clear day + heavy snow night.
// Extracts the short condition label from any NOAA string.
// Works on both tombstone conditions ("Mostly Sunny") and prose
// ("This Afternoon: Mostly sunny, with a high near 42...").
// Always returns title-cased, e.g. "Mostly Sunny".
nonisolated func extractConditionLabel(from text: String) -> String {
    guard !text.isEmpty else { return text }

    // Strip period-name prefix: "Monday: ", "This Afternoon: ", "Tonight: ", etc.
    var working = text
    if let colonRange = working.range(of: ": ") {
        let prefix = String(working[working.startIndex..<colonRange.lowerBound])
        // Only strip if the prefix is 1–2 words — NOAA period labels are "Tonight",
        // "Monday", "Monday Night", "This Afternoon". Never a weather description.
        if prefix.split(separator: " ").count <= 2 {
            working = String(working[colonRange.upperBound...])
        }
    }

    // Take everything before the first comma or period — that's the condition
    let sentence = working
        .components(separatedBy: CharacterSet(charactersIn: ",."))
        .first ?? working
    let trimmed = sentence.trimmingCharacters(in: .whitespaces)

    // Title-case it
    return trimmed
        .split(separator: " ")
        .map { word -> String in
            // Keep small words lowercase unless they're the first word
            let w = String(word)
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

nonisolated func conditionsAreNightSevere(day: String, night: String) -> Bool {
    guard !night.isEmpty else { return false }
    let d = weatherCategory(from: day)
    let n = weatherCategory(from: night)
    guard d != n else { return false }

    // Table of pairs that are worth showing a dual symbol.
    // Order doesn't matter — we check both directions.
    let severePairs: Set<[WeatherCategory]> = [
        [.clear,        .storm],
        [.clear,        .snow],
        [.clear,        .rain],
        [.clear,        .fog],
        [.partlyCloudy, .storm],
        [.partlyCloudy, .snow],
        [.cloudy,       .storm],
        [.cloudy,       .snow],
        [.drizzle,      .storm],
        [.drizzle,      .snow],
        [.rain,         .snow],
        [.rain,         .storm],
        [.snow,         .storm],
        [.snow,         .clear],      // heavy snow day, clear night
        [.storm,        .clear],      // thunderstorm day, clear night
    ]
    return severePairs.contains([d, n].sorted(by: { "\($0)" < "\($1)" }))
        || severePairs.contains([n, d].sorted(by: { "\($0)" < "\($1)" }))
}

// MARK: - WMO Helpers

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
    case 0, 1:    return isDay ? "sun.max.fill"        : "moon.stars.fill"
    case 2:       return isDay ? "cloud.sun.fill"      : "cloud.moon.fill"
    case 3:       return "cloud.fill"
    case 45, 48:  return "cloud.fog.fill"
    case 51...65: return "cloud.rain.fill"
    case 71...77: return "cloud.snow.fill"
    case 80...82: return "cloud.heavyrain.fill"
    case 95...99: return "cloud.bolt.rain.fill"
    default:      return isDay ? "cloud.sun.fill"      : "cloud.moon.fill"
    }
}

nonisolated func compassDirection(from degrees: Double) -> String {
    let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return dirs[Int((degrees + 11.25) / 22.5) % 16]
}
