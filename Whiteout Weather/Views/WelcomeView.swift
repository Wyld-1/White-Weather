/* WelcomeView.swift
 * Whiteout Weather
 *
 * Shown once on first launch. Lets the user pick their unit system and
 * time format before entering the app. Choices are saved to AppSettings
 * immediately so the first weather fetch uses the right units.
 * Dismissed by tapping "Get Started", which sets the hasLaunched flag.
 */

import SwiftUI

struct WelcomeView: View {
    let onDismiss: () -> Void

    @State private var unitSystem: UnitSystem  = AppSettings.shared.unitSystem
    @State private var timeFormat: TimeFormat  = AppSettings.shared.timeFormat

    var body: some View {
        ZStack {
            GradientBackgroundView(condition: .clear, timeOfDay: .day)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 8) {
                    Image("WhiteoutGoggles")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 100)
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 10)
                        .padding(.bottom, 20)

                    Text("Whiteout Weather")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(.white)

                    Text("I'll get you on your way in no time!")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                Spacer()
                Spacer()

                VStack(spacing: 20) {
                    SettingPicker(
                        label: "Units",
                        options: [("US", UnitSystem.us), ("Metric", UnitSystem.metric)],
                        selection: $unitSystem
                    )
                    
                    Divider().background(.white.opacity(0.3))
                    
                    SettingPicker(
                        label: "Time",
                        options: [("12-hour", TimeFormat.twelve), ("24-hour", TimeFormat.twentyFour)],
                        selection: $timeFormat
                    )
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 24)

                Group {
                    if #available(iOS 26.0, *) {
                        Button(action: {
                            Haptics.shared.notification(.success); onDismiss()
                        }) {
                            Text("Get Started")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.barrelRed)
                        .buttonBorderShape(.capsule)
                        .shadow(color: Color.barrelRed.opacity(0.5), radius: 12, y: 5)
                    } else {
                        Button(action: {
                            Haptics.shared.notification(.success); onDismiss()
                        }) {
                            Text("Get Started")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(colors: [Color(red: 0.82, green: 0.28, blue: 0.22), Color(red: 0.62, green: 0.13, blue: 0.13)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .clipShape(Capsule())
                                .shadow(color: Color(red: 0.62, green: 0.13, blue: 0.13).opacity(0.5), radius: 12, y: 5)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 35)
            }
            
            VStack {
                Spacer()
                Image("Whiteout")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 200)
                    .padding(.leading, -230)
                    .shadow(color: .black.opacity(1), radius: 10, y: 5)
            }
            .ignoresSafeArea()
        }
        .onChange(of: unitSystem) { AppSettings.shared.unitSystem = unitSystem }
        .onChange(of: timeFormat) { AppSettings.shared.timeFormat = timeFormat }
    }
}

private struct SettingPicker<T: Equatable>: View {
    let label: String
    let options: [(String, T)]
    @Binding var selection: T
    
    @Namespace private var pickerTransition

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            
            Spacer()
            
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { title, value in
                    let isSelected = selection == value
                    
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.7))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white)
                                    .matchedGeometryEffect(id: "activeBackground", in: pickerTransition)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selection = value
                            }
                        }
                }
            }
            .padding(4)
            .frame(width: 180)
            .background(.black.opacity(0.3))
            .clipShape(Capsule())
        }
    }
}

#Preview {
    WelcomeView(onDismiss: {})
        .environmentObject(AppSettings.shared)
        .preferredColorScheme(.dark)
}
