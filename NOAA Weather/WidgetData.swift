/* WidgetData.swift
 * White Weather
 *
 * Shared weather snapshot model for the widget extension.
 * The widget fetches its own data independently and saves here.
 * The main app reads on deep link open for a warm-start.
 * Shared via App Group: group.weather.widgetinfo
 */

import Foundation
import WidgetKit

struct WidgetWeatherData: Codable {
    let id: String              // "current" or a SavedLocation UUID string
    let lat: Double
    let lon: Double
    let temperature: Double
    let high: Double
    let low: Double
    let condition: String       // short condition label, e.g. "Mostly Sunny"
    let sfSymbol: String
    let precipProbability: Int  // 0–100
    let locationName: String
    let windGusts: Double?
    let isDay: Bool
    let accumDisplayString: String?
    let dayProse: String
    let nightProse: String
    let fetchedAt: Date

    static let groupID = "group.weather.widgetinfo"

    /* Saves this snapshot to the shared App Group container under key "weather-{id}". */
    func save() {
        guard let defaults = UserDefaults(suiteName: Self.groupID),
              let data     = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "weather-\(id)")
    }

    /* Loads a saved snapshot for the given location ID.
     *
     * @param id  location ID (default "current")
     * @return decoded snapshot, or nil if none exists
     */
    static func load(id: String = "current") -> WidgetWeatherData? {
        guard let defaults = UserDefaults(suiteName: groupID),
              let data     = defaults.data(forKey: "weather-\(id)"),
              let decoded  = try? JSONDecoder().decode(WidgetWeatherData.self, from: data)
        else { return nil }
        return decoded
    }

    static var placeholder: WidgetWeatherData {
        WidgetWeatherData(
            id: "current", lat: 0, lon: 0,
            temperature: 45, high: 52, low: 38,
            condition: "Mostly Sunny", sfSymbol: "sun.max.fill",
            precipProbability: 0,
            locationName: "—",
            windGusts: nil, isDay: true,
            accumDisplayString: nil,
            dayProse: "Fetching forecast...",
            nightProse: "",
            fetchedAt: Date()
        )
    }
}
