import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            CallsView().tabItem { Label("Arama", systemImage: "phone") }
            MessagesView().tabItem { Label("SMS", systemImage: "message") }
            StatusView().tabItem { Label("Durum", systemImage: "antenna.radiowaves.left.and.right") }
            PairingView().tabItem { Label("Ayarlar", systemImage: "gear") }
        }
        .task {
            model.refreshSMS()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(15)); if model.connection.connected { model.refreshSMS() } }
        }
    }
}

private struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""
    var body: some View {
        NavigationStack { Form {
            Section("Gateway üzerinden ara") {
                TextField("Telefon numarası", text: $number).keyboardType(.phonePad)
                Button("Ara") { model.dial(number) }.disabled(number.isEmpty || !model.connection.connected)
            }
            if let call = model.call { Section("Aktif çağrı") {
                LabeledContent(call.handle, value: call.state.rawValue)
                if call.state == .active {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                        ForEach(["1","2","3","4","5","6","7","8","9","*","0","#"], id: \.self) { digit in
                            Button(digit) { model.connection.send(type: "dtmf", payload: DTMFCommand(callId: call.id, digit: digit)) }.buttonStyle(.bordered)
                        }
                    }
                }
            } }
            Section("Bağlantı") { LabeledContent("Yerel gateway", value: model.connection.connected ? "Bağlı" : "Bağlı değil") }
        }.navigationTitle("K7Bridge") }
    }
}

private struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""; @State private var text = ""
    var body: some View {
        NavigationStack { List {
            Section("Yeni SMS") {
                TextField("Numara", text: $number).keyboardType(.phonePad)
                TextField("Mesaj", text: $text, axis: .vertical)
                Button("Gönder") { model.sendSMS(handle: number, text: text); text = "" }
            }
            Section("Mesajlar") { ForEach(model.messages) { message in
                VStack(alignment: .leading) { HStack { Text(message.handle).bold(); Spacer(); Text(message.state.rawValue).font(.caption) }; Text(message.text); Text(message.date, style: .relative).font(.caption).foregroundStyle(.secondary) }
            } }
        }.refreshable { model.refreshSMS() }.navigationTitle("SMS") }
    }
}

private struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack { Form {
            LabeledContent("Operatör", value: model.device.carrier)
            LabeledContent("Şebeke", value: model.device.radioTechnology)
            LabeledContent("Sinyal", value: "\(model.device.signalBars)/4")
            LabeledContent("SIM", value: model.device.simReady ? "Hazır" : "Hazır değil")
            LabeledContent("Pil", value: "\(Int(model.device.batteryLevel * 100))%")
            LabeledContent("Hotspot", value: model.device.hotspotEnabled ? "Açık" : "Kapalı")
            LabeledContent("Ses kapısı", value: model.device.audioGatePassed ? "Geçti" : "Doğrulanmadı")
        }.navigationTitle("Gateway durumu") }
    }
}

private struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var value = ""
    @State private var showingScanner = false
    var body: some View {
        NavigationStack { Form {
            Section("Eşleştirme") {
                TextField("k7bridge://pair?d=…", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Eşleştir") { if let url = URL(string: value) { model.pair(url: url) } }
                Button("QR kodunu tara") { showingScanner = true }
                if let id = model.pairing?.document.gatewayId { LabeledContent("Gateway", value: id) }
            }
            Section("Numara") { TextField("Ülke kodu", text: $model.countryCode).keyboardType(.phonePad) }
            Section { Text("TestFlight sürümü 90 günde bir yenilenmelidir. Hotspot otomatik açılamazsa eski iPhone'da elle açın.").font(.footnote) }
        }.navigationTitle("Ayarlar").sheet(isPresented: $showingScanner) {
            QRScannerView { url in value = url.absoluteString; showingScanner = false; model.pair(url: url) }
        } }
    }
}
