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
    private var isCurrentLocation: Bool { savedLocation == nil }
    
    private var coordinate: CLLocationCoordinate2D? {
        savedLocation?.coordinate ?? locationManager.coordinate
    }

    var body: some View {
        ZStack {
            // Background
            ImageBackgroundView(imageName: viewModel.backgroundImageName)
                .ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 0) {
                // Pinned header — always visible, never scrolls
                CurrentConditionsHeader(
                    locationName:      viewModel.locationName,
                    isCurrentLocation: viewModel.isCurrentLocation,
                    current:           viewModel.current,
                    high:              viewModel.daily.first?.high,
                    low:               viewModel.daily.first?.low,
                    isLoading:         viewModel.daily.isEmpty
                )
                .padding(.top, 8)
                
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: 300, height: 3)
                    .padding(.bottom, 8)

                if let error = viewModel.errorMessage {
                    // Error state — centred below the pinned header
                    Spacer()
                    ErrorView(message: error) { triggerFetch() }
                    Spacer()

                } else if viewModel.daily.isEmpty {
                    // Loading state
                    Spacer()
                    Image("WhiteoutSearching")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .shadow(radius: 6)
                        .padding(.horizontal, 32)
                        .padding(.bottom, -18)

                } else {
                    // Loaded — cards scroll beneath the pinned header
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
                            .foregroundStyle(.gray)
                            .shadow(color: .black, radius: 3)
                            .padding(.bottom, 60)
                    }
                    .refreshable {
                        guard let coord = coordinate else { return }
                        await Task.detached(priority: .userInitiated) {
                            await viewModel.load(coordinate: coord, forceRefresh: true)
                        }.value
                    }
                }
            }
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

        // Warm-start: populate the UI from cache before the network fetch.
        // This makes tapping a widget feel instant — the app shows real data
        // immediately while fresh data loads in the background.
        let cacheID = locationID ?? "current"
        viewModel.loadFromCache(id: cacheID)

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
