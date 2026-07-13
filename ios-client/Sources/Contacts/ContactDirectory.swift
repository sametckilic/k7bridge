import Combine
@preconcurrency import Contacts
import Foundation

enum ContactAccessState: Equatable, Sendable {
    case notDetermined
    case requesting
    case loading
    case ready(Int)
    case limited(Int)
    case denied
    case failed(String)

    var title: String {
        switch self {
        case .notDetermined: return "Rehber erişimini aç"
        case .requesting: return "İzin bekleniyor"
        case .loading: return "Rehber yükleniyor"
        case .ready(let count): return "\(count) kişi hazır"
        case .limited(let count): return "\(count) paylaşılan kişi"
        case .denied: return "Rehber erişimi kapalı"
        case .failed: return "Rehber okunamadı"
        }
    }

    var canResolveNames: Bool {
        switch self {
        case .ready, .limited: return true
        default: return false
        }
    }
}

@MainActor
final class ContactDirectory: ObservableObject {
    @Published private(set) var state: ContactAccessState = .notDetermined

    private let store = CNContactStore()
    private var namesByNumber: [String: String] = [:]
    private var changeObserver: NSObjectProtocol?
    private var countryCode: String

    init(countryCode: String) {
        self.countryCode = countryCode
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadIfAuthorized() }
        }
        refreshAuthorizationStatus()
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func updateCountryCode(_ value: String) {
        guard countryCode != value else { return }
        countryCode = value
        reloadIfAuthorized()
    }

    func requestAccess() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            state = .requesting
            store.requestAccess(for: .contacts) { [weak self] _, error in
                Task { @MainActor in
                    if let error { self?.state = .failed(error.localizedDescription) }
                    else { self?.refreshAuthorizationStatus() }
                }
            }
        case .authorized, .limited:
            reloadIfAuthorized()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    func reloadIfAuthorized() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            reload(limited: false)
        case .limited:
            reload(limited: true)
        case .notDetermined:
            state = .notDetermined
        case .denied, .restricted:
            namesByNumber = [:]
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    func name(for number: String) -> String? {
        for key in ContactNumberMatcher.keys(for: number, countryCode: countryCode) {
            if let name = namesByNumber[key] { return name }
        }
        return nil
    }

    func remember(name: String, number: String) {
        guard !name.isEmpty else { return }
        for key in ContactNumberMatcher.keys(for: number, countryCode: countryCode) {
            namesByNumber[key] = name
        }
        objectWillChange.send()
    }

    private func refreshAuthorizationStatus() {
        reloadIfAuthorized()
    }

    private func reload(limited: Bool) {
        state = .loading
        let store = store
        let countryCode = countryCode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var index: [String: String] = [:]
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactMiddleNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var contactCount = 0
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let personal = [contact.givenName, contact.middleName, contact.familyName]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    let name = personal.isEmpty ? contact.organizationName : personal
                    guard !name.isEmpty else { return }
                    contactCount += 1
                    for phone in contact.phoneNumbers {
                        for key in ContactNumberMatcher.keys(for: phone.value.stringValue, countryCode: countryCode) {
                            if index[key] == nil { index[key] = name }
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.namesByNumber = index
                    self.state = limited ? .limited(contactCount) : .ready(contactCount)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.state = .failed(error.localizedDescription) }
            }
        }
    }
}

enum ContactNumberMatcher {
    static func keys(for raw: String, countryCode: String = "+90") -> [String] {
        let digits = String(raw.filter(\.isNumber))
        var values: [String] = []
        if let normalized = PhoneNumberPolicy.normalize(raw, countryCode: countryCode) {
            values.append(normalized)
            values.append(String(normalized.filter(\.isNumber)))
        }
        if !digits.isEmpty { values.append(digits) }
        if digits.count >= 10 { values.append(String(digits.suffix(10))) }
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
