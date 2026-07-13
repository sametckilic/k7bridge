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
    }
}

