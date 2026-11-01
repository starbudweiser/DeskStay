import XCTest
@testable import DeskStayCore

final class BrandTests: XCTestCase {
    func testNameFollowsSocleRule() {
        // tout en majuscules sauf une seule lettre minuscule : le « e »
        XCTAssertEqual(Brand.name, "DeSKSTAY")
        XCTAssertEqual(Brand.name.filter(\.isLowercase), "e")
    }

    func testColoursTheLowercaseLetterOfEveryOccurrence() {
        let text = "Quitter DeSKSTAY — à l'ouverture de DeSKSTAY"
        let ranges = Brand.lowercaseRanges(in: text)
        XCTAssertEqual(ranges.count, 2)
        for range in ranges { XCTAssertEqual((text as NSString).substring(with: range), "e") }
    }

    func testIgnoresNameInsideWordPathOrIdentifier() {
        XCTAssertTrue(Brand.lowercaseRanges(in: "/Applications/DeSKSTAY.app").isEmpty)
        XCTAssertTrue(Brand.lowercaseRanges(in: "DeSKSTAYCore").isEmpty)
        XCTAssertTrue(Brand.lowercaseRanges(in: "com.DeSKSTAY").isEmpty)
        XCTAssertTrue(Brand.lowercaseRanges(in: "Desk Stay, DESKSTAY, DeskStay").isEmpty)
        XCTAssertEqual(Brand.lowercaseRanges(in: "(DeSKSTAY)").count, 1)
    }
}
