//
//  NOAA_WeatherApp.swift
//  NOAA Weather

import SwiftUI
import Combine
import AVFoundation

extension Notification.Name {
    static let refreshAllLocations = Notification.Name("refreshAllLocations")
}

@main
struct NOAA_WeatherApp: App {
    @State private var locationStore = LocationStore()
    @State private var locationManager = LocationManager()
    
    // Track the ID of the location we want to display
    @State private var selectedLocationID: String? = "current"

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedID: $selectedLocationID)
                .environment(locationStore)
                .environment(locationManager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onAppear { locationManager.requestLocation() }
                .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
                    // Nudge GPS location (LocationPageView picks this up via .task)
                    locationManager.requestLocation()
                    // Tell all saved-location pages to refresh too
                    NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
                }
        }
    }
    
    private func handleDeepLink(_ url: URL) {
    // Look for: wildcat-weather://location/{id}
    guard url.scheme == "wildcat-weather",
          url.host == "location",
          let locationID = url.pathComponents.last else { return }
    
    // Update the state to switch the UI to this location
    selectedLocationID = locationID
}
}
