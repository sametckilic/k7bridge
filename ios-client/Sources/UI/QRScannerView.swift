@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (URL) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.example.K7Bridge.qr-session", qos: .userInitiated)
}

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((URL) -> Void)?

    private let sessionBox = CaptureSessionBox()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let messageLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let box = sessionBox
        box.queue.async { if box.session.isRunning { box.session.stopRunning() } }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            messageLabel.text = "Kamera izni bekleniyor…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureSession() }
                    else { self.showMessage("QR taramak için Ayarlar'dan kamera izni verin.") }
                }
            }
        case .denied, .restricted:
            showMessage("Kamera erişimi kapalı. Ayarlar → Gizlilik ve Güvenlik → Kamera bölümünden K7Bridge'e izin verin.")
        @unknown default:
            showMessage("Kamera kullanılamıyor.")
        }
    }

    private func configureSession() {
        messageLabel.text = "Kamera hazırlanıyor…"
        let box = sessionBox
        box.queue.async { [weak self] in
            guard let self,
                  let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                DispatchQueue.main.async { [weak self] in self?.showMessage("Kamera başlatılamadı.") }
                return
            }
            let session = box.session
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { [weak self] in self?.showMessage("Kamera girişi kullanılamıyor.") }
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { [weak self] in self?.showMessage("QR okuyucu kullanılamıyor.") }
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
            session.commitConfiguration()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.insertSublayer(preview, at: 0)
                self.previewLayer = preview
                self.messageLabel.text = "QR kodunu çerçeveye alın"
                self.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
                self.messageLabel.layer.cornerRadius = 12
                self.messageLabel.clipsToBounds = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    private func showMessage(_ message: String) {
        messageLabel.text = message
        messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              let url = URL(string: value), url.scheme?.lowercased() == "k7bridge" else { return }
        delivered = true
        let box = sessionBox
        box.queue.async { if box.session.isRunning { box.session.stopRunning() } }
        onCode?(url)
    }
}
