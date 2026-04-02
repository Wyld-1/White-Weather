//
//  LocationPageView.swift
//  NOAA Weather
//
//  One page in the swipe carousel. Owns its own WeatherViewModel.

import SwiftUI
import MapKit

struct LocationPageView: View {
    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager
    
    @State private var viewModel = WeatherViewModel()
    @State private var selectedDay: DailyForecast?
    @State private var showDeleteConfirm = false
    #if DEBUG
    @State private var showDebugReset = false
    #endif
    
    let savedLocation: SavedLocation?
    let onBackgroundChange: ((Bool) -> Void)?
    private var isCurrentLocation: Bool { savedLocation == nil }
    
    private var coordinate: CLLocationCoordinate2D? {
        savedLocation?.coordinate ?? locationManager.coordinate
    }

    var body: some View {
        ZStack {
            // Background gradient — condition + time-of-day resolved live
            GradientBackgroundView(
                condition: viewModel.weatherCondition,
                timeOfDay: viewModel.weatherTimeOfDay
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                CurrentConditionsHeader(
                    locationName:      viewModel.locationName,
                    isCurrentLocation: viewModel.isCurrentLocation,
                    current:           viewModel.current,
                    high:              viewModel.daily.first?.high,
                    low:               viewModel.daily.first?.low,
                    isLoading:         viewModel.daily.isEmpty,
                    currentSFSymbol:   viewModel.currentSFSymbol
                )
                .padding(.top, 8)

                Capsule()
                    .fill(.black.opacity(0.3))
                    .frame(width: 300, height: 4)
                
                Spacer(minLength: 10)

                if let error = viewModel.errorMessage {
                    Spacer()
                    ErrorView(message: error) { triggerFetch() }
                    Spacer()

                } else if viewModel.daily.isEmpty {
                    Spacer()
                    Image("WhiteoutSearching")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .shadow(radius: 6)
                        .padding(.horizontal, 32)
                        .padding(.bottom, -18)

                } else {
                    // Scroll content extends under the home indicator; the gradient
                    // overlay fades it out so nothing collides with system chrome.
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: false) {
                            WeatherContentView(viewModel: viewModel, selectedDay: $selectedDay)

                            if !isCurrentLocation {
                                deleteButton
                            }
                            #if DEBUG
                            debugResetButton
                            #endif

                            Text("Weather provided by NOAA and Open-Meteo")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(color: .black, radius: 1)
                                .padding(.bottom, 80)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear,         location: 0.00),
                                    .init(color: .black.opacity(0.3), location: 0.02),
                                    .init(color: .black,         location: 0.04),
                                    .init(color: .black,         location: 1.00),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .ignoresSafeArea(edges: .bottom)
                        .refreshable {
                            guard let coord = coordinate else { return }
                            let locationID  = savedLocation?.id.uuidString
                            let skipGeocode = savedLocation != nil
                            await Task.detached(priority: .userInitiated) {
                                await viewModel.load(
                                    coordinate:  coord,
                                    locationID:  locationID,
                                    skipGeocode: skipGeocode,
                                    forceRefresh: true
                                )
                            }.value
                        }

                        // Bottom fade — covers the home indicator area with a soft
                        // gradient that matches the weather background color.
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 80)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(item: $selectedDay) { day in
            DayDetailSheet(
                days:       Array(viewModel.daily.prefix(7)),
                startIndex: viewModel.daily.prefix(7).firstIndex(where: { $0.id == day.id }) ?? 0,
                globalLow:  viewModel.globalLow,
                globalHigh: viewModel.globalHigh
            )
        }
        .alert("Delete Location?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let loc = savedLocation { store.delete(loc) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Remove \(savedLocation?.name ?? "this location")?")
        }
        .task(id: coordinate?.latitude) {
            triggerFetch()
        }

        // Notify ContentView when background brightness changes so PageDotsView
        // can adapt its colors. Fire on both condition and time-of-day changes.
        .onChange(of: viewModel.isLightBackground) { _, newValue in
            onBackgroundChange?(newValue)
        }
        .onAppear {
            onBackgroundChange?(viewModel.isLightBackground)
        }
        // Refresh on the 15-min timer and on settings changes (units, time format).
        // skipGeocode only for saved locations whose name is already known.
        .onReceive(NotificationCenter.default.publisher(for: .refreshAllLocations)) { _ in
            guard let coord = coordinate else { return }
            Task {
                await viewModel.load(
                    coordinate: coord,
                    locationID: savedLocation?.id.uuidString,
                    skipGeocode: savedLocation != nil,
                    forceRefresh: true
                )
            }
        }
    }

    private func triggerFetch() {
        guard let coord = coordinate else { return }

        let locationID = savedLocation?.id.uuidString

        viewModel.isCurrentLocation = savedLocation == nil
        if let savedLoc = savedLocation {
            viewModel.setLocationName(savedLoc.name)
            viewModel.setSkiResort(savedLoc.isSkiResort)
        }

        // Warm-start: only populate from cache when there's no live data yet.
        // Calling loadFromCache when the viewModel already has current data
        // (e.g. on swipe-back within the cache window) would overwrite live
        // state with stale widget cache, producing the wrong weather display.
        let cacheID = locationID ?? "current"
        if viewModel.current == nil {
            viewModel.loadFromCache(id: cacheID)
        }

        Task {
            await viewModel.load(
                coordinate: coord,
                locationID: locationID,
                skipGeocode: savedLocation != nil
            )
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
                Text("Delete Location")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.red)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    #if DEBUG
    private var debugResetButton: some View {
        Button {
            showDebugReset = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.orange)
                Text("Reset App Data")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 15)
        .confirmationDialog("Reset App Data", isPresented: $showDebugReset, titleVisibility: .visible) {
            Button("Welcome screen only", role: .destructive) {
                NotificationCenter.default.post(
                    name: .debugResetApp,
                    object: DebugResetScope.welcomeOnly
                )
            }
            Button("All (incl. saved locations)", role: .destructive) {
                NotificationCenter.default.post(
                    name: .debugResetApp,
                    object: DebugResetScope.all
                )
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }
    #endif
}

// MARK: - Supporting Views

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image("WhiteoutSleeping")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 200)
                .padding(.vertical, 10)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Haptics.shared.impact(.rigid)
                retry()
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }
}
