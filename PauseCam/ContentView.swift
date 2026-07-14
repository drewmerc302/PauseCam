import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingLastClip = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isCameraAccessDenied {
                CameraAccessDeniedView()
            } else {
                CameraPreview(controller: camera)
                    .ignoresSafeArea()

                VStack {
                    statusBar
                        .padding(.top, 12)
                    Spacer()
                    if !camera.zoomOptions.isEmpty {
                        zoomBar
                            .padding(.bottom, 14)
                    }
                    controls
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 24)

                if camera.didSaveToPhotos {
                    savedToast
                }
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            camera.configure()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Backgrounding mid-recording would strand an unfinished file; stop
            // and save instead. `.inactive` is deliberately ignored — Control
            // Center, notification banners, and system prompts all pass through
            // it while frames keep flowing.
            if newPhase == .background, camera.state == .recording || camera.state == .paused {
                camera.stop()
            }
        }
        .onChange(of: camera.didSaveToPhotos) { _, saved in
            if saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { camera.didSaveToPhotos = false }
                }
            }
        }
        .alert(
            "PauseCam",
            isPresented: Binding(
                get: { camera.errorMessage != nil },
                set: { if !$0 { camera.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if camera.state == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .modifier(PulseEffect())
            }

            Text(timeString(camera.recordedSeconds))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)

            if camera.state == .paused {
                Text("PAUSED")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)
            }

            if camera.state == .recording || camera.state == .paused {
                Text("Scene \(camera.sceneNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
    }

    // MARK: - Zoom

    private var zoomBar: some View {
        HStack(spacing: 10) {
            ForEach(camera.zoomOptions) { option in
                Button {
                    camera.setZoom(option)
                } label: {
                    Text(option.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(camera.selectedZoomID == option.id ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel("Zoom \(option.label)")
            }
        }
        .padding(6)
        .background(.black.opacity(0.25), in: Capsule())
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Button {
                camera.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2)
                    .foregroundStyle(camera.state == .idle && !camera.isSwitchingCamera ? .white : .gray)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .disabled(camera.state != .idle || camera.isSwitchingCamera)
            .accessibilityLabel(camera.isUsingFrontCamera ? "Switch to back camera" : "Switch to front camera")

            Spacer()

            recordButton

            Spacer()

            trailingControl
        }
    }

    /// Stop button while recording/paused; last-clip thumbnail while idle.
    @ViewBuilder
    private var trailingControl: some View {
        if camera.state == .recording || camera.state == .paused {
            Button {
                camera.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.red.opacity(0.85), in: Circle())
            }
            .accessibilityLabel("Stop and save")
        } else if let thumbnail = camera.lastClipThumbnail {
            Button {
                isShowingLastClip = true
            } label: {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    }
            }
            .disabled(camera.state == .saving)
            .accessibilityLabel("Play last saved video")
            .sheet(isPresented: $isShowingLastClip) {
                LastClipPlayerView(url: CameraController.lastClipURL)
            }
        } else {
            Color.clear.frame(width: 56, height: 56)
        }
    }

    private var recordButton: some View {
        Button {
            switch camera.state {
            case .idle:
                camera.startRecording()
            case .recording:
                camera.pause()
            case .paused:
                camera.resume()
            case .saving:
                break
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)

                switch camera.state {
                case .idle:
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                case .recording:
                    Image(systemName: "pause.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(.red, in: Circle())
                case .paused:
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                        .overlay {
                            Image(systemName: "record.circle")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                        }
                case .saving:
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .disabled(camera.state == .saving || camera.isSwitchingCamera)
        .accessibilityLabel(recordButtonLabel)
    }

    private var recordButtonLabel: String {
        switch camera.state {
        case .idle: return "Start recording"
        case .recording: return "Pause recording"
        case .paused: return "Resume recording"
        case .saving: return "Saving"
        }
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 130)
        }
        .transition(.opacity)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// Slow opacity pulse for the recording dot.
private struct PulseEffect: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

/// Full-screen playback of the last saved clip (the app's own cached copy —
/// add-only Photos access can't read the library back).
struct LastClipPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// Shown when camera permission is denied — the app is unusable without it.
struct CameraAccessDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.gray)
            Text("Camera Access Needed")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("PauseCam can't record without the camera. Enable camera access in Settings.")
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
