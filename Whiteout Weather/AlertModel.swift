/* AlertModel.swift
 * Whiteout Weather
 *
 * NWS Alerts API integration.
 * Fetches active alerts for a coordinate from api.weather.gov,
 * maps every known event type to a display configuration,
 * and sorts by severity so the most critical alerts surface first.
 *
 * Endpoint: GET https://api.weather.gov/alerts/active?point={lat},{lon}
 * No API key required. Only "Actual" status alerts are surfaced.
 */

import Foundation
import SwiftUI

// MARK: - Severity

/* NWS CAP severity levels, ordered from most to least critical.
 * Used for sorting: lower rawValue = higher priority.
 */
enum NWSAlertSeverity: Int, Comparable, Decodable {
    case extreme  = 0
    case severe   = 1
    case moderate = 2
    case minor    = 3
    case unknown  = 4

    static func < (lhs: NWSAlertSeverity, rhs: NWSAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Extreme":  self = .extreme
        case "Severe":   self = .severe
        case "Moderate": self = .moderate
        case "Minor":    self = .minor
        default:         self = .unknown
        }
    }

    /* Three-level background opacity for the alert banner tint.
     * Extreme/Severe → strong, Moderate → mid, Minor/Unknown → subtle.
     */
    var backgroundOpacity: Double {
        switch self {
        case .extreme:          return 0.60
        case .severe:           return 0.40
        case .moderate, .minor, .unknown: return 0.15
        }
    }

    /* Border opacity stays at 100% regardless of severity — always clear. */
    var borderOpacity: Double { 1.0 }

    /* Human-readable severity label for the alert detail sheet subtitle. */
    var label: String {
        switch self {
        case .extreme:  return "Extreme Warning"
        case .severe:   return "Severe Warning"
        case .moderate: return "Moderate Advisory"
        case .minor:    return "Minor Advisory"
        case .unknown:  return "Weather Alert"
        }
    }
}

// MARK: - Display Config

/* Visual configuration for a single alert type.
 * Symbol is an SF symbol name; color drives both border and background tint.
 */
struct AlertDisplayConfig {
    let symbol: String
    let color: Color
    let title: String           // Short display title, overrides the raw event name.
}

// MARK: - NWSAlert

struct NWSAlert: Identifiable {
    let id: String
    let event: String
    let severity: NWSAlertSeverity
    let headline: String        // Short NWS headline, e.g. "Wind Advisory in effect until 6 PM PDT"
    let description: String     // Full NWS descriptive text shown in the detail sheet

    /* Resolves the display configuration for this alert's event type.
     * Falls back to a generic warning icon for unknown event names.
     */
    var display: AlertDisplayConfig {
        NWSAlert.displayConfig(for: event)
    }

    // MARK: Event → Display mapping

    /* Maps every standard NWS event name to its SF symbol and color.
     * Source: NWS Product Definition (PDD) and CAP event vocabulary.
     * https://www.weather.gov/help-map
     */
    static func displayConfig(for event: String) -> AlertDisplayConfig {
        let e = event.lowercased()

        // MARK: Tornado
        if e.contains("tornado") {
            return AlertDisplayConfig(symbol: "tornado", color: .red, title: event)
        }

        // MARK: Thunderstorm / Lightning
        if e.contains("thunderstorm") || e.contains("lightning") {
            return AlertDisplayConfig(symbol: "cloud.bolt.fill", color: .yellow, title: event)
        }

        // MARK: Hurricane / Tropical
        if e.contains("hurricane") || e.contains("tropical storm") || e.contains("typhoon") {
            return AlertDisplayConfig(symbol: "hurricane", color: Color(red: 0.85, green: 0.25, blue: 0.1), title: event)
        }

        // MARK: Flash Flood (before general flood — more specific)
        if e.contains("flash flood") {
            return AlertDisplayConfig(symbol: "drop.triangle.fill", color: Color(red: 0.0, green: 0.55, blue: 0.45), title: event)
        }

        // MARK: Flood / Storm Surge
        if e.contains("flood") || e.contains("storm surge") || e.contains("coastal flood") || e.contains("lakeshore flood") {
            return AlertDisplayConfig(symbol: "water.waves", color: Color(red: 0.1, green: 0.5, blue: 0.8), title: event)
        }

        // MARK: Fire / Red Flag
        if e.contains("red flag") || e.contains("fire weather") || e.contains("fire warning") || e.contains("fire danger") {
            return AlertDisplayConfig(symbol: "flame.fill", color: Color(red: 0.95, green: 0.35, blue: 0.05), title: event)
        }

        // MARK: Smoke / Air Quality
        if e.contains("air quality") || e.contains("smoke") || e.contains("air stagnation") {
            return AlertDisplayConfig(symbol: "aqi.high", color: Color(red: 0.55, green: 0.3, blue: 0.7), title: event)
        }

        // MARK: Blizzard
        if e.contains("blizzard") {
            return AlertDisplayConfig(symbol: "wind.snow", color: Color(red: 0.4, green: 0.7, blue: 1.0), title: event)
        }

        // MARK: Winter Storm / Ice
        if e.contains("winter storm") || e.contains("ice storm") || e.contains("sleet") || e.contains("freezing rain") || e.contains("freezing drizzle") {
            return AlertDisplayConfig(symbol: "cloud.sleet.fill", color: Color(red: 0.4, green: 0.75, blue: 1.0), title: event)
        }

        // MARK: Winter Weather / Freeze / Frost
        if e.contains("winter weather") || e.contains("freeze") || e.contains("frost") || e.contains("wind chill") || e.contains("cold") {
            return AlertDisplayConfig(symbol: "thermometer.snowflake", color: Color(red: 0.55, green: 0.85, blue: 1.0), title: event)
        }

        // MARK: Snow (catch-all after blizzard/winter storm)
        if e.contains("snow") || e.contains("avalanche") || e.contains("lake effect") {
            return AlertDisplayConfig(symbol: "snowflake", color: Color(red: 0.6, green: 0.85, blue: 1.0), title: event)
        }

        // MARK: Heat
        if e.contains("excessive heat") || e.contains("extreme heat") {
            return AlertDisplayConfig(symbol: "thermometer.sun.fill", color: Color(red: 1.0, green: 0.3, blue: 0.1), title: event)
        }
        if e.contains("heat") {
            return AlertDisplayConfig(symbol: "thermometer.medium", color: Color(red: 1.0, green: 0.55, blue: 0.1), title: event)
        }

        // MARK: Wind
        if e.contains("high wind") || e.contains("wind advisory") || e.contains("wind warning") || e.contains("extreme wind") {
            return AlertDisplayConfig(symbol: "wind.circle.fill", color: .yellow, title: event)
        }

        // MARK: Dust
        if e.contains("dust storm") || e.contains("blowing dust") || e.contains("dust devil") {
            return AlertDisplayConfig(symbol: "sun.dust.fill", color: Color(red: 0.8, green: 0.65, blue: 0.3), title: event)
        }

        // MARK: Fog
        if e.contains("dense fog") || e.contains("fog advisory") || e.contains("freezing fog") {
            return AlertDisplayConfig(symbol: "cloud.fog.fill", color: Color(red: 0.7, green: 0.75, blue: 0.8), title: event)
        }

        // MARK: Dense Smoke
        if e.contains("dense smoke") {
            return AlertDisplayConfig(symbol: "smoke.fill", color: Color(red: 0.55, green: 0.45, blue: 0.5), title: event)
        }

        // MARK: Tsunami / Seiche
        if e.contains("tsunami") || e.contains("seiche") {
            return AlertDisplayConfig(symbol: "water.waves.and.arrow.trianglehead.up.fill", color: Color(red: 0.1, green: 0.4, blue: 0.9), title: event)
        }

        // MARK: Earthquake
        if e.contains("earthquake") {
            return AlertDisplayConfig(symbol: "waveform.path.ecg", color: Color(red: 0.7, green: 0.5, blue: 0.2), title: event)
        }

        // MARK: Marine / Coastal
        if e.contains("marine") || e.contains("gale") || e.contains("small craft") || e.contains("hazardous seas") || e.contains("rip current") {
            return AlertDisplayConfig(symbol: "water.waves", color: Color(red: 0.15, green: 0.45, blue: 0.85), title: event)
        }

        // MARK: Hydrological
        if e.contains("hydrological") {
            return AlertDisplayConfig(symbol: "drop.fill", color: Color(red: 0.1, green: 0.5, blue: 0.8), title: event)
        }

        // MARK: Volcano
        if e.contains("volcano") || e.contains("volcanic") || e.contains("ashfall") {
            return AlertDisplayConfig(symbol: "mountain.2.fill", color: Color(red: 0.6, green: 0.25, blue: 0.1), title: event)
        }

        // MARK: Special Weather Statement / Advisory (catch-all for lower-tier products)
        if e.contains("special weather statement") || e.contains("weather statement") {
            return AlertDisplayConfig(symbol: "exclamationmark.bubble.fill", color: .white, title: event)
        }

        // MARK: Generic fallback
        return AlertDisplayConfig(symbol: "exclamationmark.triangle.fill", color: .yellow, title: event)
    }
}

// MARK: - JSON Decodable DTOs

private struct AlertsResponse: Decodable {
    let features: [AlertFeature]
}

private struct AlertFeature: Decodable {
    let id: String
    let properties: AlertProperties
}

private struct AlertProperties: Decodable {
    let event: String
    let severity: NWSAlertSeverity
    let headline: String?
    let description: String?    // Full alert text; may be nil for some product types
    let status: String          // "Actual" | "Exercise" | "System" | "Test" | "Draft"
    let messageType: String     // "Alert" | "Update" | "Cancel" | "Ack" | "Error"
}

// MARK: - NWSAlertClient

/* Fetches active NWS alerts for a coordinate.
 * Results are filtered to "Actual" + "Alert"/"Update" only and sorted by severity.
 * Returns an empty array (never throws) on any network or parse error — alerts
 * are supplemental and should never block the main weather display.
 */
actor NWSAlertClient {
    static let shared = NWSAlertClient()

    func fetchAlerts(lat: Double, lon: Double) async -> [NWSAlert] {
        // NWS API requires no more than 4 decimal places.
        let latStr = String(format: "%.4f", lat)
        let lonStr = String(format: "%.4f", lon)
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(latStr),\(lonStr)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("WhiteoutWeather/1.0 (contact@example.com)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(AlertsResponse.self, from: data)

            return response.features
                .filter { $0.properties.status == "Actual" &&
                          ($0.properties.messageType == "Alert" || $0.properties.messageType == "Update") }
                .map { feature in
                    NWSAlert(
                        id:          feature.id,
                        event:       feature.properties.event,
                        severity:    feature.properties.severity,
                        headline:    feature.properties.headline ?? feature.properties.event,
                        description: feature.properties.description ?? ""
                    )
                }
                .sorted { $0.severity < $1.severity }

        } catch {
            return []
        }
    }
}
