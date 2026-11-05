import XCTest
@testable import PortViewer

final class LocalizationTests: XCTestCase {
    func testSupportedLanguagesHaveExpectedResources() {
        let resourceBundle = Bundle(for: PortViewModel.self)
        XCTAssertTrue(resourceBundle.localizations.contains("zh-Hans"))
        XCTAssertTrue(resourceBundle.localizations.contains("en"))
        XCTAssertEqual(localizedString("设置", language: "zh-Hans", bundle: resourceBundle), "设置")
        XCTAssertEqual(localizedString("设置", language: "en", bundle: resourceBundle), "Settings")
        XCTAssertEqual(localizedString("网络扫描", language: "en", bundle: resourceBundle), "Network Scan")
    }

    func testEnglishFormatCanReorderTypedArguments() {
        let resourceBundle = Bundle(for: PortViewModel.self)
        let template = localizedString(
            "在 %lld 台主机上发现 %lld 个开放端口，用时 %.1f 秒。",
            language: "en",
            bundle: resourceBundle
        )
        XCTAssertEqual(
            String(format: template, 2, 3, 1.5),
            "Found 3 open ports on 2 hosts in 1.5 seconds."
        )
    }

    func testCloudflareStatusAndSettingsAreLocalized() {
        let bundle = Bundle(for: PortViewModel.self)
        for key in ["隧道已连接", "隧道未连接", "连接状态未知", "数据已过期", "有 Cloudflare 映射",
                    "检测本机 Cloudflare Tunnel", "手动诊断端点（可选）", "端点可读，进程归属未确认"] {
            XCTAssertNotEqual(localizedString(key, language: "en", bundle: bundle), key)
            XCTAssertEqual(localizedString(key, language: "zh-Hans", bundle: bundle), key)
        }
    }

    private func localizedString(_ key: String, language: String, bundle: Bundle) -> String {
        guard
            let path = bundle.path(forResource: language, ofType: "lproj"),
            let localizedBundle = Bundle(path: path)
        else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }
}
