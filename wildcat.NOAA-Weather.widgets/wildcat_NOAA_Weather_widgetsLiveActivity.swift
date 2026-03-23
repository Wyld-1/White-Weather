//
//  wildcat_NOAA_Weather_widgetsLiveActivity.swift
//  wildcat.NOAA-Weather.widgets
//
//  Created by Liam Lefohn on 3/23/26.
//

/*
import ActivityKit
import WidgetKit
import SwiftUI

struct wildcat_NOAA_Weather_widgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct wildcat_NOAA_Weather_widgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: wildcat_NOAA_Weather_widgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension wildcat_NOAA_Weather_widgetsAttributes {
    fileprivate static var preview: wildcat_NOAA_Weather_widgetsAttributes {
        wildcat_NOAA_Weather_widgetsAttributes(name: "World")
    }
}

extension wildcat_NOAA_Weather_widgetsAttributes.ContentState {
    fileprivate static var smiley: wildcat_NOAA_Weather_widgetsAttributes.ContentState {
        wildcat_NOAA_Weather_widgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: wildcat_NOAA_Weather_widgetsAttributes.ContentState {
         wildcat_NOAA_Weather_widgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: wildcat_NOAA_Weather_widgetsAttributes.preview) {
   wildcat_NOAA_Weather_widgetsLiveActivity()
} contentStates: {
    wildcat_NOAA_Weather_widgetsAttributes.ContentState.smiley
    wildcat_NOAA_Weather_widgetsAttributes.ContentState.starEyes
}
*/
