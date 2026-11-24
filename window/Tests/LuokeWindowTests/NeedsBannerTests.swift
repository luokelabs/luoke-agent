import XCTest
@testable import LuokeWindow

/// 应用页顶上的「待允许」：点了去的设置页，和读屏念的页名，是设置里真画出来的那一页。
final class NeedsBannerTests: XCTestCase {
    func testTheBannerNamesTheSettingsPageAsDrawn() {
        XCTAssertEqual(PrefsTab.permissions.shownTab, .privacy)
        XCTAssertTrue(PrefsTab.shown.contains(.privacy))
        XCTAssertEqual(AgentAppBody.needsLabel("照片图库"), "待允许：照片图库，前往设置 · 隐私与权限")
    }
}
