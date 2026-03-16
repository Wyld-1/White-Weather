//
//  NOAA_WeatherApp.swift
//  NOAA Weather

import SwiftUI

@main
struct NOAA_WeatherApp: App {
    @State private var locationStore = LocationStore()
    @State private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationStore)
                .environment(locationManager)
                .onAppear { locationManager.requestLocation() }
        }
    }
}
