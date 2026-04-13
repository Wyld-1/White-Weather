/* LocationStore.swift
 * Whiteout Weather
 *
 * Single source of truth for the user's saved location list.
 * The GPS/current location is handled separately by LocationManager and is never stored here.
 * Persists to UserDefaults and syncs location metadata to the shared App Group
 * so the widget knows where to fetch from.
 */

import Foundation
internal import CoreLocation
import WidgetKit

struct SavedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var isSkiResort: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Observable
@MainActor
final class LocationStore {
    private(set) var saved: [SavedLocation] = []
    private let key     = "savedLocations"
    private let groupID = "group.weather.widgetinfo"

    init() { load() }

    /* Adds a location if one doesn't already exist within ~5km of the given coordinate. */
    func add(_ location: SavedLocation) {
        guard !saved.contains(where: {
            abs($0.latitude  - location.latitude)  < 0.05 &&
            abs($0.longitude - location.longitude) < 0.05
        }) else { return }
        saved.append(location)
        persist()
        syncToWidget()
    }

    /* Deletes a location and returns the ID of the page that should be selected after deletion.
     * Navigates left: the saved location before this one, or "current" if this was the first.
     * Callers should set selectedID to the returned value BEFORE the deletion so SwiftUI's
     * TabView doesn't try to render the now-gone ID during the transition animation.
     *
     * @param location  the location to delete
     * @param currentSelectedID  the app's current selectedLocationID binding value
     * @return the ID that should become selected after deletion
     */
    func delete(_ location: SavedLocation, currentSelectedID: String?, hasCurrentPage: Bool) -> String? {
        let idx = saved.firstIndex(where: { $0.id == location.id })
        let targetID: String?
        if let idx {
            if idx == 0 {
                // First saved location — go to current page if visible, else next saved
                if hasCurrentPage {
                    targetID = "current"
                } else if saved.count > 1 {
                    targetID = saved[1].id.uuidString
                } else {
                    targetID = nil
                }
            } else {
                // Go to the saved location immediately to the left
                targetID = saved[idx - 1].id.uuidString
            }
        } else {
            targetID = currentSelectedID
        }
        saved.removeAll { $0.id == location.id }
        persist()
        syncToWidget()
        return targetID
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /* Public: re-syncs the registry on foreground without reloading timelines.
     * Called by WhiteoutWeatherApp on every .active scene-phase transition.
     */
    func syncRegistryToWidget() {
        syncLocationRegistry()
    }

    /* Syncs location registry and triggers a widget timeline reload. */
    private func syncToWidget() {
        syncLocationRegistry()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data)
        else { return }
        saved = decoded
        // Sync metadata only on launch — weather data hasn't loaded yet so
        // there's no reason to reload widget timelines.
        syncLocationRegistry()
    }

    /* Writes location names, coordinates, and ordering to the shared App Group container.
     * The widget reads this to resolve coordinates for independent fetches.
     * Does not reload widget timelines.
     */
    private func syncLocationRegistry() {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        var names:  [String: String] = [:]
        var coords: [String: String] = [:]
        for loc in saved {
            names[loc.id.uuidString]  = loc.name
            coords[loc.id.uuidString] = "\(loc.latitude),\(loc.longitude)"
        }
        defaults.set(names,                           forKey: "saved_location_names")
        defaults.set(coords,                          forKey: "saved_location_coords")
        defaults.set(saved.map { $0.id.uuidString },  forKey: "ordered_location_ids")
    }
}
