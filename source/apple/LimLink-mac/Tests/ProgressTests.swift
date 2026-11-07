import XCTest

final class ProgressTests: XCTestCase {
    func testThemeTokensMatchSpec() {
        let theme = LimLinkTheme.limLink
        XCTAssertEqual(theme.controlHeight, 46)
        XCTAssertEqual(theme.cardRadius, 20)
        XCTAssertEqual(theme.spaceXS, 4)
        XCTAssertEqual(theme.spaceS, 6)
        XCTAssertEqual(theme.spaceM, 8)
        XCTAssertEqual(theme.spaceL, 12)
        XCTAssertEqual(theme.spaceXL, 16)
        XCTAssertEqual(theme.spaceXXL, 20)
        XCTAssertEqual(theme.dialDiameter, 240)
        XCTAssertEqual(theme.dialDiameterSmall, 44)
        XCTAssertEqual(theme.dialLineWidth, 14)
        XCTAssertEqual(theme.dialLineWidthSmall, 5)
        XCTAssertEqual(theme.dialIndeterminateArc, 0.25)
        XCTAssertEqual(theme.dialIndeterminatePeriod, 1)
        XCTAssertEqual(theme.dialProgressDuration, 0.3)
        XCTAssertEqual(theme.dialStartAngleDegrees, -90)
        XCTAssertTrue(theme.dialClockwise)
        XCTAssertEqual(theme.largeDial().centerTextWidth, 188)
        XCTAssertEqual(theme.smallDial().centerTextWidth, 10)
        XCTAssertEqual(theme.brandFont.design, "Resource Han Rounded CN")
        XCTAssertTrue(theme.brandFont.enabled)
        XCTAssertTrue(theme.brandFont.postScriptName.isEmpty)
    }

    func testBrandFontFallsBackUntilSubsetIsRegistered() {
        let bundled = BrandFontToken.resourceHanRoundedSubsetNotBundled
        XCTAssertEqual(BrandFontResolver.resolve(token: bundled, isRegistered: { _ in true }), .system)

        var token = bundled
        token.postScriptName = "LimLinkRounded"
        XCTAssertEqual(
            BrandFontResolver.resolve(token: token, isRegistered: { $0 == "LimLinkRounded" }),
            .custom(postScriptName: "LimLinkRounded")
        )
        token.enabled = false
        XCTAssertEqual(
            BrandFontResolver.resolve(token: token, isRegistered: { _ in true }),
            .system
        )
        token.enabled = true
        token.postScriptName = "Missing"
        XCTAssertEqual(
            BrandFontResolver.resolve(token: token, isRegistered: { _ in false }),
            .system
        )
    }

    func testPathSafetyStaysInLimLinkKit() {
        XCTAssertEqual(ReceivePathSafety.owner, "LimLinkKit")
    }

    func testAccessibilityCopy() {
        let active = BatchProgressSnapshot.make(
            direction: .sending,
            peerName: "周的 iPhone",
            bytesTransferred: 62,
            totalBytes: 100,
            secondsRemaining: 4,
            currentIndex: 5,
            totalCount: 8
        )
        XCTAssertEqual(DialAccessibility.label(for: active), "发给 周的 iPhone")
        XCTAssertEqual(DialAccessibility.value(for: active), "62%，第 5 个，共 8 个，剩余约 4 秒")
        XCTAssertFalse(DialAccessibility.value(for: active).contains("/s"))
        XCTAssertEqual(
            DialCaption.detail(active),
            "剩余约 4 秒 · 第 5 个 / 共 8 个"
        )
        XCTAssertEqual(DialCaption.percentage(active), "62%")

        let unknown = BatchProgressSnapshot.make(
            bytesTransferred: 1_200_000_000,
            totalBytes: nil,
            totalBytesKnown: false,
            currentIndex: 2,
            totalCount: 3,
            phase: .indeterminate
        )
        let unknownValue = DialAccessibility.value(for: unknown, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(unknownValue.hasPrefix("进度未知，已传 "), unknownValue)
        XCTAssertTrue(unknownValue.contains("GB"), unknownValue)
        XCTAssertFalse(unknownValue.contains("%"))
        XCTAssertEqual(DialCaption.detail(unknown), "第 2 个 / 共 3 个 · 大小未知")
        XCTAssertNil(DialCaption.percentage(unknown))

        let paused = BatchProgressSnapshot.make(
            bytesTransferred: 62,
            totalBytes: 100,
            phase: .paused(reason: "这台 Mac 刚才睡眠了，传输已暂停（系统限制）")
        )
        XCTAssertEqual(DialAccessibility.value(for: paused), "已暂停，62%")
        XCTAssertEqual(DialCaption.detail(paused), "这台 Mac 刚才睡眠了，传输已暂停（系统限制）")

        let done = BatchProgressSnapshot.make(totalCount: 8, phase: .completed(verified: true))
        XCTAssertEqual(DialAccessibility.value(for: done), "已完成")
        XCTAssertEqual(DialCaption.detail(done), "已完成 · 8 个文件 · 已校验")
        XCTAssertEqual(
            DialCaption.detail(BatchProgressSnapshot.make(totalCount: 8, phase: .completed(verified: false))),
            "已完成 · 8 个文件"
        )
        XCTAssertEqual(DialAccessibility.value(for: BatchProgressSnapshot.make(phase: .idle)), "还没有开始")
    }

    func testFileCountUsesDecimalUnits() {
        let text = ByteCountText.fileCount(1_500_000, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.contains("1.5"), text)
        XCTAssertTrue(text.contains("MB"), text)
        XCTAssertFalse(text.contains("MiB"), text)
        let speed = ByteCountText.speed(2_000_000, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(speed.hasSuffix("/s"), speed)
        XCTAssertTrue(speed.contains("MB"), speed)
    }

    func testRemainingTimePhrases() {
        XCTAssertEqual(RemainingTimeText.phrase(nil), "正在估算…")
        XCTAssertEqual(RemainingTimeText.phrase(4), "剩余约 4 秒")
        XCTAssertEqual(RemainingTimeText.phrase(59), "剩余约 59 秒")
        XCTAssertEqual(RemainingTimeText.phrase(90), "剩余约 2 分钟")
        XCTAssertEqual(RemainingTimeText.phrase(3600), "剩余约 1 小时")
    }

    func testRingStartsAtNoonAndGoesClockwise() {
        let quarter = RingGeometry.arc(fraction: 0.25)
        XCTAssertEqual(quarter.startAngle, 90)
        XCTAssertEqual(quarter.endAngle, 0)
        XCTAssertTrue(quarter.clockwise)
        XCTAssertEqual(RingGeometry.arc(fraction: 0).endAngle, 90)
        XCTAssertEqual(RingGeometry.arc(fraction: 1).endAngle, -270)
    }

    func testCenterDropsNameAtAccessibilitySizes() {
        XCTAssertEqual(DialCenterLayout.density(isAccessibilitySize: false), .regular)
        XCTAssertEqual(DialCenterLayout.density(isAccessibilitySize: true), .speedOnly)
    }

    func testEngineComputesSpeedIndexAndCompletion() {
        var engine = FakeTransferEngine(totalBytes: 80_000_000, totalCount: 8)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(engine.snapshot(now: start).phase, .idle)

        engine.start(now: start)
        engine.advance(bytes: 2_000_000, at: start.addingTimeInterval(1))
        let early = engine.snapshot(now: start.addingTimeInterval(1))
        XCTAssertEqual(early.phase, .active)
        XCTAssertEqual(early.speedBytesPerSecond ?? 0, 2_000_000, accuracy: 0.1)
        XCTAssertEqual(early.secondsRemaining ?? 0, 39, accuracy: 0.1)
        XCTAssertEqual(early.currentIndex, 1)
        XCTAssertEqual(early.fraction ?? 0, 0.025, accuracy: 0.0001)

        engine.advance(bytes: 38_000_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(engine.snapshot(now: start.addingTimeInterval(2)).currentIndex, 5)

        engine.advance(bytes: 80_000_000, at: start.addingTimeInterval(3))
        let done = engine.snapshot(now: start.addingTimeInterval(3))
        XCTAssertEqual(done.phase, .completed(verified: true))
        XCTAssertEqual(done.fraction, 1)
        XCTAssertEqual(done.currentIndex, 8)
    }

    func testEnginePauseAndUnknownSize() {
        var engine = FakeTransferEngine()
        let now = Date(timeIntervalSince1970: 20)
        engine.start(now: now)
        engine.pause(reason: "已暂停")
        engine.advance(bytes: 5_000_000, at: now.addingTimeInterval(1))
        let paused = engine.snapshot(now: now.addingTimeInterval(1))
        XCTAssertEqual(paused.phase, .paused(reason: "已暂停"))
        XCTAssertEqual(paused.bytesTransferred, 0)
        XCTAssertNil(paused.secondsRemaining)

        engine.resume()
        engine.markIndeterminate()
        engine.advance(bytes: 5_000_000, at: now.addingTimeInterval(2))
        let unknown = engine.snapshot(now: now.addingTimeInterval(2))
        XCTAssertEqual(unknown.phase, .indeterminate)
        XCTAssertFalse(unknown.totalBytesKnown)
        XCTAssertNil(unknown.fraction)
        XCTAssertEqual(unknown.bytesTransferred, 5_000_000)
        XCTAssertNil(unknown.secondsRemaining)
    }
}

extension BatchProgressSnapshot {
    static func make(
        direction: TransferDirection = .receiving,
        peerName: String = "示例设备",
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = 100,
        totalBytesKnown: Bool = true,
        speedBytesPerSecond: Double? = nil,
        secondsRemaining: TimeInterval? = nil,
        currentIndex: Int = 1,
        totalCount: Int = 8,
        phase: BatchProgressPhase = .active
    ) -> BatchProgressSnapshot {
        BatchProgressSnapshot(
            direction: direction,
            peerName: peerName,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            totalBytesKnown: totalBytesKnown,
            speedBytesPerSecond: speedBytesPerSecond,
            secondsRemaining: secondsRemaining,
            currentIndex: currentIndex,
            totalCount: totalCount,
            phase: phase
        )
    }
}
