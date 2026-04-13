/* WeatherModel.swift
 * Whiteout Weather
 *
 * Domain models, data fetching, and parsing pipeline.
 * Data flows: Open-Meteo (numeric) + NOAA (prose/tombstones) → domain models.
 * Both sources are fetched concurrently; NOAA is best-effort and degrades to WMO.
 */

import Foundation
import SwiftSoup

// MARK: - Domain Models

struct HourlyForecast: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let shortForecast: String       // NOAA condition string, e.g. "Mostly Cloudy", "Rain And Snow Likely"
    let precipitationProbability: Int
    let isDay: Bool                 // true when this hour is daylight at the forecast location
    let resolvedSymbol: String?

    init(time: Date, temperature: Double, shortForecast: String,
         precipitationProbability: Int, isDay: Bool, resolvedSymbol: String? = nil) {
        self.time = time
        self.temperature = temperature
        self.shortForecast = shortForecast
        self.precipitationProbability = precipitationProbability
        self.isDay = isDay
        self.resolvedSymbol = resolvedSymbol
    }
}

/* Rich per-hour data from NOAA's digital forecast table (FcstType=digital).
 * This is the ground truth for hourly conditions — quantitative, per-type,
 * sourced directly from the NWS gridded model output.
 * Keyed by (date string "yyyy-MM-dd", localHour 0-23).
 */
struct NOAAHourlyTableEntry {
    let date: Date              // start of this hour, in the location's local timezone
    let localHour: Int          // 0-23, local time

    // Temperature & moisture
    let temperatureF: Double
    let dewpointF: Double?
    let humidity: Int?          // relative humidity %
    let windChill: Double?      // °F, nil when above ~50°F

    // Wind
    let windSpeedMph: Int?
    let windDirection: String?  // "N", "SW", etc.
    let windGustMph: Int?       // nil when no gusts forecast

    // Sky & general precip
    let skyCoverPct: Int        // 0-100
    let precipPotentialPct: Int // overall precip probability 0-100

    // Precip type probabilities — stored as raw percentages
    // Derived from NOAA bucket strings: --=0, SChc=20, Chc=35, Lkly=65, Def=85
    let rainPct: Int
    let thunderPct: Int
    let snowPct: Int
    let freezingRainPct: Int
    let sleetPct: Int

    /* Derives the best SF symbol for this hour from quantitative table data.
     * Priority order matches meteorological severity, not alphabetical.
     * isDay comes from the table entry itself (solar position at forecast time).
     */
    func sfSymbol(isDay: Bool) -> String {
        // Mixed: snow and meaningful rain simultaneously
        if snowPct >= 30 && rainPct >= 30  { return "cloud.sleet.fill" }
        // Sleet / freezing rain
        if sleetPct >= 20 || freezingRainPct >= 20 { return "cloud.sleet.fill" }
        // Thunder
        if thunderPct >= 20 { return rainPct >= 20 ? "cloud.bolt.rain.fill" : "cloud.bolt.fill" }
        // Pure snow
        if snowPct >= 65   { return "cloud.snow.fill" }
        if snowPct >= 20   { return "cloud.snow.fill" }
        // Rain intensity
        if rainPct >= 65   { return skyCoverPct >= 80 ? "cloud.heavyrain.fill" : "cloud.rain.fill" }
        if rainPct >= 30   { return skyCoverPct >= 70 ? "cloud.rain.fill" : (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill") }
        // Sky cover only
        if skyCoverPct < 20 { return isDay ? "sun.max.fill"    : "moon.stars.fill" }
        if skyCoverPct < 55 { return isDay ? "cloud.sun.fill"  : "cloud.moon.fill" }
        if skyCoverPct < 80 { return "cloud.fill" }
        return "cloud.fill"
    }

    /* Derives a shortForecast condition string for backward compat with noaaSFSymbol callers. */
    var shortForecast: String {
        if snowPct >= 30 && rainPct >= 30  { return "Rain And Snow" }
        if sleetPct >= 20 { return "Sleet" }
        if freezingRainPct >= 20 { return "Freezing Rain" }
        if thunderPct >= 20 { return "Thunderstorm" }
        if snowPct >= 65   { return "Snow" }
        if snowPct >= 20   { return "Chance Snow" }
        if rainPct >= 65   { return "Rain" }
        if rainPct >= 20   { return "Chance of Rain" }
        if skyCoverPct < 10 { return "Clear" }
        if skyCoverPct < 30 { return "Mostly Clear" }
        if skyCoverPct < 55 { return "Partly Cloudy" }
        if skyCoverPct < 80 { return "Mostly Cloudy" }
        return "Cloudy"
    }
}

/* A single calendar day in the 7-day forecast. */
struct DailyForecast: Identifiable {
    let id: UUID
    let date: Date
    let high: Double
    let low: Double
    let precipProbability: Int
    let shortForecast: String   // extracted condition label, e.g. "Mostly Sunny"
    let dayProse: String        // full NOAA day period text
    let nightProse: String      // full NOAA night period text
    let accumulation: AccumulationRange
    let precipType: PrecipType
    let isNightSevere: Bool     // day and night conditions are notably different
    let daySymbol: String       // SF symbol for the day period
    let nightSymbol: String?    // SF symbol for the night period — set whenever night prose exists
    let rowNightSymbol: String? // night symbol shown in the 7-day row — only set when isNightSevere
    let hourlyTemps: [HourlyForecast]
}

struct CurrentConditions {
    let temperature: Double
    let description: String     // NOAA condition label if available, otherwise WMO description
    let windSpeed: Double       // NOAA prose average, or OM fallback — shown in Wind row
    let windGusts: Double       // NOAA prose gust, or OM fallback — shown in Gusts row
    let windSpeedInstant: Double // OM current instantaneous — shown in compass center
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
            case weatherCode        = "weather_code"
            case isDay              = "is_day"
            case temperature2m      = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m       = "wind_speed_10m"
            case windGusts10m       = "wind_gusts_10m"
            case windDirection10m   = "wind_direction_10m"
        }
    }

    struct HourlyBlock: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Int]
        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode              = "weather_code"
            case temperature2m            = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
        }
    }

    struct DailyBlock: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double?]          // nullable at forecast boundary
        let temperature2mMin: [Double?]
        let precipitationProbabilityMax: [Int?]
        let sunrise: [String]
        let sunset: [String]
        enum CodingKeys: String, CodingKey {
            case time, weatherCode = "weather_code", sunrise, sunset
            case temperature2mMax            = "temperature_2m_max"
            case temperature2mMin            = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }
}

// MARK: - Weather Repository

/* Orchestrates concurrent fetches from Open-Meteo and NOAAScraper,
 * then assembles the full domain model set.
 *
 * NOAA data enriches the Open-Meteo baseline; if NOAA fails, all fields
 * fall back to WMO codes with graceful degradation.
 */
actor WeatherRepository {
    static let shared = WeatherRepository()

    /* Fetches all weather data for a coordinate.
     *
     * @param lat latitude
     * @param lon longitude
     * @return (current conditions, 7-day forecast, all hourly data, sun events, raw scraped periods)
     * @throws if the Open-Meteo fetch fails (NOAA failure is non-fatal)
     */
    func fetchAll(lat: Double, lon: Double) async throws -> (
        CurrentConditions, [DailyForecast], [HourlyForecast], SunEvent, [String: NOAAScraper.ScrapedPeriod], Int, [NWSAlert], [NOAAHourlyTableEntry]
    ) {
        // Phase 1: OM + alerts + NOAA prose all run concurrently.
        // These are the fast fetches — OM and alerts are JSON APIs,
        // prose scrape is one HTML page. Together ~1-2s.
        async let omFetch     = OpenMeteoClient.shared.fetch(lat: lat, lon: lon)
        async let alertsFetch = NWSAlertClient.shared.fetchAlerts(lat: lat, lon: lon)

        let om     = try await omFetch
        let alerts = await alertsFetch
        let tz     = TimeZone(secondsFromGMT: om.utcOffsetSeconds) ?? .current

        let noaa = (try? await NOAAScraper.shared.fetchProse(lat: lat, lon: lon, tz: tz)) ?? [:]

        let current  = buildCurrentConditions(om: om, noaa: noaa, tz: tz)
        // Phase 1 hourly: full OM hourly array (all days) as warm-start data.
        // buildDaily uses this to populate hourlyTemps for all 7 days.
        let omHourly = buildHourly(om: om, tz: tz)
        let (daily, sun) = buildDaily(om: om, noaa: noaa, allHourly: omHourly, tz: tz, current: current)

        return (current, daily, omHourly, sun, noaa, om.utcOffsetSeconds, alerts, [])
    }

    /* Phase 2: fetch the digital table and return enriched hourly data.
     * Called by WeatherViewModel after phase 1 has already rendered the page.
     * Returns nil on failure — caller keeps phase 1 data unchanged.
     */
    func fetchTable(lat: Double, lon: Double, tz: TimeZone) async -> [NOAAHourlyTableEntry]? {
        await NOAADigitalTableScraper.shared.fetchTable(lat: lat, lon: lon, tz: tz)
    }

    /* Builds current conditions, preferring the NOAA tombstone label over the WMO description.
     * Applies unit conversions from AppSettings before returning, so all callers get display-ready values.
     */
    private func buildCurrentConditions(
        om: OpenMeteoResponse,
        noaa: [String: NOAAScraper.ScrapedPeriod],
        tz: TimeZone
    ) -> CurrentConditions {
        let todayData = noaa[dateString(from: Date(), tz: tz)]

        // Temperature: prefer the NOAA station observation (same sensor network NOAA
        // uses for its own page display); fall back to Open-Meteo.
        let temperature = todayData?.currentTempF ?? om.current.temperature2m

        // Condition label: prefer the short station label (e.g. "Rain"), then the
        // day/night tombstone condition, then WMO description.
        let stationLabel = todayData?.currentCondition ?? ""
        let tombstoneLabel = [todayData?.dayCondition, todayData?.nightCondition]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let description: String
        if !stationLabel.isEmpty {
            description = stationLabel
        } else if !tombstoneLabel.isEmpty {
            description = extractConditionLabel(from: tombstoneLabel)
        } else {
            description = wmoDescription(code: om.current.weatherCode, isDay: om.current.isDay == 1)
        }

        let c = om.current
        // Wind: prefer NOAA prose extraction (day prose first, then night) so that
        // "East wind around 8 mph, with gusts as high as 20 mph" overrides OM.
        // Fall back to OM values when NOAA prose is absent or unparseable.
        let proseSources = [todayData?.dayProse ?? "", todayData?.nightProse ?? ""]
        let noaaWindSpeed = proseSources.compactMap { extractWindSpeedFromProse($0) }.first
        let noaaWindGust  = proseSources.compactMap { extractWindGustFromProse($0) }.first
        return CurrentConditions(
            temperature:        temperature,
            description:        description,
            windSpeed:          noaaWindSpeed ?? c.windSpeed10m,
            windGusts:          noaaWindGust  ?? c.windGusts10m,
            windSpeedInstant:   c.windSpeed10m,
            windDirection:      c.windDirection10m,
            windDirectionLabel: compassDirection(from: c.windDirection10m),
            humidity:           c.relativeHumidity2m,
            weatherCode:        c.weatherCode,
            isDay:              c.isDay == 1
        )
    }

    /* Builds a full HourlyForecast array from Open-Meteo data covering all forecast days.
     * Used as phase-1 warm data and as fallback when the table fails.
     */
    private func buildHourly(om: OpenMeteoResponse, tz: TimeZone) -> [HourlyForecast] {
        let fmt = localDateFormatter(format: "yyyy-MM-dd'T'HH:mm", tz: tz)
        return om.hourly.time.enumerated().compactMap { i, str in
            guard let date = fmt.date(from: str) else { return nil }
            let h = Calendar.current.component(.hour, from: date)
            let isDay = h >= 6 && h < 20
            return HourlyForecast(
                time:                     date,
                temperature:              om.hourly.temperature2m[i],
                shortForecast:            wmoDescription(code: om.hourly.weatherCode[i], isDay: isDay),
                precipitationProbability: om.hourly.precipitationProbability[i],
                isDay:                    isDay
            )
        }
    }

    /* Builds the 7-day DailyForecast array and the SunEvent for today.
     *
     * SF symbol resolution priority: NOAA tombstone → extracted prose label → WMO code.
     * Tombstones are only available for days 1–5; days 6–7 fall through to prose extraction.
     */
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
            guard let date = dayFmt.date(from: dateStr),
                  let high = om.daily.temperature2mMax[i],
                  let low  = om.daily.temperature2mMin[i] else { continue }

            let noaaData   = noaa[dateStr]
            let wmoCode    = om.daily.weatherCode[i]
            let isToday    = i == 0

            // If today's day prose is absent (late afternoon), use tonight's
            let dayProse = (isToday && (noaaData?.dayProse ?? "").isEmpty)
                ? (noaaData?.nightProse ?? "") : (noaaData?.dayProse ?? "")
            let dayCond  = (isToday && (noaaData?.dayCondition ?? "").isEmpty)
                ? (noaaData?.nightCondition ?? "") : (noaaData?.dayCondition ?? "")

            // Prefer NOAA prose temperatures — more accurate than OM for the displayed location.
            // High comes from the day prose, low from the night prose.
            // Fall back to OM if the prose doesn’t contain the pattern (near/around/of).
            let resolvedHigh: Double = extractHighTemp(from: noaaData?.dayProse ?? "") ?? high
            let resolvedLow:  Double = extractLowTemp(from: noaaData?.nightProse ?? "") ?? low

            // daySymbol always resolves with isDay:true — it represents the daytime
            // period regardless of when the app is viewed.
            let isCurrentlyDay = true
            let daySymbol: String = {
                if !dayCond.isEmpty {
                    return noaaSFSymbol(condition: dayCond, isDay: isCurrentlyDay)
                        ?? wmoSFSymbol(code: wmoCode, isDay: isCurrentlyDay)
                }
                if !dayProse.isEmpty {
                    return noaaSFSymbol(condition: extractConditionLabel(from: dayProse), isDay: isCurrentlyDay)
                        ?? wmoSFSymbol(code: wmoCode, isDay: isCurrentlyDay)
                }
                return wmoSFSymbol(code: wmoCode, isDay: isCurrentlyDay)
            }()

            let nightCond  = noaaData?.nightCondition ?? ""
            let nightProse = noaaData?.nightProse ?? ""
            let nightSymbolResolved: String? = {
                if !nightCond.isEmpty {
                    return noaaSFSymbol(condition: nightCond, isDay: false) ?? "cloud.moon.fill"
                }
                if !nightProse.isEmpty {
                    return noaaSFSymbol(condition: extractConditionLabel(from: nightProse), isDay: false)
                        ?? "moon.stars.fill"
                }
                return nil
            }()
            // nightSymbol: always set when night prose exists, so the DayDetailPage
            // night prose card always shows the correct resolved night symbol.
            let nightSymbol: String? = nightSymbolResolved
            // rowNightSymbol: only shown in the 7-day row when conditions are
            // dramatically different — guards against cluttering routine clear→clear days.
            let nightIsSevere = conditionsAreNightSevere(day: dayCond, night: nightCond)
            let rowNightSymbol: String? = nightIsSevere ? nightSymbolResolved : nil
            let condLabel = !dayCond.isEmpty ? dayCond : wmoDescription(code: wmoCode, isDay: true)

            days.append(DailyForecast(
                id:               UUID(),
                date:             date,
                high:             resolvedHigh,
                low:              resolvedLow,
                precipProbability: noaaData?.precipChance ?? 0,
                shortForecast:    extractConditionLabel(from: condLabel),
                dayProse:         dayProse,
                nightProse:       noaaData?.nightProse ?? "",
                accumulation:     noaaData?.accumulation ?? .none,
                precipType:       noaaData?.precipType ?? .none,
                isNightSevere:    noaaData?.isNightSevere ?? false,
                daySymbol:        daySymbol,
                nightSymbol:      nightSymbol,
                rowNightSymbol:   rowNightSymbol,
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

/* Fetches and parses forecast.weather.gov for a given coordinate.
 * Returns a dictionary keyed by "yyyy-MM-dd" date strings.
 * Tombstone conditions are only available for the first ~5 periods;
 * later periods rely on prose extraction for symbols.
 */
actor NOAAScraper {
    static let shared = NOAAScraper()

    struct ScrapedPeriod {
        let condition: String       // extracted display condition, e.g. "Partly Sunny"
        let dayProse: String
        let nightProse: String
        let dayCondition: String    // tombstone condition for the day period
        let nightCondition: String  // tombstone condition for the night period
        let accumulation: AccumulationRange
        let precipType: PrecipType
        let isNightSevere: Bool
        let precipChance: Int?
        // Observed current conditions from the NOAA station block (today only).
        // nil when the page has no current-conditions panel (future days, failed scrape).
        let currentCondition: String?   // e.g. "Rain"
        let currentTempF: Double?        // observed station temp in °F
    }

    /* Fetches and parses the NOAA forecast page for the given coordinate.
     *
     * @param lat latitude
     * @param lon longitude
     * @return dictionary of date key → ScrapedPeriod, or empty on parse failure
     */
    /* @param tz  the location's timezone (from Open-Meteo utcOffsetSeconds).
     *             Used to seed the date cursor so "today" is correct for the
     *             location, not the device running the app.
     */
    func fetchProse(lat: Double, lon: Double, tz: TimeZone = .current) async throws -> [String: ScrapedPeriod] {
        let url = URL(string: "https://forecast.weather.gov/MapClick.php?lat=\(lat)&lon=\(lon)")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return [:] }

        let doc = try SwiftSoup.parse(html)
        let tombstones = try scrapeTombstones(doc)
        let (currentCondition, currentTempF) = scrapeCurrentConditions(doc)
        return try buildPeriods(doc, tombstones: tombstones, tz: tz,
                                currentCondition: currentCondition, currentTempF: currentTempF)
    }

    /* Scrapes the "Current Conditions" station block at the top of the NOAA forecast page.
     * Returns the short condition label (e.g. "Rain") and the observed temperature in °F.
     * Both are nil when the block is absent or unparseable.
     *
     * Confirmed selectors (verified via telemetry):
     *   p.myforecast-current      -> condition string, e.g. "light rain,mist" (take before comma)
     *   p.myforecast-current-lrg  -> imperial temp, e.g. "49°F"
     *   p.myforecast-current-sm   -> metric temp, e.g. "9°C" (ignored)
     */
    private func scrapeCurrentConditions(_ doc: Document) -> (String?, Double?) {
        // Condition: take the text before the first comma, title-case each word.
        // "light rain,mist" -> "Light Rain"
        let conditionRaw = (try? doc.select("p.myforecast-current").first()?.text())
            .flatMap { $0.isEmpty ? nil : $0 }
        let condition: String? = conditionRaw.map { raw in
            let segment = raw.split(separator: ",").first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
            return segment.split(separator: " ")
                .map { w in String(w.prefix(1)).uppercased() + String(w.dropFirst()).lowercased() }
                .joined(separator: " ")
        }

        // Temperature: p.myforecast-current-lrg holds the imperial value, e.g. "49°F".
        let tempString = (try? doc.select("p.myforecast-current-lrg").first()?.text()) ?? ""
        let digits = tempString.components(
            separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "-.")).inverted
        ).joined()
        let tempF = Double(digits).flatMap { v in
            (-60.0...140.0).contains(v) ? v : nil
        }

        return (condition, tempF)
    }

    /* Scrapes the 7-day tombstone icon strip for period names and condition titles.
     * Returns a lowercased period name → condition string map.
     */
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

    /* Parses the detailed forecast table into RawDay structs keyed by date,
     * then builds the final ScrapedPeriod map.
     */
    private func buildPeriods(_ doc: Document, tombstones: [String: String], tz: TimeZone = .current,
                               currentCondition: String? = nil, currentTempF: Double? = nil) throws -> [String: ScrapedPeriod] {
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
        // Lock calendar and formatters to the location's timezone so that
        // "today" and day-name comparison use the location's local date.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        var cursor = cal.startOfDay(for: Date())
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE"; dayFmt.timeZone = tz

        for row in try doc.select("#detailed-forecast-body .row-forecast") {
            let label   = (try? row.select(".forecast-label").text()) ?? ""
            let text    = (try? row.select(".forecast-text").text()) ?? ""
            let lower   = label.lowercased()
            let isNight = lower.contains("night") || lower == "tonight"

            if !isNight {
                let expected = dayFmt.string(from: cursor).lowercased()
                let isToday  = lower.contains("today") || lower.contains("this afternoon") || lower.contains("this morning")
                if !isToday && !lower.contains(expected) {
                    cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                }
            }

            let key = dateKey(cursor, tz: tz)
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

        let todayKey = dateKey(cal.startOfDay(for: Date()), tz: tz)

        var result: [String: ScrapedPeriod] = [:]
        for key in orderedKeys {
            guard let day = raw[key] else { continue }
            let combined = day.dayText + " " + day.nightText
            // Attach the scraped station observation only to today's entry.
            let isToday = key == todayKey
            result[key] = ScrapedPeriod(
                condition:        day.dayCondition.isEmpty ? day.dayLabel : day.dayCondition,
                dayProse:         day.dayText,
                nightProse:       day.nightText,
                dayCondition:     day.dayCondition,
                nightCondition:   day.nightCondition,
                accumulation:     extractAccumulationRange(from: day.dayText) + extractAccumulationRange(from: day.nightText),
                precipType:       PrecipType.from(dayCondition: day.dayCondition, nightCondition: day.nightCondition, prose: combined),
                isNightSevere:    conditionsAreNightSevere(day: day.dayCondition, night: day.nightCondition),
                precipChance:     day.precipChance,
                currentCondition: isToday ? currentCondition : nil,
                currentTempF:     isToday ? currentTempF     : nil
            )
        }
        return result
    }

    private func dateKey(_ date: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz; return f.string(from: date)
    }

    /* Extracts a precipitation probability percentage from NOAA prose.
     * Handles "A 20 percent chance of rain", "40% chance of snow", "Chance of precipitation is 60%".
     *
     * @return percentage as Int, or nil if not found
     */
    private func extractPrecipChance(from text: String) -> Int? {
        let pattern = "([0-9]+)\\s*(?:%|percent)\\s+chance|chance of [a-z ]+ is ([0-9]+)(?:%|\\s*percent)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for i in 1...2 {
            let r = match.range(at: i)
            if r.location != NSNotFound, let range = Range(r, in: text) { return Int(text[range]) }
        }
        return nil
    }

    /* Extracts an accumulation range from NOAA prose using ordered regex patterns.
     * Only fires when snow/ice trigger words are present; returns .none otherwise.
     *
     * @param text  prose text for a single day or night period
     * @return AccumulationRange with bounds in inches
     */
    private func extractAccumulationRange(from text: String) -> AccumulationRange {
        let lower = text.lowercased()
        let triggers = ["snow", "accumulation", "flurr", "blizzard", "wintry mix", "sleet"]
        guard triggers.contains(where: { lower.contains($0) }) else { return .none }

        // "Less than" English fraction phrases, most specific first
        if ["less than a quarter", "under a quarter", "less than 0.25"].contains(where: { lower.contains($0) })          { return AccumulationRange(low: nil, high: 0.25) }
        if ["less than a half", "less than half an", "under a half", "less than half inch", "less than 0.5", "under 0.5"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: nil, high: 0.5) }
        if ["less than three quarter", "less than 0.75", "under three quarter"].contains(where: { lower.contains($0) })  { return AccumulationRange(low: nil, high: 0.75) }
        if ["less than one inch", "less than an inch", "less than 1 inch", "under one inch", "under an inch"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: nil, high: 1.0) }

        if let hi = regexFirstCapture("(?:less than|under) ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init) { return AccumulationRange(low: nil, high: hi) }
        if let hi = regexFirstCapture("up to ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init)               { return AccumulationRange(low: nil, high: hi) }
        if ["around an inch", "around one inch", "about an inch", "near an inch"].contains(where: { lower.contains($0) }) { return AccumulationRange(low: 1.0, high: 1.0) }
        if let v = regexFirstCapture("(?:around|about|near) ([0-9]+(?:\\.[0-9]+)?) inch", in: text).flatMap(Double.init) { return AccumulationRange(low: v, high: v) }

        if let pair = regexFirstCapture("([0-9]+(?:\\.[0-9]+)?)\\s+to\\s+([0-9]+(?:\\.[0-9]+)?)\\s+inch", in: text, groups: 2) {
            let parts = pair.components(separatedBy: "|")
            if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) { return AccumulationRange(low: lo, high: hi) }
        }

        if let v = regexFirstCapture("([0-9]+(?:\\.[0-9]+)?)\\s+inch", in: text).flatMap(Double.init) { return AccumulationRange(low: v, high: v) }
        return .none
    }

    /* Returns the first regex capture group as a string, or all groups joined by "|" when groups > 1.
     *
     * @param pattern  NSRegularExpression pattern with capture groups
     * @param text     input string
     * @param groups   number of capture groups to return (default 1)
     * @return captured string(s) or nil on no match
     */
    private func regexFirstCapture(_ pattern: String, in text: String, groups: Int = 1) -> String? {
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

/* Fetches the Open-Meteo forecast API for a coordinate.
 * Returns temperatures in °F and wind in mph. Timezone is auto-detected.
 */
actor OpenMeteoClient {
    static let shared = OpenMeteoClient()

    /* @param lat latitude
     * @param lon longitude
     * @return decoded OpenMeteoResponse
     * @throws on network or decode failure
     */
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

// MARK: - NOAA Digital Table Scraper

/* Scrapes the NOAA hourly digital forecast table (FcstType=digital).
 * This is richer than any API — quantitative per-hour values for sky cover,
 * precip type probabilities, humidity, dewpoint, wind, and gusts.
 * Returns nil on failure so callers fall back to the NOAA hourly API or OM.
 *
 * HTML structure observed 2026-04:
 *   Rows are <tr> elements. The first <td> in each row is the element label.
 *   Subsequent <td> elements are hourly values, one per column.
 *   Date and hour headers are in separate <tr> rows with class patterns.
 *   Two 24-hour blocks are rendered per page (48 hours total).
 */
actor NOAADigitalTableScraper {
    static let shared = NOAADigitalTableScraper()

    func fetchTable(lat: Double, lon: Double, tz: TimeZone) async -> [NOAAHourlyTableEntry]? {
        let latStr = String(format: "%.4f", lat)
        let lonStr = String(format: "%.4f", lon)
        guard let url = URL(string:
            "https://forecast.weather.gov/MapClick.php?lat=\(latStr)&lon=\(lonStr)&FcstType=digital"
        ) else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8)
        else {
            print("[Phase2] columnDates.isEmpty — bailing")
            return nil
        }

        return parse(html: html, tz: tz)
    }

    // MARK: - Parser

    private func parse(html: String, tz: TimeZone) -> [NOAAHourlyTableEntry]? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        
        // Skip table lookup — NOAA's malformed HTML causes SwiftSoup to miscount rows.
        // The data rows are uniquely identifiable: exactly 25 <td> cells each.
        let allRows = (try? doc.select("tr").array()) ?? []
        let rows = allRows.filter { row in
            let cells = (try? row.select("td").array()) ?? []
            return cells.count == 25
        }
        guard !rows.isEmpty else { return nil }

        // Build the timeline: parse date+hour header rows to get a Date for each column.
        // The table has two 24-column blocks separated by a date/hour header row.
        var columnDates: [Date] = []
        var rawRows: [String: [String]] = [:] // label → column values
        var currentDates: [Date] = []
        var pendingHours: [Int] = []
        var pendingDate: String = ""

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = tz

        for row in rows {
            guard let cells = try? row.select("td").array(), !cells.isEmpty else { continue }
            let firstText = (try? cells[0].text()) ?? ""

            // Date header row: contains strings like "04/11"
            if firstText == "Date" || firstText.contains("Date") {
                // extract MM/DD values from subsequent cells
                pendingDate = ""
                for cell in cells.dropFirst() {
                    let t = ((try? cell.text()) ?? "").trimmingCharacters(in: .whitespaces)
                    if t.count == 5 && t.contains("/") {
                        pendingDate = t
                        break  // take the first date, not the last
                    }
                }
                continue
            }

            // Hour header row: contains integers 0-23
            if firstText == "Hour (PDT)" || firstText.contains("Hour (") {
                pendingHours = []
                for cell in cells.dropFirst() {
                    if let h = Int((try? cell.text()) ?? "") {
                        pendingHours.append(h)
                    }
                }
                // Now build dates from pendingDate + pendingHours
                if !pendingDate.isEmpty && !pendingHours.isEmpty {
                    let parts = pendingDate.split(separator: "/")
                    if parts.count == 2,
                       let month = Int(parts[0]),
                       let day   = Int(parts[1]) {
                        let year = cal.component(.year, from: Date())
                        var currentDay = day
                        var lastHour = -1
                        for h in pendingHours {
                            if lastHour >= 0 && h < lastHour { currentDay += 1 }
                            lastHour = h
                            var comps = DateComponents()
                            comps.year = year; comps.month = month; comps.day = currentDay; comps.hour = h
                            comps.minute = 0; comps.second = 0
                            if let d = cal.date(from: comps) {
                                currentDates.append(d)
                            }
                        }
                    }
                    columnDates.append(contentsOf: currentDates)
                    currentDates = []
                }
                continue
            }

            // Data row: first cell is the element label, rest are values
            let label = firstText.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let values = cells.dropFirst().map { (try? $0.text()) ?? "" }
            rawRows[label] = (rawRows[label] ?? []) + values
        }

        guard !columnDates.isEmpty else { return nil }

        // Helper: safe index into a values array
        func val(_ key: String, _ i: Int) -> String {
            guard let arr = rawRows[key], i < arr.count else { return "" }
            return arr[i].trimmingCharacters(in: .whitespaces)
        }
        func intVal(_ key: String, _ i: Int) -> Int? { Int(val(key, i)) }
        func dblVal(_ key: String, _ i: Int) -> Double? { Double(val(key, i)) }

        // Convert NOAA probability bucket string to a percentage
        func pct(_ s: String) -> Int {
            switch s.trimmingCharacters(in: .whitespaces) {
            case "--", "": return 0
            case "SChc":   return 20
            case "Chc":    return 35
            case "Lkly":   return 65
            case "Def":    return 85
            default:       return Int(s) ?? 0  // sometimes raw %
            }
        }

        // Map row label variants to canonical keys
        // (the exact label text varies slightly by region/season)
        func find(_ candidates: [String]) -> String? {
            candidates.first { rawRows[$0] != nil }
        }

        let tempKey    = find(["Temperature (°F)", "Temperature (°F)", "Temperature"]) ?? ""
        let dewKey     = find(["Dewpoint (°F)", "Dewpoint (°F)", "Dewpoint"]) ?? ""
        let wcKey      = find(["Wind Chill (°F)", "Wind Chill (°F)", "Wind Chill"]) ?? ""
        let wsKey      = find(["Surface Wind (mph)", "Surface Wind"]) ?? ""
        let wdKey      = find(["Wind Dir", "Wind Direction"]) ?? ""
        let wgKey      = find(["Gust", "Wind Gust"]) ?? ""
        let skyKey     = find(["Sky Cover (%)", "Sky Cover"]) ?? ""
        let ppKey      = find(["Precipitation Potential (%)", "Precipitation Potential"]) ?? ""
        let rhKey      = find(["Relative Humidity (%)", "Relative Humidity"]) ?? ""
        let rainKey    = find(["Rain"]) ?? ""
        let tstmKey    = find(["Thunder", "Thunderstorm"]) ?? ""
        let snowKey    = find(["Snow"]) ?? ""
        let fzraKey    = find(["Freezing Rain"]) ?? ""
        let sleetKey   = find(["Sleet"]) ?? ""

        var entries: [NOAAHourlyTableEntry] = []
        for (i, date) in columnDates.enumerated() {
            guard let tempF = dblVal(tempKey, i) else { continue }
            let lh = cal.component(.hour, from: date)
            entries.append(NOAAHourlyTableEntry(
                date:             date,
                localHour:        lh,
                temperatureF:     tempF,
                dewpointF:        dblVal(dewKey, i),
                humidity:         intVal(rhKey, i),
                windChill:        dblVal(wcKey, i),
                windSpeedMph:     intVal(wsKey, i),
                windDirection:    val(wdKey, i).isEmpty ? nil : val(wdKey, i),
                windGustMph:      val(wgKey, i) == "--" || val(wgKey, i).isEmpty ? nil : intVal(wgKey, i),
                skyCoverPct:      intVal(skyKey, i) ?? 0,
                precipPotentialPct: intVal(ppKey, i) ?? 0,
                rainPct:          pct(val(rainKey, i)),
                thunderPct:       pct(val(tstmKey, i)),
                snowPct:          pct(val(snowKey, i)),
                freezingRainPct:  pct(val(fzraKey, i)),
                sleetPct:         pct(val(sleetKey, i))
            ))
        }
        return entries.isEmpty ? nil : entries
    }
}

// MARK: - Hourly Table Conversion

/* Converts a NOAAHourlyTableEntry array into HourlyForecast.
 * Free function (nonisolated) — no actor hop needed, pure transformation.
 * sunrise/sunset give accurate day/night per hour; falls back to clock hour.
 */
func buildHourlyFromTable(
    _ table: [NOAAHourlyTableEntry],
    sunrise: Date? = nil,
    sunset: Date? = nil
) -> [HourlyForecast] {
    table.map { entry in
        let isDay: Bool
        if let rise = sunrise, let set = sunset {
            isDay = entry.date >= rise && entry.date < set
        } else {
            isDay = entry.localHour >= 6 && entry.localHour < 20
        }
        return HourlyForecast(
            time:                     entry.date,
            temperature:              entry.temperatureF,
            shortForecast:            entry.shortForecast,
            precipitationProbability: entry.precipPotentialPct,
            isDay:                    isDay,
            resolvedSymbol:           entry.sfSymbol(isDay: isDay)
        )
    }
}

// MARK: - Weather Category

/* Broad sky/precipitation category used for isNightSevere comparison.
 * Not used for display — see PrecipType and noaaSFSymbol for that.
 */
enum WeatherCategory: Hashable {
    case clear, mostlyClear, partlyCloudy, cloudy, fog, drizzle, rain, snow, storm
}

/* Classifies a NOAA condition string into a WeatherCategory.
 * Uses the post-"then" segment for transitional conditions like "Chance Snow then Mostly Sunny".
 */
nonisolated func weatherCategory(from condition: String) -> WeatherCategory {
    let c = condition.lowercased().components(separatedBy: " then ").last ?? condition.lowercased()
    if c.contains("thunder") || c.contains("tstm")                              { return .storm }
    if c.contains("blizzard") || c.contains("heavy snow") || c.contains("snow") ||
       c.contains("flurr") || c.contains("sleet") || c.contains("wintry mix")    { return .snow }
    if c.contains("heavy rain") || c.contains("shower") || c.contains("rain")    { return .rain }
    if c.contains("drizzle")                                                      { return .drizzle }
    if c.contains("fog") || c.contains("mist")                                   { return .fog }
    if c.contains("mostly cloudy") || c.contains("overcast") ||
       c.contains("considerable cloudiness")                                      { return .cloudy }
    if c.contains("partly sunny") || c.contains("partly cloudy")                 { return .partlyCloudy }
    if c.contains("mostly sunny") || c.contains("mostly clear")                  { return .mostlyClear }
    return .clear
}

/* Returns true when day and night conditions are dramatically different in a way
 * worth surfacing to the user — e.g. sunny day + thunderstorm night.
 * Only flags genuine surprises; clear→mostlyClear or partlyCloudy→cloudy are not severe.
 *
 * @param day   tombstone condition string for the day period
 * @param night tombstone condition string for the night period
 */
nonisolated func conditionsAreNightSevere(day: String, night: String) -> Bool {
    guard !day.isEmpty, !night.isEmpty else { return false }
    let d = weatherCategory(from: day)
    let n = weatherCategory(from: night)
    guard d != n else { return false }

    // Only flag pairs where the night condition would genuinely surprise someone
    // who only saw the day forecast. Minor sky-cover shifts (clear↔mostlyClear,
    // partlyCloudy↔cloudy) are not worth a dual icon.
    let severePairs: Set<Set<WeatherCategory>> = [
        // Precipitation appearing at night after a clear/partly-cloudy day
        [.clear,        .storm],
        [.clear,        .snow],
        [.clear,        .rain],
        [.clear,        .fog],
        [.mostlyClear,  .storm],
        [.mostlyClear,  .snow],
        [.mostlyClear,  .rain],
        [.partlyCloudy, .storm],
        [.partlyCloudy, .snow],
        [.cloudy,       .storm],
        [.cloudy,       .snow],
        // Mixed precipitation shifts
        [.drizzle,      .storm],
        [.drizzle,      .snow],
        [.rain,         .snow],
        [.rain,         .storm],
        // Dramatic clearing overnight (e.g. thunderstorm day → clear night)
        [.storm,        .clear],
        [.storm,        .mostlyClear],
        [.snow,         .clear],
        [.snow,         .mostlyClear],
    ]
    return severePairs.contains([d, n])
}

// MARK: - NOAA Temperature Extraction

/* Extracts a high temperature from a NOAA day-period prose string.
 * Handles: "high near 31", "high around 38", "high of 29", "near 31" (when "high" is implicit).
 * Returns nil when no match is found so the caller can fall back to Open-Meteo.
 *
 * @param text  NOAA day-period prose, e.g. "Sunny, with a high near 31."
 * @return temperature in °F as Double, or nil
 */
nonisolated func extractHighTemp(from text: String) -> Double? {
    // Patterns: "high near 31", "high around 38", "high of 29", "highs near 31"
    let pattern = "high[s]?\\s+(?:near|around|of)\\s+(-?[0-9]+(?:\\.[0-9]+)?)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.range(at: 1).location != NSNotFound,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Double(text[range])
}

/* Extracts a low temperature from a NOAA night-period prose string.
 * Handles: "low around 15", "low near 19", "low of 12", "lows near 23".
 * Returns nil when no match is found so the caller can fall back to Open-Meteo.
 *
 * @param text  NOAA night-period prose, e.g. "Partly cloudy, with a low around 15."
 * @return temperature in °F as Double, or nil
 */
nonisolated func extractLowTemp(from text: String) -> Double? {
    let pattern = "low[s]?\\s+(?:near|around|of)\\s+(-?[0-9]+(?:\\.[0-9]+)?)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.range(at: 1).location != NSNotFound,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Double(text[range])
}

// MARK: - NOAA Wind Extraction

/* Extracts sustained wind speed in mph from NOAA prose.
 * Handles patterns like:
 *   "East wind around 8 mph"         → 8
 *   "North wind 10 to 15 mph"        → 12.5 (midpoint)
 *   "winds up to 20 mph"             → 20
 *   "Breezy, with a west wind 15 to 25 mph" → 20
 * Returns nil when no match is found so the caller can fall back to Open-Meteo.
 */
nonisolated func extractWindSpeedFromProse(_ text: String) -> Double? {
    let t = text
    // Range pattern: "10 to 15 mph" → midpoint
    let rangePattern = "([0-9]+)\\s+to\\s+([0-9]+)\\s+mph"
    if let regex = try? NSRegularExpression(pattern: rangePattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
       match.range(at: 1).location != NSNotFound,
       match.range(at: 2).location != NSNotFound,
       let r1 = Range(match.range(at: 1), in: t),
       let r2 = Range(match.range(at: 2), in: t),
       let lo = Double(t[r1]), let hi = Double(t[r2]) {
        return (lo + hi) / 2
    }
    // Single value: "around 8 mph", "up to 20 mph", "near 15 mph", "15 mph"
    let singlePattern = "(?:around|near|up to|about)?\\s*([0-9]+)\\s+mph"
    if let regex = try? NSRegularExpression(pattern: singlePattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
       match.range(at: 1).location != NSNotFound,
       let r = Range(match.range(at: 1), in: t) {
        return Double(t[r])
    }
    return nil
}

/* Extracts wind gust speed in mph from NOAA prose.
 * Handles patterns like:
 *   "with gusts as high as 20 mph"   → 20
 *   "gusts up to 35 mph"             → 35
 *   "gusts to 25 mph"                → 25
 * Returns nil when no match is found so the caller can fall back to Open-Meteo.
 */
nonisolated func extractWindGustFromProse(_ text: String) -> Double? {
    let pattern = "gust[s]?\\s+(?:as high as|up to|to|of|near|around)?\\s*([0-9]+)\\s+mph"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.range(at: 1).location != NSNotFound,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Double(text[range])
}

// MARK: - Condition Label Extraction

/* Extracts a short condition label from any NOAA string.
 * Works on both tombstone strings ("Mostly Sunny") and full prose
 * ("Tonight: Mostly clear, with a low around 23. East wind...").
 * Always returns title-cased output, e.g. "Mostly Clear".
 *
 * @param text  any NOAA condition or prose string
 * @return short title-cased condition label
 */
nonisolated func extractConditionLabel(from text: String) -> String {
    guard !text.isEmpty else { return text }
    var working = text

    if let range = working.lowercased().range(of: "otherwise, ") {
        working = String(working[range.upperBound...])
    }

    // Strip period-name prefix: "Tonight: ", "Monday: " (≤2 words before the colon)
    if let colonRange = working.range(of: ": ") {
        let prefix = String(working[..<colonRange.lowerBound])
        if prefix.split(separator: " ").count <= 2 {
            working = String(working[colonRange.upperBound...])
        }
    }

    working = working.components(separatedBy: ",").first ?? working

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

/* Returns a human-readable description for an Open-Meteo WMO weather code. */
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

/* Returns an SF symbol name for an Open-Meteo WMO weather code.
 * Used as a fallback when no NOAA condition string is available.
 */
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

/* Converts a wind direction in degrees to a cardinal/intercardinal compass label. */
nonisolated func compassDirection(from degrees: Double) -> String {
    let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return dirs[Int((degrees + 11.25) / 22.5) % 16]
}
