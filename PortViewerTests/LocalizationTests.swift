import XCTest
@testable import PortViewer

final class LocalizationTests: XCTestCase {
    func testLanguageSelectionPersistsAnApplicationOverrideAndRestoresSystem() throws {
        let suiteName = "PortViewer.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: AppLanguage.preferenceKey))
        for language in [AppLanguage.english, .simplifiedChinese] {
            language.save(to: defaults)
            let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertEqual(restoredDefaults.string(forKey: AppLanguage.preferenceKey), language.rawValue)
            XCTAssertEqual(restoredDefaults.stringArray(forKey: "AppleLanguages"), [language.rawValue])
        }

        AppLanguage.system.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "system")
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }

    func testLanguageSettingsHaveTranslations() {
        let bundle = Bundle(for: PortViewModel.self)
        for key in ["语言", "应用语言", "跟随系统", "更改语言后，退出并重新打开 Port Viewer 即可生效。"] {
            XCTAssertNotEqual(localizedString(key, language: "en", bundle: bundle), key)
            XCTAssertEqual(localizedString(key, language: "zh-Hans", bundle: bundle), key)
        }
    }

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
                    "检测本机 Cloudflare Tunnel", "连接器地址", "端点可读，进程归属未确认"] {
            XCTAssertNotEqual(localizedString(key, language: "en", bundle: bundle), key)
            XCTAssertEqual(localizedString(key, language: "zh-Hans", bundle: bundle), key)
        }
    }

    func testSearchAndRelationshipDescriptionsHaveEnglishTranslations() {
        let bundle = Bundle(for: PortViewModel.self)
        let keys = [
            "搜索应用名称或端口，例如 3000", "菜单栏端口搜索", "发送或接收", "这台 Mac 的端口",
            "无固定对象", "端口未知", "访问来源", "同一网络设备", "来源暂不确定",
            "共同使用其中端口", "连接目标", "可以尝试连接", "通信对象", "存在连接",
            "系统没有提供固定的连接对象。", "这是该应用当前在本机使用的端口。",
            "其他设备可能可访问", "显示这个节点的解释", "未知格式", "正在积累样本",
            "全部", "已建立", "等待首次采样", "归属", "连接状态", "全部状态", "重试", "已暂停"
        ]
        for key in keys {
            let english = localizedString(key, language: "en", bundle: bundle)
            XCTAssertNotEqual(english, key, key)
            XCTAssertNil(english.range(of: "\\p{Han}", options: .regularExpression), key)
            XCTAssertEqual(localizedString(key, language: "zh-Hans", bundle: bundle), key)
        }
    }

    func testRelationshipCountsUseLocalizedFormats() {
        let bundle = Bundle(for: PortViewModel.self)
        for (key, expected) in [
            ("%lld 个进程", "3 processes"),
            ("%lld 个服务端口", "3 service ports"),
            ("%lld 个连接目标", "3 connection targets"),
            ("共 %lld 条连接", "3 connections in total"),
            ("%lld 个进程使用", "Used by 3 processes"),
            ("%lld 个采样点", "3 samples"),
            ("另有 %lld 项", "3 more items")
        ] {
            let template = localizedString(key, language: "en", bundle: bundle)
            XCTAssertEqual(String(format: template, 3), expected)
        }
        let template = localizedString("%lld 个 · %lld 条连接", language: "en", bundle: bundle)
        XCTAssertEqual(String(format: template, 2, 3), "2 peers · 3 connections")
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
