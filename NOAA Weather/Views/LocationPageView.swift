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
    
    let savedLocation: SavedLocation?
    private var isCurrentLocation: Bool { savedLocation == nil }
    
    private var coordinate: CLLocationCoordinate2D? {
        savedLocation?.coordinate ?? locationManager.coordinate
    }

    var body: some View {
        ZStack {
            // Background
            VideoBackgroundView(videoName: viewModel.background.videoName)
                .ignoresSafeArea()
            Color.black.opacity(0.3).ignoresSafeArea()
            
            Group {
                if viewModel.isLoading && viewModel.current == nil {
                    ProgressView().tint(.white)
                } else if let error = viewModel.errorMessage {
                    ErrorView(message: error) { triggerFetch() }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        WeatherContentView(viewModel: viewModel, selectedDay: $selectedDay)
                        
                        if !isCurrentLocation {
                            deleteButton
                        }
                        
                        Text("Weather provided by NOAA and Open Mateo")
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
            Text("Delete Location")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 15)
    }
}

// MARK: - Supporting Views

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                retry()
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }
}
