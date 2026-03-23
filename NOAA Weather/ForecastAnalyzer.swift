// ForecastAnalyzer.swift
// White Weather
//
// Supports iOS 17+.

import Foundation

// MARK: - PrecipType

enum PrecipType {
    case snow
    case rain
    case mixed  // rain and snow both mentioned
    case none

    // Derive from NOAA condition strings and/or prose keywords.
    static func from(dayCondition: String, nightCondition: String, prose: String) -> PrecipType {
        let combined = (dayCondition + " " + nightCondition + " " + prose).lowercased()
        let hasSnow = combined.contains("snow") || combined.contains("flurr") ||
                      combined.contains("blizzard") || combined.contains("sleet") ||
                      combined.contains("wintry mix")
        let hasRain = combined.contains("rain") || combined.contains("shower") ||
                      combined.contains("drizzle")
        if hasSnow && hasRain { return .mixed }
        if hasSnow             { return .snow }
        if hasRain             { return .rain }
        return .none
    }
}

// MARK: - AccumulationRange

struct AccumulationRange {
    let low: Double?   // nil = no lower bound ("less than X")
    let high: Double?  // nil = no upper bound ("more than X")

    var hasAccumulation: Bool { low != nil || high != nil }

    var displayString: String {
        switch (low, high) {
        case (nil, nil):                    return ""
        case (nil, let h?):                 return "< \(fmt(h))\""
        case (let l?, nil):                 return "> \(fmt(l))\""
        case (let l?, let h?) where l == h: return "~\(fmt(l))\""
        case (let l?, let h?):              return "\(fmt(l))–\(fmt(h))\""
        }
    }

    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v))
            : String(format: "%.1f", v)
    }

    static func merge(_ a: AccumulationRange, _ b: AccumulationRange) -> AccumulationRange {
        guard a.hasAccumulation || b.hasAccumulation else { return .none }
        let lo = max(a.low  ?? 0, b.low  ?? 0)
        let hi = max(a.high ?? 0, b.high ?? 0)
        return AccumulationRange(low: lo > 0 ? lo : nil, high: hi > 0 ? hi : nil)
    }

    static var none: AccumulationRange { AccumulationRange(low: nil, high: nil) }
}

// MARK: - NOAA condition string → SF Symbol

nonisolated func noaaSFSymbol(condition: String, isDay: Bool) -> String? {
    let c = condition.lowercased()
    guard !c.isEmpty else { return nil }

    // "X then Y" — dominant state is after "then"
    let parts = c.components(separatedBy: " then ")
    let dominant = parts.last ?? c

    func symbol(for s: String) -> String? {
        if s.contains("thunder") || s.contains("tstm")              { return "cloud.bolt.rain.fill" }
        if s.contains("freezing rain") || s.contains("fzra")        { return "cloud.sleet.fill" }
        if s.contains("freezing drizzle") || s.contains("fzdz")     { return "cloud.sleet.fill" }
        if s.contains("sleet") || s.contains("ice pellet")          { return "cloud.sleet.fill" }
        if s.contains("blizzard")                                    { return "wind.snow" }
        if s.contains("heavy snow")                                  { return "wind.snow" }
        if s.contains("blowing snow") || s.contains("drifting snow") { return "wind.snow" }
        if s.contains("snow shower")                                 { return "cloud.snow.fill" }
        if s.contains("flurr")                                       { return "cloud.snow.fill" }
        if s.contains("wintry mix") || s.contains("rain/snow") ||
           s.contains("rain and snow") || s.contains("snow and rain") { return "cloud.sleet.fill" }
        if s.contains("snow")                                        { return "cloud.snow.fill" }
        if s.contains("heavy rain")                                  { return "cloud.heavyrain.fill" }
        if s.contains("rain shower") || s.contains("shower")        {
            return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        }
        if s.contains("drizzle")                                     { return "cloud.drizzle.fill" }
        if s.contains("rain")                                        { return "cloud.rain.fill" }
        if s.contains("dense fog") || s.contains("patchy fog")      { return "cloud.fog.fill" }
        if s.contains("fog") || s.contains("mist")                  { return "cloud.fog.fill" }
        if s.contains("haze") || s.contains("smoke") || s.contains("dust") { return "sun.haze.fill" }
        if s.contains("breezy") || s.contains("windy") || s.contains("blustery") { return "wind" }
        if s.contains("partly sunny") || s.contains("partly cloudy") {
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        }
        if s.contains("mostly sunny") || s.contains("mostly clear") {
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        }
        if s.contains("sunny") || s.contains("clear") || s.contains("fair") {
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        }
        if s.contains("mostly cloudy") || s.contains("considerable cloudiness") {
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        }
        if s.contains("cloudy") || s.contains("overcast") || s.contains("increasing clouds") {
            return "cloud.fill"
        }
        return nil
    }

    return symbol(for: dominant) ?? (parts.count > 1 ? symbol(for: c) : nil)
}
