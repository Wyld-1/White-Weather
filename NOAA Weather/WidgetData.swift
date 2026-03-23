// WidgetData.swift
// Shared between the app and widget extension via App Group.
// Written by the main app, read by the widgets.
// App Group: group.weather.widgetinfo

import Foundation
import WidgetKit

struct WidgetWeatherData: Codable {
    let id: String // "current" or the UUID string
    let temperature: Double
    let high: Double
    let low: Double
    let condition: String
    let sfSymbol: String
    let locationName: String
    let windGusts: Double?
    let isDay: Bool
    let accumDisplayString: String?
    let dayProse: String
    let nightProse: String
    let fetchedAt: Date

    static let groupID = "group.weather.widgetinfo"

    func save() {
        guard let defaults = UserDefaults(suiteName: Self.groupID),
              let data = try? JSONEncoder().encode(self) else { return }
        // Save using a unique key for this location
        defaults.set(data, forKey: "weather-\(id)")
    }

    static func load(id: String = "current") -> WidgetWeatherData? {
        guard let defaults = UserDefaults(suiteName: groupID),
              let data = defaults.data(forKey: "weather-\(id)"),
              let decoded = try? JSONDecoder().decode(WidgetWeatherData.self, from: data)
        else { return nil }
        return decoded
    }

    static var placeholder: WidgetWeatherData {
        WidgetWeatherData(id: "current", temperature: 00, high: 00, low: 00, condition: "Mostly Sunny", sfSymbol: "hourglass", locationName: "Unkown", windGusts: 00, isDay: true, accumDisplayString: nil, dayProse: "Fetching...", nightProse: "Fetching...", fetchedAt: Date())
    }
}
