import AVFoundation
import CoreVideo

/// 카메라 프레임을 작게(가로 약 320px) 줄여 RGB 배열로 보관하고, 여러 장을 평균 낸다.
/// 영상은 메모리에서만 쓰고 저장하거나 전송하지 않는다.
final class CameraSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "TouchBridge.camera")
    private let lock = NSLock()
    private let newFrame = DispatchSemaphore(value: 0)
    private var frame: [Float] = []
    private var frameCount = 0
    private(set) var width = 0, height = 0

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] } else { types.append(.externalUnknown) }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        // 아이폰을 맨 앞으로 (가상 카메라는 제외)
        return all.filter { !$0.modelID.localizedCaseInsensitiveContains("virtual") && !$0.localizedName.localizedCaseInsensitiveContains("virtual") }
            .sorted { isPhone($0) && !isPhone($1) }
    }

    static func isPhone(_ d: AVCaptureDevice) -> Bool {
        d.modelID.hasPrefix("iPhone") || d.localizedName.localizedCaseInsensitiveContains("iPhone")
    }

    /// 측정을 틀어지게 하는 비디오 효과 (사용자만 끌 수 있음). 반응(제스처)은 손동작이 없으면 색에 영향이 없어 제외.
    static func activeVideoEffects() -> [String] {
        var on: [String] = []
        if #available(macOS 12.0, *), AVCaptureDevice.isPortraitEffectEnabled { on.append("인물 사진") }
        if #available(macOS 13.0, *), AVCaptureDevice.isStudioLightEnabled { on.append("스튜디오 조명") }
        if #available(macOS 15.0, *), AVCaptureDevice.isBackgroundReplacementEnabled { on.append("배경") }
        return on
    }

    func start(_ device: AVCaptureDevice) throws {
        stop()
        if #available(macOS 12.3, *) {
            AVCaptureDevice.centerStageControlMode = .app   // 센터 스테이지는 앱이 끌 수 있음
            AVCaptureDevice.isCenterStageEnabled = false
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.addInput(try AVCaptureDeviceInput(device: device))
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let step = max(1, W / 320), ow = W / step, oh = H / step
        var out = [Float](repeating: 0, count: ow * oh * 3)
        for y in 0..<oh {
            let row = base + (y * step) * bpr
            for x in 0..<ow {
                let p = row + (x * step) * 4, i = (y * ow + x) * 3
                out[i] = Float(p[2]) / 255; out[i + 1] = Float(p[1]) / 255; out[i + 2] = Float(p[0]) / 255
            }
        }
        lock.lock()
        width = ow; height = oh; frame = out; frameCount += 1
        lock.unlock()
        newFrame.signal()
    }

    /// 지금부터 들어오는 새 프레임 n장의 평균 (메인이 아닌 스레드에서 호출). 시간 안에 못 받으면 nil.
    func average(_ n: Int, timeout: TimeInterval = 5) -> [Float]? {
        while newFrame.wait(timeout: .now()) == .success {}   // 쌓인 신호 버림
        var acc: [Float] = [], got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < n {
            guard newFrame.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return nil }
            lock.lock(); let f = frame; lock.unlock()
            if acc.count != f.count { acc = [Float](repeating: 0, count: f.count); got = 0 }
            for i in 0..<f.count { acc[i] += f[i] }
            got += 1
        }
        return acc.map { $0 / Float(n) }
    }
}
