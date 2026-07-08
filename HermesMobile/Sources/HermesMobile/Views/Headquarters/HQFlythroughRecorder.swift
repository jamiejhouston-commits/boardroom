import AVFoundation
import SceneKit
import SwiftUI
import UIKit

// MARK: - The camera path

/// The ~21s cinematic route through the HQ, as a pure function of time
/// (seek-safe — every frame's pose depends only on `t`, never on the last
/// frame). Waypoints come straight from `HQSceneBuilder`'s floor plan:
/// lobby dolly from the south entrance, orbit of the command dais ("war
/// table"), a tracking pass along the Production Line on the west wall, then
/// the rise through the ceiling to the divisions floor (elevation 8).
/// Each segment eases with smoothstep, so joints land with zero velocity.
enum HQFlythroughPath {
    static let duration: TimeInterval = segments.reduce(0) { $0 + $1.duration }

    private enum Segment {
        case dolly(from: SCNVector3, to: SCNVector3, lookFrom: SCNVector3, lookTo: SCNVector3)
        case orbit(center: SCNVector3, radius: Float, height: Float,
                   angleFrom: Float, angleTo: Float, look: SCNVector3)
    }

    // Continuity invariant: each segment starts exactly where the previous one
    // ends (the orbit's angle-0 pose equals the lobby dolly's end pose; its
    // angle −2.3 pose equals the approach dolly's start).
    private static let segments: [(duration: TimeInterval, segment: Segment)] = [
        // 1 · Lobby dolly — drift in over the lounge toward the glowing dais.
        (4.5, .dolly(from: SCNVector3(0, 1.7, 14.0), to: SCNVector3(0, 2.4, 6.8),
                     lookFrom: SCNVector3(0, 1.6, 0), lookTo: SCNVector3(0, 1.1, 0))),
        // 2 · War-table orbit — a slow 130° sweep around the command center.
        (5.0, .orbit(center: SCNVector3(0, 1.1, 0), radius: 6.8, height: 2.4,
                     angleFrom: 0, angleTo: -2.3, look: SCNVector3(0, 1.1, 0))),
        // 3 · Approach — break off the orbit, over the Decision Desk, toward
        //     the west-wall Production Line.
        (3.0, .dolly(from: SCNVector3(-5.07, 2.4, -4.53), to: SCNVector3(-16.6, 1.8, 3.2),
                     lookFrom: SCNVector3(0, 1.1, 0), lookTo: SCNVector3(-19.6, 1.3, 4.6))),
        // 4 · Production pass — track along the three device totems (z 4.9 → 9.1).
        (3.5, .dolly(from: SCNVector3(-16.6, 1.8, 3.2), to: SCNVector3(-16.6, 1.8, 10.4),
                     lookFrom: SCNVector3(-19.6, 1.3, 4.6), lookTo: SCNVector3(-19.6, 1.3, 9.4))),
        // 5 · The rise — straight up beside the divisions shell (x −17.7 clears
        //     the storey slab at ±16.5 and its west wall at ±16.2), the wall
        //     face filling frame like an elevator shaft…
        (2.5, .dolly(from: SCNVector3(-16.6, 1.8, 10.4), to: SCNVector3(-17.7, 13.0, 10.3),
                     lookFrom: SCNVector3(-19.6, 1.3, 9.4), lookTo: SCNVector3(0, 8.4, 0))),
        // 6 · …then break over the wall top (12.6) for the divisions reveal —
        //     six bays around the center aisle, seen from above.
        (3.0, .dolly(from: SCNVector3(-17.7, 13.0, 10.3), to: SCNVector3(0, 12.8, 9.8),
                     lookFrom: SCNVector3(0, 8.4, 0), lookTo: SCNVector3(0, 8.35, -1.5))),
    ]

    static func pose(at t: TimeInterval) -> (position: SCNVector3, target: SCNVector3) {
        var remaining = min(max(t, 0), duration)
        for (index, entry) in segments.enumerated() {
            if remaining <= entry.duration || index == segments.count - 1 {
                let u = smoothstep(Float(min(remaining / entry.duration, 1)))
                return sample(entry.segment, u: u)
            }
            remaining -= entry.duration
        }
        return sample(segments[segments.count - 1].segment, u: 1)
    }

    private static func sample(_ segment: Segment, u: Float)
        -> (position: SCNVector3, target: SCNVector3) {
        switch segment {
        case let .dolly(from, to, lookFrom, lookTo):
            return (lerp(from, to, u), lerp(lookFrom, lookTo, u))
        case let .orbit(center, radius, height, angleFrom, angleTo, look):
            let angle = angleFrom + (angleTo - angleFrom) * u
            let position = SCNVector3(center.x + radius * sin(angle), height,
                                      center.z + radius * cos(angle))
            return (position, look)
        }
    }

    private static func smoothstep(_ x: Float) -> Float { x * x * (3 - 2 * x) }

    private static func lerp(_ a: SCNVector3, _ b: SCNVector3, _ u: Float) -> SCNVector3 {
        SCNVector3(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)
    }
}

// MARK: - Frame + encoder

/// One captured frame headed for the encoder. CGImage is immutable, so
/// shipping it across the actor boundary is sound.
private struct FlythroughFrame: @unchecked Sendable {
    let image: CGImage
    let index: Int
}

/// H.264 writer for the flythrough — 1080×1920 portrait, 30fps. Lives on its
/// own actor so pixel-buffer drawing and encoding never touch the main thread;
/// the main actor only snapshots the SCNView and yields frames across.
private actor FlythroughEncoder {
    static let width = 1080
    static let height = 1920
    static let fps: Int32 = 30

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-flythrough-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: FlythroughFrame) async {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Self.width, height: Self.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) {
            // Aspect-fill the (screen-sized) snapshot into the portrait frame.
            let iw = CGFloat(frame.image.width), ih = CGFloat(frame.image.height)
            let scale = max(CGFloat(Self.width) / iw, CGFloat(Self.height) / ih)
            let dw = iw * scale, dh = ih * scale
            context.draw(frame.image, in: CGRect(x: (CGFloat(Self.width) - dw) / 2,
                                                 y: (CGFloat(Self.height) - dh) / 2,
                                                 width: dw, height: dh))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime:
            CMTime(value: Int64(frame.index), timescale: Self.fps))
    }

    /// Close the file. Returns the finished .mp4, or nil if writing failed.
    func finish() async -> URL? {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed { return url }
        try? FileManager.default.removeItem(at: url)
        return nil
    }
}

// MARK: - Recording controller

/// Drives the recording: a CADisplayLink poses the camera per output frame
/// (frame index → path time, so a hitch never bends the camera path), grabs an
/// `SCNView.snapshot()`, and hands the frame to the encoder actor through an
/// ordered stream. Back-pressure: when the encoder falls behind, display ticks
/// are skipped — wall-clock recording stretches, the output stays a perfect
/// 30fps.
@MainActor
private final class HQFlythroughController: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRecording = false
    @Published private(set) var videoURL: URL?
    @Published var errorMessage: String?

    weak var scnView: SCNView?
    var cameraNode: SCNNode?

    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var pending = 0
    private var continuation: AsyncStream<FlythroughFrame>.Continuation?
    private var drainTask: Task<Void, Never>?

    private static let fps = 30
    private var totalFrames: Int { Int(HQFlythroughPath.duration * Double(Self.fps)) }

    func applyPose(at t: TimeInterval) {
        guard let cameraNode else { return }
        let pose = HQFlythroughPath.pose(at: t)
        cameraNode.position = pose.position
        cameraNode.look(at: pose.target)
    }

    func record() {
        guard !isRecording, scnView != nil else { return }
        let encoder: FlythroughEncoder
        do {
            encoder = try FlythroughEncoder()
        } catch {
            errorMessage = "Couldn't start the recorder: \(error.localizedDescription)"
            return
        }

        frameIndex = 0
        pending = 0
        progress = 0
        videoURL = nil
        errorMessage = nil
        isRecording = true

        let (stream, continuation) = AsyncStream.makeStream(
            of: FlythroughFrame.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        // Single consumer keeps frame order; appends run on the encoder actor.
        drainTask = Task { [weak self] in
            for await frame in stream {
                await encoder.append(frame)
                self?.pending -= 1
            }
            let url = await encoder.finish()
            guard let self, !Task.isCancelled else { return }
            self.videoURL = url
            if url == nil { self.errorMessage = "Recording failed to finalize." }
            self.isRecording = false
        }

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard isRecording, let scnView else { return }
        guard pending < 4 else { return }     // encoder behind — skip this tick
        guard frameIndex < totalFrames else {
            link.invalidate()
            displayLink = nil
            continuation?.finish()            // drain task finalizes the file
            continuation = nil
            return
        }
        applyPose(at: Double(frameIndex) / Double(Self.fps))
        guard let image = scnView.snapshot().cgImage else { return }
        pending += 1
        continuation?.yield(FlythroughFrame(image: image, index: frameIndex))
        frameIndex += 1
        progress = Double(frameIndex) / Double(totalFrames)
    }

    /// Abandon an in-flight recording (view dismissed mid-record).
    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        continuation?.finish()
        continuation = nil
        drainTask?.cancel()
        drainTask = nil
        isRecording = false
    }
}

// MARK: - Scene host

/// The recorder's OWN SCNView of the HQ — the same environment + staff + camera
/// rig `HQSceneView` builds, minus gestures and live-state plumbing. Building a
/// private copy keeps the walkable HQ untouched while this one gets flown.
private struct HQFlythroughSceneView: UIViewRepresentable {
    let controller: HQFlythroughController
    var agents: [OrgAgent]
    var companyState: CompanyState

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.043, green: 0.055, blue: 0.082, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.preferredFramesPerSecond = 60
        view.isPlaying = true

        let scene = SCNScene()
        HQSceneBuilder.buildEnvironment(into: scene)
        // The builder ships the divisions storey hidden (the walkable HQ shows
        // it only while roaming upstairs); the flythrough's finale needs it.
        scene.rootNode
            .childNode(withName: HQDivisionsFloor.floorNodeName, recursively: false)?
            .isHidden = false
        for placement in HQLayout.placements(for: agents) {
            let node = HQAgentNode(placement: placement)
            node.applyStatus(AgentStatusResolver.status(for: placement.agent, in: companyState))
            scene.rootNode.addChildNode(node)
        }

        // Same proven camera (HDR + bloom 0.85 threshold); we drive its node
        // directly along the flythrough path instead of using its modes.
        let rig = HQCameraController()
        rig.attach(to: scene)
        view.pointOfView = rig.cameraNode
        view.scene = scene

        controller.scnView = view
        controller.cameraNode = rig.cameraNode
        controller.applyPose(at: 0)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - The recorder screen

/// Full-screen flythrough recorder, presented from the War Room. Watch the
/// camera fly the floor live while it records; a progress ring tracks the
/// capture, and the finished ~21s portrait .mp4 lands in a share sheet.
struct HQFlythroughRecorderView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = HQFlythroughController()

    var body: some View {
        ZStack {
            HQFlythroughSceneView(controller: controller,
                                  agents: org.agents,
                                  companyState: company.state)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }
            .padding(20)
        }
        .statusBarHidden()
        .onDisappear { controller.cancel() }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("HQ Flythrough")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Lobby · war table · production line · divisions")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button {
                controller.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 14) {
            if let message = controller.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(10)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            if controller.isRecording {
                recordingRing
            } else if let url = controller.videoURL {
                ShareLink(item: url) {
                    Label("Share clip", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 13)
                        .background(Color(uiColor: HQSceneBuilder.emerald), in: Capsule())
                }
                Button("Record again") { controller.record() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Button { controller.record() } label: {
                    Label("Record flythrough", systemImage: "record.circle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 13)
                        .background(Color(uiColor: HQSceneBuilder.emerald), in: Capsule())
                }
                Text("~21 seconds · 1080×1920 · shares as .mp4")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.bottom, 12)
    }

    private var recordingRing: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: controller.progress)
                    .stroke(Color(uiColor: HQSceneBuilder.gold),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: controller.progress)
                Text("\(Int(controller.progress * 100))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)
            Text("Recording the flythrough…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(16)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }
}
