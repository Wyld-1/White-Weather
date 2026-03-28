/* WelcomeView.swift
 * White Weather
 *
 * Shown once on first launch. Dismissed by tapping the button,
 * which sets a UserDefaults flag so it never appears again.
 */

import SwiftUI

struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            VideoBackgroundView(videoName: "sun").ignoresSafeArea()
            
            RadialGradient(stops: [.init(color: .blue.opacity(0.4), location: 0),
                                   .init(color: .black.opacity(0.7), location: 0.8)],
                           center: .bottom, startRadius: 10, endRadius: 600).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App icon + name
                VStack(spacing: 16) {
                    Image(systemName: "cloud.sun.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 72, weight: .thin))
                        .shadow(color: .black.opacity(0.3), radius: 12)

                    Text("White Weather")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)

                    Text("Accurate forecasts from NOAA,\npresented the way they should be.")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .shadow(radius: 3)
                }

                Spacer()
                Spacer()

                // Dismiss button
                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 56)
            }
        }
    }
}
