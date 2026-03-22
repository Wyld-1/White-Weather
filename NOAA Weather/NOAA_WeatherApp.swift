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

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationStore)
                .environment(locationManager)
                .onAppear { locationManager.requestLocation() }
                .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
                    // Nudge GPS location (LocationPageView picks this up via .task)
                    locationManager.requestLocation()
                    // Tell all saved-location pages to refresh too
                    NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
                }
        }
    }
}
