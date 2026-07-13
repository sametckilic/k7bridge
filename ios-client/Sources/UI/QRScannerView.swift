@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (URL) -> Void
    func makeUIViewController(context: Context) -> ScannerViewController { let value = ScannerViewController(); value.onCode = onCode; return value }
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((URL) -> Void)?
    private let sessionBox = CaptureSessionBox()
    private var session: AVCaptureSession { sessionBox.session }
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input); let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds
        view.layer.addSublayer(preview)
        let sessionBox = sessionBox
        DispatchQueue.global(qos: .userInitiated).async { sessionBox.session.startRunning() }
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds }
    deinit { session.stopRunning() }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              let url = URL(string: value), url.scheme == "k7bridge" else { return }
        delivered = true; session.stopRunning(); onCode?(url)
    }
}
