import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            CallsView().tabItem { Label("Telefon", systemImage: "phone.fill") }
            MessagesView().tabItem { Label("Mesajlar", systemImage: "message.fill") }
            StatusView().tabItem { Label("Gateway", systemImage: "antenna.radiowaves.left.and.right") }
            PairingView().tabItem { Label("Ayarlar", systemImage: "gearshape.fill") }
        }
        .tint(.indigo)
        .controlSize(.large)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if model.connection.connected { model.refreshAll() }
            }
        }
    }
}

private struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""

    var body: some View {
        NavigationStack {
            ZStack {
                K7Background()
                ScrollView {
                    VStack(spacing: 20) {
                        ConnectionHero(phase: model.connection.phase,
                                       detail: model.connection.lastError,
                                       retry: model.connection.reconnect)

                        K7Card {
                            VStack(alignment: .leading, spacing: 16) {
                                K7SectionTitle(title: "SIM üzerinden ara",
                                               subtitle: "Arama eski iPhone'daki fiziksel SIM ile yapılır")
                                HStack(spacing: 12) {
                                    TextField("05xx xxx xx xx", text: $number)
                                        .keyboardType(.phonePad)
                                        .textContentType(.telephoneNumber)
                                        .font(.title2.monospacedDigit().weight(.semibold))
                                        .padding(.horizontal, 18)
                                        .frame(height: 64)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                                    Button {
                                        model.dial(number)
                                        UIApplication.shared.k7DismissKeyboard()
                                    } label: {
                                        Image(systemName: "phone.fill")
                                            .font(.title2)
                                            .frame(width: 38, height: 38)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.circle)
                                    .tint(.green)
                                    .disabled(number.isEmpty || !model.connection.connected)
                                }
                            }
                        }

                        if let call = model.call {
                            ActiveCallCard(call: call)
                        }

                        HStack(spacing: 14) {
                            MetricTile(title: "Operatör", value: model.device.carrier ?? "Bilinmiyor",
                                       symbol: "simcard.fill", tint: .indigo)
                            MetricTile(title: "Gateway pili", value: batteryText(model.device.batteryLevel),
                                       symbol: model.device.charging == true ? "battery.100percent.bolt" : "battery.75percent",
                                       tint: model.device.charging == true ? .green : .blue)
                        }

                        Label(model.device.audioGatePassed
                              ? "Ses fizibilite testi geçmiş; ancak PCM/Opus aktarımı bu build'e henüz bağlanmadı."
                              : "Çağrı kontrolü denenebilir; çift yönlü görüşme sesi henüz hazır değil.",
                              systemImage: "waveform.badge.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Color.orange.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                }
                .k7KeyboardDismissal()
            }
            .navigationTitle("K7Bridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.refreshAll) { Image(systemName: "arrow.clockwise") }
                        .disabled(!model.connection.connected)
                }
            }
        }
    }

    private func batteryText(_ level: Double?) -> String {
        guard let level else { return "Bilinmiyor" }
        return "\(Int((level * 100).rounded()))%"
    }
}

private struct ActiveCallCard: View {
    @EnvironmentObject private var model: AppModel
    let call: GatewayCall

    var body: some View {
        K7Card {
            VStack(spacing: 22) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.indigo)
                VStack(spacing: 6) {
                    Text(call.displayName ?? call.handle).font(.title.bold())
                    Text(call.state.turkishTitle).font(.body).foregroundStyle(.secondary)
                }
                if call.state == .active {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(["1","2","3","4","5","6","7","8","9","*","0","#"], id: \.self) { digit in
                            Button(digit) {
                                model.connection.send(type: "dtmf", payload: DTMFCommand(callId: call.id, digit: digit))
                            }
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                        }
                    }
                }
                HStack(spacing: 14) {
                    if call.state == .incoming {
                        Button(role: .destructive) {
                            model.end(call.id)
                        } label: { Label("Reddet", systemImage: "phone.down.fill").frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.bordered)
                        Button {
                            model.answer(call.id)
                        } label: { Label("Cevapla", systemImage: "phone.fill").frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.borderedProminent).tint(.green)
                    } else {
                        Button(role: .destructive) {
                            model.end(call.id)
                        } label: {
                            Label("Bitir", systemImage: "phone.down.fill").frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ZStack {
                K7Background()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ConnectionHero(phase: model.connection.phase,
                                       detail: model.connection.lastError,
                                       retry: model.connection.reconnect)
                        K7Card {
                            VStack(alignment: .leading, spacing: 12) {
                                K7SectionTitle(title: "Yeni SMS", subtitle: "Mesaj eski iPhone'un SIM hattından gönderilir")
                                TextField("Telefon numarası", text: $number)
                                    .keyboardType(.phonePad)
                                    .font(.body)
                                    .padding(.vertical, 6)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Mesajınızı yazın", text: $text, axis: .vertical)
                                    .lineLimit(3...6)
                                    .font(.body)
                                    .padding(.vertical, 6)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    if model.sendSMS(handle: number, text: text) {
                                        text = ""
                                        UIApplication.shared.k7DismissKeyboard()
                                    }
                                } label: {
                                    Label("SIM üzerinden gönder", systemImage: "paperplane.fill")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(number.isEmpty || text.isEmpty || !model.connection.connected)
                            }
                        }

                        K7SectionTitle(title: "Son mesajlar", subtitle: "Yalnız düz metin SMS")
                        if model.messages.isEmpty {
                            ContentUnavailableView("Henüz SMS yok", systemImage: "message",
                                                   description: Text(model.connection.connected ? "Yenilemek için aşağı çekin." : "Önce gateway bağlantısını kurun."))
                                .padding(.vertical, 36)
                        } else {
                            ForEach(model.messages) { message in MessageRow(message: message) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                }
                .k7KeyboardDismissal()
                .refreshable { model.refreshSMS() }
            }
            .navigationTitle("Mesajlar")
        }
    }
}

private struct MessageRow: View {
    let message: SMSMessage

    var body: some View {
        K7Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(message.handle).font(.title3.bold())
                    Spacer()
                    Text(message.state.turkishTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(message.state == .failed ? .red : .secondary)
                }
                Text(message.text).font(.body).lineSpacing(3)
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                K7Background()
                ScrollView {
                    VStack(spacing: 20) {
                        ConnectionHero(phase: model.connection.phase,
                                       detail: model.connection.lastError,
                                       retry: model.connection.reconnect)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            MetricTile(title: "Operatör", value: model.device.carrier ?? "Bilinmiyor", symbol: "building.2.crop.circle")
                            MetricTile(title: "Şebeke", value: model.device.radioTechnology ?? "Bilinmiyor", symbol: "antenna.radiowaves.left.and.right", tint: .blue)
                            MetricTile(title: "SIM", value: booleanText(model.device.simReady, yes: "Hazır", no: "Hazır değil"), symbol: "simcard", tint: .purple)
                            MetricTile(title: "Sinyal", value: signalText, symbol: "cellularbars", tint: .green)
                            MetricTile(title: "Pil", value: batteryText, symbol: model.device.charging == true ? "battery.100percent.bolt" : "battery.75percent", tint: .green)
                            MetricTile(title: "Hotspot", value: model.device.hotspotEnabled.turkishStatus, symbol: "personalhotspot", tint: .orange)
                        }
                        K7Card {
                            VStack(alignment: .leading, spacing: 12) {
                                K7SectionTitle(title: "Sistem hazırlığı")
                                statusLine("Kontrol kanalı", value: model.connection.connected ? "Hazır" : "Hazır değil", good: model.connection.connected)
                                statusLine("Ses fizibilite kapısı", value: model.device.audioGatePassed ? "Geçti" : "Test bekliyor", good: model.device.audioGatePassed)
                                statusLine("PCM/Opus ses aktarımı", value: "Henüz uygulanmadı", good: false)
                                statusLine("Sıcaklık", value: thermalText, good: model.device.thermalState == "nominal")
                                if let date = model.lastStatusUpdate {
                                    Text("Son güncelleme: \(date.formatted(date: .omitted, time: .standard))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("iOS bir alanı güvenilir biçimde sunmuyorsa K7Bridge yanlış bir 0 değeri göstermek yerine “Bilinmiyor” yazar.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                }
                .k7KeyboardDismissal()
                .refreshable { model.refreshAll() }
            }
            .navigationTitle("Gateway")
        }
    }

    private var signalText: String { model.device.signalBars.map { "\($0)/4" } ?? "Bilinmiyor" }
    private var batteryText: String { model.device.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "Bilinmiyor" }
    private var thermalText: String {
        switch model.device.thermalState {
        case "nominal": return "Normal"
        case "fair": return "Ilık"
        case "serious": return "Yüksek"
        case "critical": return "Kritik"
        default: return "Bilinmiyor"
        }
    }

    private func booleanText(_ value: Bool?, yes: String, no: String) -> String {
        guard let value else { return "Bilinmiyor" }
        return value ? yes : no
    }

    private func statusLine(_ title: String, value: String, good: Bool) -> some View {
        HStack {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(good ? .green : .orange)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var value = ""
    @State private var showingScanner = false
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            ZStack {
                K7Background()
                ScrollView {
                    VStack(spacing: 20) {
                        ConnectionHero(phase: model.connection.phase,
                                       detail: model.connection.lastError,
                                       retry: model.connection.reconnect)
                        K7Card {
                            VStack(alignment: .leading, spacing: 14) {
                                K7SectionTitle(title: "Gateway eşleştirme",
                                               subtitle: "QR kodunu tarayın veya eşleştirme metnini yapıştırın")
                                TextField("k7bridge://pair?d=…", text: $value, axis: .vertical)
                                    .lineLimit(2...5)
                                    .font(.body.monospaced())
                                    .padding(.vertical, 6)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Button {
                                        showingScanner = true
                                    } label: {
                                        Label("QR tara", systemImage: "qrcode.viewfinder").frame(minHeight: 46)
                                    }
                                    .buttonStyle(.bordered)
                                    Button {
                                        model.pair(text: value)
                                        UIApplication.shared.k7DismissKeyboard()
                                    } label: {
                                        Label("Eşleştir", systemImage: "link")
                                            .frame(maxWidth: .infinity, minHeight: 46)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                if let notice = model.pairingNotice {
                                    Label(notice, systemImage: model.connection.connected ? "checkmark.shield.fill" : "hourglass")
                                    .font(.subheadline)
                                        .foregroundStyle(model.connection.connected ? .green : .secondary)
                                }
                            }
                        }

                        if let pairing = model.pairing {
                            K7Card {
                                VStack(alignment: .leading, spacing: 12) {
                                    K7SectionTitle(title: "Kayıtlı gateway")
                                    LabeledContent("Adres", value: pairing.document.host)
                                    LabeledContent("Port", value: String(pairing.document.port))
                                    LabeledContent("Kimlik", value: String(pairing.document.gatewayId.prefix(8)))
                                    Divider()
                                    Button("Bu gateway'i unut", role: .destructive) { confirmForget = true }
                                }
                            }
                        }

                        K7Card {
                            VStack(alignment: .leading, spacing: 12) {
                                K7SectionTitle(title: "Arama ayarları")
                                LabeledContent("Varsayılan ülke kodu") {
                                    TextField("+90", text: $model.countryCode)
                                        .keyboardType(.phonePad)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }

                        K7Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Yerel test sürümü", systemImage: "hammer.fill").font(.headline)
                                Text("Ücretsiz Apple hesabıyla kurulan uygulama 7 günde bir yeniden imzalanır. APNs ve kilit ekranında uzaktan uyandırma bu sürümde kapalıdır.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text(versionText).font(.footnote).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                }
                .k7KeyboardDismissal()
            }
            .navigationTitle("Ayarlar")
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRScannerView { url in
                        showingScanner = false
                        model.pair(url: url)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Gateway QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Kapat") { showingScanner = false }
                        }
                    }
                }
            }
            .confirmationDialog("Gateway eşleştirmesi silinsin mi?", isPresented: $confirmForget,
                                titleVisibility: .visible) {
                Button("Gateway'i unut", role: .destructive, action: model.forgetGateway)
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "K7Bridge \(version) (\(build))"
    }
}

private extension CallState {
    var turkishTitle: String {
        switch self {
        case .idle: return "Hazır"
        case .incoming: return "Gelen çağrı"
        case .dialing: return "Aranıyor"
        case .connecting: return "Bağlanıyor"
        case .active: return "Görüşme sürüyor"
        case .ended: return "Sona erdi"
        case .failed: return "Başarısız"
        }
    }
}

private extension SMSState {
    var turkishTitle: String {
        switch self {
        case .queued: return "Bekliyor"
        case .sent: return "Gönderildi"
        case .failed: return "Başarısız"
        }
    }
}

private extension View {
    func k7KeyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Bitti") { UIApplication.shared.k7DismissKeyboard() }
                        .fontWeight(.semibold)
                }
            }
    }
}

private extension UIApplication {
    func k7DismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
