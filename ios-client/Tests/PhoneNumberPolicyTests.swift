import XCTest
@testable import K7Bridge

final class PhoneNumberPolicyTests: XCTestCase {
    func testTurkishNormalization() {
        XCTAssertEqual(PhoneNumberPolicy.normalize("0555 111 22 33"), "+905551112233")
        XCTAssertEqual(PhoneNumberPolicy.normalize("+49 30 123456"), "+4930123456")
    }
    func testEmergencyAndInvalidNumbersAreRejected() {
        XCTAssertNil(PhoneNumberPolicy.normalize("112"))
        XCTAssertNil(PhoneNumberPolicy.normalize("123"))
        XCTAssertNil(PhoneNumberPolicy.normalize("+"))
        XCTAssertNil(PhoneNumberPolicy.normalize("0555"))
    }

    func testFractionalGatewayDatesDecode() throws {
        let json = #"{"id":"sms-1","handle":"+905551112233","text":"Merhaba","date":"2026-07-14T00:03:04.123Z","isFromMe":false,"state":"sent"}"#
        let message = try JSONDecoder.k7.decode(SMSMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.id, "sms-1")
        XCTAssertEqual(message.handle, "+905551112233")
    }

    func testUnknownDeviceValuesDecodeAsNil() throws {
        let json = #"{"carrier":null,"radioTechnology":null,"signalBars":null,"simReady":null,"batteryLevel":null,"charging":null,"thermalState":"nominal","hotspotEnabled":null,"clientConnected":true,"audioGatePassed":false}"#
        let status = try JSONDecoder.k7.decode(DeviceStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.carrier)
        XCTAssertNil(status.signalBars)
        XCTAssertNil(status.batteryLevel)
        XCTAssertEqual(status.clientConnected, true)
    }

    func testConnectionPhaseLabelsAreStable() {
        XCTAssertTrue(ConnectionPhase.online.isOnline)
        XCTAssertEqual(ConnectionPhase.authenticating.title, "Güvenli bağlantı kuruluyor")
    }

    func testContactNumbersMatchAcrossTurkishFormats() {
        let local = Set(ContactNumberMatcher.keys(for: "0555 111 22 33"))
        let international = Set(ContactNumberMatcher.keys(for: "+90 555 111 22 33"))
        XCTAssertFalse(local.intersection(international).isEmpty)
        XCTAssertTrue(local.contains("5551112233"))
    }

    func testGatewayDiagnosticEntryDecodes() throws {
        let json = #"{"timestamp":"2026-07-14T12:34:56.123Z","sequence":7,"source":"gateway","level":"info","component":"telephony","event":"health_changed","fields":{"callObservationReady":"1"}}"#
        let entry = try JSONDecoder.k7.decode(DiagnosticEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.component, "telephony")
        XCTAssertEqual(entry.fields["callObservationReady"], "1")
    }
}
