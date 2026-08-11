import SwiftUI

/// Working name only. Not final — never hardcode it in user-facing strings.
enum AppNaming {
    static let displayName = String(localized: "Video Overlap", comment: "Working name of the app")
}

@main
struct SendSocietyApp: App {
    @State private var model = AppModel()

    init() {
        // RTMPose lives in the app target because ONNX Runtime does; Core has to
        // keep building on macOS for the tests and the CLI. Registering it here
        // is the seam.
        if RTMPoseOnnxExtractor.isInstalled {
            PoseExtractorFactory.register(.rtmPose) { RTMPoseOnnxExtractor() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            SessionListView()
        }
    }
}
