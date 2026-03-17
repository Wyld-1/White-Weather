//
//  LocationPageView.swift
//  NOAA Weather
//
//  One page in the swipe carousel. Owns its own WeatherViewModel.
//  Pull-to-refresh uses SwiftUI's native .refreshable.
//  Delete is triggered by pulling past the BOTTOM of the scroll view.

import SwiftUI
import CoreLocation

struct LocationPageView: View {
    let savedLocation: SavedLocation?

    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager

    @State private var viewModel = WeatherViewModel()
    @State private var selectedDay: DailyForecast?
    @State private var showDeleteConfirm = false

    private var isCurrentLocation: Bool { savedLocation == nil }

    var coordinate: CLLocationCoordinate2D? {
        savedLocation?.coordinate ?? locationManager.coordinate
    }

    var body: some View {
        ZStack {
            VideoBackgroundView(videoName: viewModel.background.videoName).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            if viewModel.isLoading && viewModel.current == nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView().tint(.white).scaleEffect(1.5)
                    Text(savedLocation?.name ?? "Getting location…")
                        .foregroundStyle(.white.opacity(0.7)).font(.system(size: 14))
                    Spacer()
                }
            } else if let error = viewModel.errorMessage {
                ErrorView(message: error) {
                    if let coord = coordinate { Task { await viewModel.refresh(coordinate: coord) } }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    WeatherContentView(viewModel: viewModel, selectedDay: $selectedDay)

                    // ── Bottom delete affordance (saved locations only) ──────
                    if !isCurrentLocation {
                        BottomDeleteView(
                            locationName: savedLocation?.name ?? "",
                            showConfirm: $showDeleteConfirm
                        )
                    }
                }
                .refreshable {
                    if let coord = coordinate {
                        await viewModel.refresh(coordinate: coord)
                    }
                }
            }
        }
        .sheet(item: $selectedDay) { day in
            DayDetailSheet(day: day,
                           globalLow: viewModel.globalLow,
                           globalHigh: viewModel.globalHigh)
                .presentationDetents([.fraction(0.67)])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Remove \(savedLocation?.name ?? "this location")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let loc = savedLocation { store.remove(id: loc.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: locationManager.coordinate?.latitude)  { _, _ in loadIfNeeded() }
        .onChange(of: locationManager.coordinate?.longitude) { _, _ in loadIfNeeded() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            if let coord = coordinate { Task { await viewModel.refresh(coordinate: coord) } }
        }
    }

    private func loadIfNeeded() {
        guard let coord = coordinate else { return }
        // For saved locations, pin the display name before loading so
        // geocoding never overwrites it (e.g. White Pass → Packwood).
        if let name = savedLocation?.name, !name.isEmpty {
            viewModel.setLocationName(name)
        }
        Task { await viewModel.load(coordinate: coord) }
    }
}

// MARK: - Bottom delete affordance

struct BottomDeleteView: View {
    let locationName: String
    @Binding var showConfirm: Bool

    var body: some View {
        VStack(spacing: 16) {
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 40, height: 1)

            Button {
                showConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("Remove \(locationName)")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity)
    }
}
