import AppIntents
import SwiftUI
import WidgetKit

@main
struct PauseCamControlsBundle: WidgetBundle {
    var body: some Widget {
        LaunchPauseCamControl()
    }
}

/// Control Center button that launches PauseCam — a drop-in replacement for
/// the stock Camera control. Users add it via Control Center's
/// "Add a Control" editor (and on iPhone it can also replace the Lock Screen
/// camera shortcut). The intent itself lives in Shared/ and is compiled into
/// both targets so the system executes it in the app process.
struct LaunchPauseCamControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.drewmerc.PauseCam.launch") {
            ControlWidgetButton(action: LaunchPauseCamIntent()) {
                Label("PauseCam", systemImage: "video.fill")
            }
        }
        .displayName("PauseCam")
        .description("Opens PauseCam to record video with pause and resume.")
    }
}
