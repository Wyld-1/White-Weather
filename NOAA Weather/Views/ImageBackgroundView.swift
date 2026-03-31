import SwiftUI

/* ImageBackgroundView
 * White Weather
 *
 * Displays a static JPEG background matched to the current season + weather condition.
 * Images live in NOAA Weather/Backgrounds/[Season]/[imageName].jpeg
 * and are added to the Xcode asset catalogue or loaded directly from the bundle.
 *
 * Cross-fades when the image name changes (e.g. swiping to a different location
 * that has different weather).
 */
struct ImageBackgroundView: View {
    let imageName: String

    var body: some View {
        GeometryReader { geo in
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .animation(.easeInOut(duration: 0.6), value: imageName)
        }
        .ignoresSafeArea()
    }
}

