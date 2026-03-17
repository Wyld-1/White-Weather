//
//  LocationPageView.swift
//  NOAA Weather
//
//  One page in the swipe carousel. Owns its own WeatherViewModel.

import SwiftUI
import MapKit

struct LocationPageView: View {
    @Environment(LocationStore.self) private var store // Fix: Store in scope
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
                    }
                }
            }
        }
        .sheet(item: $selectedDay) { day in
            // This will now trigger because selectedDay is no longer nil
            DayDetailSheet(
                day: day,
                globalLow: viewModel.globalLow,
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
        // Optimization: Fetch data ONLY when the coordinate changes
        .task(id: coordinate?.latitude) {
            triggerFetch()
        }
    }

    private func triggerFetch() {
        guard let coord = coordinate else { return }
        
        // If we are looking at a saved location, set its known name FIRST
        if let savedLoc = savedLocation {
            viewModel.setLocationName(savedLoc.name)
        }
        
        // Now tell it to load the data. We pass skipGeocode = true
        Task {
            await viewModel.load(
                coordinate: coord,
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
        .padding(.bottom, 80)
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
