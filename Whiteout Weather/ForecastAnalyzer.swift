/* ForecastAnalyzer.swift
 * Whiteout Weather
 *
 * Pure Swift types for precipitation analysis and SF symbol resolution.
 */

import Foundation

// MARK: - PrecipType

/* Broad precipitation category for a forecast period.
 * Drives the icon choice (drop vs. snowflake) in the 7-day row.
 */
enum PrecipType {
    case snow, rain, mixed, none

    /* Derives the precip type from tombstone condition strings and prose.
     * Checks all three inputs combined so a "Chance Snow" day condition
     * with a "Rain Likely" night condition correctly returns .mixed.
     *
     * @param dayCondition   tombstone string for the day period
     * @param nightCondition tombstone string for the night period
     * @param prose          combined day + night prose text
     * @return the dominant precipitation type
     */
    static func from(dayCondition: String, nightCondition: String, prose: String) -> PrecipType {
        let text = (dayCondition + " " + nightCondition + " " + prose).lowercased()
        let hasSnow = text.contains("snow") || text.contains("flurr") ||
                      text.contains("blizzard") || text.contains("sleet") ||
                      text.contains("wintry mix")
        let hasRainShower = text.contains("shower") && !text.contains("snow shower")
        let hasRain = text.contains("rain") || hasRainShower || text.contains("drizzle")
        if hasSnow && hasRain { return .mixed }
        if hasSnow             { return .snow }
        if hasRain             { return .rain }
        return .none
    }
}

// MARK: - AccumulationRange

/* Numeric snow/rain accumulation bounds in inches.
 * A nil bound means the range is open on that side:
 *   low=nil, high=1.0  →  "less than 1 inch"
 *   low=2.0, high=nil  →  "more than 2 inches"
 *   low=2.0, high=4.0  →  "2 to 4 inches"
 * Display formatting lives here so callers only deal in numbers.
 */
struct AccumulationRange {
    let low: Double?
    let high: Double?

    var hasAccumulation: Bool { low != nil || high != nil }

    /* Returns a display string like "< 1\"", "2–4 cm", "> 3\"".
     * Values are raw inches; pass settings to apply unit conversion at display time.
     *
     * @param settings  AppSettings instance for live unit conversion (defaults to .shared)
     */
    func displayString(settings: AppSettings = .shared) -> String {
        let converted = settings.isMetric
            ? AccumulationRange(low: low.map { $0 * 2.54 }, high: high.map { $0 * 2.54 })
            : self
        let u = settings.accumUnit
        switch (converted.low, converted.high) {
        case (nil, nil):                    return ""
        case (nil, let h?):                 return "< \(fmt(h))\(u)"
        case (let l?, nil):                 return "> \(fmt(l))\(u)"
        case (let l?, let h?) where l == h: return "\(fmt(l))\(u)"
        case (let l?, let h?):              return "\(fmt(l))–\(fmt(h))\(u)"
        }
    }

    /* Formats a Double as an integer if whole, otherwise one decimal place. */
    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    /* Sums two ranges. Used to combine separate day and night accumulation. */
    static func + (lhs: AccumulationRange, rhs: AccumulationRange) -> AccumulationRange {
        if !lhs.hasAccumulation { return rhs }
        if !rhs.hasAccumulation { return lhs }
        let lo  = (lhs.low == nil && rhs.low == nil) ? nil : (lhs.low ?? 0) + (rhs.low ?? 0)
        let lHi = lhs.high ?? lhs.low ?? 0
        let rHi = rhs.high ?? rhs.low ?? 0
        return AccumulationRange(low: lo == 0 ? nil : lo, high: lHi + rHi)
    }

    static var none: AccumulationRange { AccumulationRange(low: nil, high: nil) }
}

// MARK: - SF Symbol Resolution

/* noaaSFSymbol(String, Bool) -> String?
*
* Resolves the most accurate SF symbol for a NOAA condition string.
 * Note: Callers fall back to wmoSFSymbol when noaaSFSymbol() returns nil.
*
* @param condition  NOAA condition string, tombstone or extracted label
* @param isDay      true for day periods, false for night
* @return           SF symbol name, or nil if the condition is unrecognised
*/

nonisolated func noaaSFSymbol(condition: String, isDay: Bool) -> String? {
    let c = condition.lowercased()
    guard !c.isEmpty else { return nil }

    // For "X then Y" tombstones, the post-"then" segment is the dominant afternoon state.
    let parts    = c.components(separatedBy: " then ")
    let dominant = parts.last ?? c

    func symbol(for s: String) -> String? {
        // Severe weather
        // Thunder only dominates when primary — not "also possible", "isolated", or "slight chance"
        let thunderIsPrimary = (s.contains("thunder") || s.contains("tstm"))
            && !s.contains("also possible")
            && !s.contains("isolated thunder")
            && !s.contains("slight chance of thunder")
        if thunderIsPrimary                                              { return "cloud.bolt.rain.fill" }
        if s.contains("blizzard") || s.contains("heavy snow")           { return "wind.snow" }
        if s.contains("blowing snow") || s.contains("drifting snow")    { return "wind.snow" }
        if s.contains("freezing rain") || s.contains("fzra")            { return "cloud.sleet.fill" }
        if s.contains("freezing drizzle") || s.contains("fzdz")         { return "cloud.sleet.fill" }
        if s.contains("sleet") || s.contains("ice pellet")              { return "cloud.sleet.fill" }
        if s.contains("wintry mix") || s.contains("rain/snow") ||
           s.contains("rain and snow") || s.contains("snow and rain")   { return "cloud.sleet.fill" }
        
        if s.contains("snow likely")                                    { return "snowflake" }

        // Sky condition checked before generic precipitation, so that
        // "Chance Snow. Partly Sunny" correctly returns the sky icon.
        if s.contains("partly sunny") || s.contains("partly cloudy")    { return isDay ? "cloud.sun.fill"   : "cloud.moon.fill" }
        if s.contains("mostly sunny") || s.contains("mostly clear")     { return isDay ? "sun.max.fill"     : "moon.stars.fill" }
        if s.contains("mostly cloudy") || s.contains("considerable cloudiness") { return "cloud.fill" }
        if s.contains("sunny") || s.contains("clear") || s.contains("fair") { return isDay ? "sun.max.fill" : "moon.stars.fill" }
        if s.contains("cloudy") || s.contains("overcast") ||
           s.contains("increasing clouds")                               { return "cloud.fill" }

        // Snow
        if s.contains("snow shower")                                     { return "snowflake" }
        if s.contains("flurr")                                           { return "snowflake" }
        if s.contains("snow")                                            { return "snowflake" }

        // Rain
        if s.contains("heavy rain")                                      { return "cloud.heavyrain.fill" }
        if s.contains("rain shower") || s.contains("shower")             { return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill" }
        if s.contains("drizzle")                                         { return "cloud.drizzle.fill" }
        if s.contains("rain")                                            { return "cloud.rain.fill" }

        // Atmosphere
        if s.contains("dense fog") || s.contains("patchy fog") || s.contains("fog") || s.contains("mist") { return "cloud.fog.fill" }
        if s.contains("haze") || s.contains("smoke") || s.contains("dust") { return isDay ? "sun.haze.fill" : "moon.haze.fill" }

        // Wind — only when it's the primary descriptor, not incidental forecast text
        if s.contains("breezy") || s.contains("windy") || s.contains("blustery") { return "wind" }

        return nil
    }

    return symbol(for: dominant) ?? (parts.count > 1 ? symbol(for: c) : nil)
}

// MARK: - ForecastBadge

/* Compact info nugget shown in the right side of DailyRow instead of temp bars.
 * Surfaces the most relevant conditions for the day at a glance.
 *
 * mainSymbols:   up to 3 SF symbols for primary day conditions (timeline or chance).
 *                The night severe symbol is included here, rendered monochromatically.
 * nightSymbol:   set when a night symbol is part of the main group (rendered monochrome).
 * chanceSymbols: secondary "chance of" or "also possible" symbols, shown right of a divider.
 *
 * Visual: [snow] [rain·night] | [thunder]
 */
struct ForecastBadge {
    let mainSymbols: [String]      // multicolor, up to 3
    let nightSymbol: String?       // which of mainSymbols is the night one (rendered monochrome)
    let chanceSymbols: [String]    // shown after a " | " divider

    var hasContent: Bool { !mainSymbols.isEmpty || !chanceSymbols.isEmpty }
}

// MARK: - ForecastBadge Extraction

/* Builds a ForecastBadge from NOAA prose, tombstone conditions, and the night symbol.
 *
 * Priority within mainSymbols:
 *  1. Timeline symbols ("then"-separated clauses), up to 3 distinct
 *  2. Chance symbols from prose when no timeline
 * Night symbol is appended to mainSymbols when isNightSevere.
 * Secondary thunder/hazard ("also possible") goes into chanceSymbols.
 *
 * @param prose         NOAA day-period prose
 * @param dayCond        tombstone condition for the day period
 * @param nightSymbol    resolved night SF symbol (from nightSymbolResolved)
 * @param isNightSevere  whether night conditions are notably different
 */
nonisolated func extractForecastBadge(
    from prose: String,
    dayCond: String,
    nightSymbol: String?,
    isNightSevere: Bool
) -> ForecastBadge? {
    var mainSymbols: [String] = []
    var nightSym: String? = nil
    var chanceSymbols: [String] = []

    let lower = prose.lowercased()

    // ── Step 1: Primary symbols from timeline or chance ──────────────────
    if lower.contains(" then ") {
        // Timeline: collect up to 3 distinct precip symbols from clauses
        let thenPattern = "[,.]?\\s+then\\s+"
        if let splitRegex = try? NSRegularExpression(pattern: thenPattern, options: .caseInsensitive) {
            let nsStr = prose as NSString
            let fullRange = NSRange(location: 0, length: nsStr.length)
            var splitRanges: [NSRange] = []
            splitRegex.enumerateMatches(in: prose, range: fullRange) { match, _, _ in
                if let m = match { splitRanges.append(m.range) }
            }
            var clauses: [String] = []
            var lastEnd = 0
            for r in splitRanges {
                clauses.append(nsStr.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd)))
                lastEnd = r.location + r.length
            }
            clauses.append(nsStr.substring(from: lastEnd))

            var seen: [String] = []
            for clause in clauses {
                if let sym = timelineSymbol(for: clause), !seen.contains(sym) {
                    seen.append(sym)
                }
            }
            mainSymbols = Array(seen.prefix(3))
        }
    }

    // If no timeline, try chance condition
    if mainSymbols.isEmpty {
        let dc = dayCond.lowercased()
        let isChanceTombstone = dc.hasPrefix("chance ") || dc.hasPrefix("slight chance ")
        let domCategory = weatherCategory(from: dc.isEmpty ? lower : dc)
        let isSkyDominant = [WeatherCategory.clear, .mostlyClear, .partlyCloudy, .cloudy].contains(domCategory)

        if isChanceTombstone || isSkyDominant {
            // Prose pattern: "chance of X"
            let pattern = "(?:slight )?chance of ([a-z\\s]+?)(?:\\.|,|$)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: prose, range: NSRange(prose.startIndex..., in: prose)),
               let capRange = Range(match.range(at: 1), in: prose) {
                let fragment = String(prose[capRange]).trimmingCharacters(in: .whitespaces)
                if let sym = timelineSymbol(for: fragment) { mainSymbols = [sym] }
            }
            // Tombstone fallback
            if mainSymbols.isEmpty && isChanceTombstone {
                let stripped = dc.hasPrefix("slight chance ")
                    ? String(dc.dropFirst("slight chance ".count))
                    : String(dc.dropFirst("chance ".count))
                if let sym = timelineSymbol(for: stripped) { mainSymbols = [sym] }
            }
        }
    }

    // ── Step 2: Night symbol appended to main group ──────────────────────
    if isNightSevere, let ns = nightSymbol {
        // Cap mainSymbols at 2 to leave room for night
        if mainSymbols.count > 2 { mainSymbols = Array(mainSymbols.prefix(2)) }
        mainSymbols.append(ns)
        nightSym = ns
    }

    // ── Step 3: Secondary chance symbols ("also possible", trailing "chance") ──
    // Look for "also possible" thunder or secondary precip after the main condition
    let alsoPossiblePattern = "([a-z\\s]+?)(?:is also possible|are also possible)"
    if let regex = try? NSRegularExpression(pattern: alsoPossiblePattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: prose, range: NSRange(prose.startIndex..., in: prose)),
       let capRange = Range(match.range(at: 1), in: prose) {
        let fragment = String(prose[capRange])
            .components(separatedBy: ".").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if let sym = timelineSymbol(for: fragment), !mainSymbols.contains(sym) {
            chanceSymbols.append(sym)
        }
    }

    guard mainSymbols.hasContent || chanceSymbols.hasContent else { return nil }
    // Need at least one symbol to be worth showing
    guard !mainSymbols.isEmpty || !chanceSymbols.isEmpty else { return nil }

    return ForecastBadge(
        mainSymbols:  mainSymbols,
        nightSymbol:  nightSym,
        chanceSymbols: chanceSymbols
    )
}

private extension Array {
    var hasContent: Bool { !isEmpty }
}

// MARK: - Timeline Extraction

/* Maps a raw NOAA condition phrase fragment to an SF symbol.
 * Used by timeline and chance parsers — not the full noaaSFSymbol chain.
 */
private func timelineSymbol(for fragment: String) -> String? {
    let f = fragment.lowercased()
    // Thunder only dominates when it's primary, not a secondary "also possible" qualifier
    let thunderIsPrimary = (f.contains("thunder") || f.contains("tstm"))
        && !f.contains("also possible")
        && !f.contains("slight chance of thunder")
        && !f.contains("isolated thunder")
    if thunderIsPrimary                                             { return "cloud.bolt.rain.fill" }
    if f.contains("blizzard") || f.contains("heavy snow")          { return "wind.snow" }
    if f.contains("freezing rain") || f.contains("fzra")           { return "cloud.sleet.fill" }
    if f.contains("sleet") || f.contains("wintry mix")             { return "cloud.sleet.fill" }
    if f.contains("rain") && f.contains("snow")                    { return "cloud.sleet.fill" }
    if f.contains("snow shower") || f.contains("flurr")            { return "snowflake" }
    if f.contains("snow")                                          { return "snowflake" }
    if f.contains("heavy rain")                                    { return "cloud.heavyrain.fill" }
    if f.contains("shower") || f.contains("rain")                  { return "cloud.rain.fill" }
    if f.contains("drizzle")                                       { return "cloud.drizzle.fill" }
    if f.contains("fog") || f.contains("mist")                     { return "cloud.fog.fill" }
    return nil
}

/* Normalises a raw NOAA time phrase into a short display label.
 * "11am" → "11am", "2pm" → "2pm", "noon" → "noon"
 * "this afternoon" / "afternoon" → "aftn"
 * "this morning" / "morning" → "morn"
 * "this evening" / "evening" → "eve"
 * "later" / "later today" → "later"
 * "tonight" → "tonight"
 */
private func shortTimeLabel(_ raw: String) -> String {
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    // Clock time: "11am", "2pm", "11 am", "2 pm"
    let clockPattern = "(\\d{1,2})(?::\\d{2})?\\s*(am|pm)"
    if let regex = try? NSRegularExpression(pattern: clockPattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let hourRange = Range(match.range(at: 1), in: s),
       let periodRange = Range(match.range(at: 2), in: s) {
        return String(s[hourRange]) + String(s[periodRange])
    }
    if s.contains("afternoon")  { return "aftn" }
    if s.contains("morning")    { return "morn" }
    if s.contains("evening")    { return "eve" }
    if s.contains("tonight")    { return "tonight" }
    if s.contains("later")      { return "later" }
    if s.contains("noon")       { return "noon" }
    return s
}

/* Extracts a ConditionTimeline from NOAA prose.
 *
 * Handles patterns like:
 *   "Snow before 9am, then rain"
 *   "Rain before 11am, then showers and possibly a thunderstorm between 11am and 2pm, then rain after 2pm"
 *   "Snow likely before noon, then a chance of sleet"
 *
 * Returns nil when fewer than 2 distinct precip segments are found.
 * Does NOT fire for pure sky-condition prose ("Mostly sunny") — only when
 * precip transitions are explicitly described.
 */
// MARK: - WeatherTimeOfDay

/* Time-of-day slot used to select the background image.
 * Sunrise: roughly 30 min before until 30 min after actual sunrise.
 * Night:   after sunset or before sunrise window.
 * Day:     everything else.
 */
enum WeatherTimeOfDay: String {
    case day     = "Day"
    case night   = "Night"
    case sunrise = "Sunrise"

    /* Derives the time slot from a SunEvent and the current UTC time,
     * adjusted for the location's timezone offset.
     *
     * @param sun              today's sunrise/sunset times
     * @param utcOffsetSeconds the location's UTC offset from Open-Meteo
     */
    static func from(sun: SunEvent?, utcOffsetSeconds: Int) -> WeatherTimeOfDay {
        guard let sun = sun else { return .day }
        let now = Date()
        let sunriseWindow: TimeInterval = 35 * 60   // ±35 min around sunrise
        let nearSunrise = abs(now.timeIntervalSince(sun.sunrise)) < sunriseWindow
        if nearSunrise { return .sunrise }
        let isNight = now < sun.sunrise || now > sun.sunset
        return isNight ? .night : .day
    }
}

extension WeatherTimeOfDay {
    static func from(isDay: Bool) -> WeatherTimeOfDay {
        return isDay ? .day : .night
    }
}

// MARK: - WeatherCondition

enum WeatherCondition {
    case clear, mostlyClear, overcast, rain, snow, fog, wind, thunderstorm

    /* Derives the current conditoins from a NOAA tombstone or prose condition string.
     * Returns nil when the string is empty or unrecognised — caller falls back to WMO.
     */
    static func fromCondition(_ condition: String) -> WeatherCondition? {
        let c = condition.lowercased()
        guard !c.isEmpty else { return nil }

        // For "X then Y" tombstones, the post-"then" segment is the dominant afternoon state.
        let parts    = c.components(separatedBy: " then ")
        let dominant = parts.last ?? c

        func background(for s: String) -> WeatherCondition? {
            // Severe weather
            if s.contains("thunder") || s.contains("tstm")                  { return .thunderstorm }
            if s.contains("blizzard") || s.contains("heavy snow")           { return .snow }
            if s.contains("blowing snow") || s.contains("drifting snow")    { return .snow }
            if s.contains("freezing rain") || s.contains("fzra")            { return .rain }
            if s.contains("freezing drizzle") || s.contains("fzdz")         { return .rain }
            if s.contains("sleet") || s.contains("ice pellet")              { return .rain }
            
            // Per your request: Any snow/mix returns .snow for the whiteish gradient vibes
            if s.contains("wintry mix") || s.contains("rain/snow") ||
               s.contains("rain and snow") || s.contains("snow and rain")   { return .snow }
            
            if s.contains("snow likely")                                    { return .snow }

            // Sky condition checked before generic precipitation
            if s.contains("partly sunny") || s.contains("partly cloudy")    { return .mostlyClear }
            if s.contains("mostly sunny") || s.contains("mostly clear")     { return .mostlyClear }
            if s.contains("mostly cloudy") || s.contains("considerable cloudiness") { return .overcast }
            if s.contains("sunny") || s.contains("clear") || s.contains("fair") { return .clear }
            if s.contains("cloudy") || s.contains("overcast") ||
               s.contains("increasing clouds")                              { return .overcast }

            // Snow
            if s.contains("snow shower")                                    { return .snow }
            if s.contains("flurr")                                          { return .snow }
            if s.contains("snow")                                           { return .snow }

            // Rain
            if s.contains("heavy rain")                                     { return .rain }
            if s.contains("rain shower") || s.contains("shower")            { return .rain }
            if s.contains("drizzle")                                        { return .rain }
            if s.contains("rain")                                           { return .rain }

            // Atmosphere
            if s.contains("dense fog") || s.contains("patchy fog") || s.contains("fog") || s.contains("mist") { return .fog }
            if s.contains("haze") || s.contains("smoke") || s.contains("dust") { return .fog }

            return nil
        }

        return background(for: dominant) ?? (parts.count > 1 ? background(for: c) : nil)
    }

    /* Derives the condition from an Open-Meteo WMO weather code. */
    static func fromWMO(code: Int) -> WeatherCondition {
        switch code {
        case 95...99:             return .thunderstorm
        case 71...77, 85, 86:     return .snow
        case 51...67, 80...82:    return .rain
        case 45, 48:              return .fog
        case 3:                   return .overcast
        case 1, 2:                return .mostlyClear
        default:                  return .clear
        }
    }

    /* Asset name suffix, e.g. "Clear", "Thunderstorm". */
    var assetSuffix: String {
        switch self {
        case .clear:         return "Clear"
        case .mostlyClear:   return "MostlyClear"
        case .overcast:      return "Overcast"
        case .rain:          return "Rain"
        case .snow:          return "Snow"
        case .fog:           return "Fog"
        case .wind:          return "Wind"
        case .thunderstorm:  return "Thunderstorm"
        }
    }
}
