/* ForecastAnalyzer.swift
 * White Weather
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
        let hasRain = text.contains("rain") || text.contains("shower") || text.contains("drizzle")
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

    /* Returns a display string like "< 1\"", "2–4\"", "~2\"", "> 3\"". */
    var displayString: String {
        switch (low, high) {
        case (nil, nil):                    return ""
        case (nil, let h?):                 return "< \(fmt(h))\""
        case (let l?, nil):                 return "> \(fmt(l))\""
        case (let l?, let h?) where l == h: return "\(fmt(l))\""
        case (let l?, let h?):              return "\(fmt(l))–\(fmt(h))\""
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
        if s.contains("thunder") || s.contains("tstm")                  { return "cloud.bolt.rain.fill" }
        if s.contains("blizzard") || s.contains("heavy snow")           { return "wind.snow" }
        if s.contains("blowing snow") || s.contains("drifting snow")    { return "wind.snow" }
        if s.contains("freezing rain") || s.contains("fzra")            { return "cloud.sleet.fill" }
        if s.contains("freezing drizzle") || s.contains("fzdz")         { return "cloud.sleet.fill" }
        if s.contains("sleet") || s.contains("ice pellet")              { return "cloud.sleet.fill" }
        if s.contains("wintry mix") || s.contains("rain/snow") ||
           s.contains("rain and snow") || s.contains("snow and rain")   { return "cloud.sleet.fill" }
        
        if s.contains("snow likely")                                    { return "cloud.snow.fill" }

        // Sky condition checked before generic precipitation, so that
        // "Chance Snow. Partly Sunny" correctly returns the sky icon.
        if s.contains("partly sunny") || s.contains("partly cloudy")    { return isDay ? "cloud.sun.fill"   : "cloud.moon.fill" }
        if s.contains("mostly sunny") || s.contains("mostly clear")     { return isDay ? "sun.max.fill"     : "moon.stars.fill" }
        if s.contains("mostly cloudy") || s.contains("considerable cloudiness") { return "cloud.fill" }
        if s.contains("sunny") || s.contains("clear") || s.contains("fair") { return isDay ? "sun.max.fill" : "moon.stars.fill" }
        if s.contains("cloudy") || s.contains("overcast") ||
           s.contains("increasing clouds")                               { return "cloud.fill" }

        // Snow
        if s.contains("snow shower")                                     { return "cloud.snow.fill" }
        if s.contains("flurr")                                           { return "cloud.snow.fill" }
        if s.contains("snow")                                            { return "cloud.snow.fill" }

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
