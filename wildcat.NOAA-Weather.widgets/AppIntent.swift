//
//  AppIntent.swift
//  wildcat.NOAA-Weather.widgets
//
//  Created by Liam Lefohn on 3/23/26.
//

import WidgetKit
import AppIntents

struct LocationEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Location"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = LocationQuery()
}

struct LocationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LocationEntity] {
        return try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LocationEntity] {
        let defaults = UserDefaults(suiteName: "group.weather.widgetinfo")
        let registry = defaults?.dictionary(forKey: "saved_location_names") as? [String: String] ?? [:]
        
        // Look for an ordered list of IDs from the main app
        let order = defaults?.stringArray(forKey: "ordered_location_ids") ?? Array(registry.keys)
        
        return order.compactMap { id in
            guard let name = registry[id] else { return nil }
            return LocationEntity(id: id, name: name)
        }
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Select Location" }
    @Parameter(title: "Location") var location: LocationEntity?
}
