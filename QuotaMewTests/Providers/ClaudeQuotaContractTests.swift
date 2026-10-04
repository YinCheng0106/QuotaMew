import Foundation
import XCTest
@testable import QuotaMew

final class ClaudeQuotaContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func parse(_ json: String, version: String? = "2.1.246") throws -> ClaudeValidatedQuotaSample {
        try ClaudeStatusLineParser.parse(Data(json.utf8), observedAt: now, claudeCodeVersion: version, now: now)
    }

    func testIndependentAbsentNullAndPresentWindows() throws {
        for json in ["{}", #"{"rate_limits":null}"#, #"{"rate_limits":{}}"#,
                     #"{"rate_limits":{"five_hour":null,"seven_day":null}}"#] {
            let sample = try parse(json)
            XCTAssertNil(sample.fiveHour)
            XCTAssertNil(sample.sevenDay)
            XCTAssertEqual(sample.availability(for: .quota, at: now), .unavailable(.awaitingSource))
        }
        let window = #"{"used_percentage":23.5,"resets_at":2000003600}"#
        for five in ["null", window] {
            for seven in ["null", window] {
                let sample = try parse("{\"rate_limits\":{\"five_hour\":\(five),\"seven_day\":\(seven)}}")
                XCTAssertEqual(sample.fiveHour != nil, five != "null")
                XCTAssertEqual(sample.sevenDay != nil, seven != "null")
                let document = sample.snapshotDocument()
                XCTAssertEqual(document.rateLimits.fiveHour?.usedPercentage, sample.fiveHour?.usedPercentage)
                XCTAssertEqual(document.rateLimits.sevenDay?.resetsAt, sample.sevenDay?.reset.date?.timeIntervalSince1970)
                XCTAssertEqual(document.capturedAt, now)
            }
        }
    }

    func testStrictPercentageNumericMatrix() throws {
        for valid in [0.0, 0.125, 23.5, 100] {
            let sample = try parse("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(valid)}}}")
            XCTAssertEqual(sample.fiveHour?.usedPercentage, valid)
            XCTAssertEqual(sample.fiveHour?.resetAvailability, .unavailable(.awaitingSource))
            XCTAssertEqual(sample.availability(for: .quota, at: now), .available)
        }
        for value in ["-1", "140", "1e999", "NaN", "Infinity", #""NaN""#, #""10""#, "true", "[]", "{}"] {
            XCTAssertThrowsError(try parse("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(value)}}}"))
        }
        for value in [Double.nan, .infinity, -.infinity, -0.001, 100.001] {
            XCTAssertThrowsError(try ClaudeQuotaValidation.window(used: value, reset: nil, now: now)) {
                XCTAssertEqual($0 as? ClaudeContractError, .invalidPercentage)
            }
        }
    }

    func testResetSecondsBoundsAndIndependentAvailability() throws {
        let future = try ClaudeQuotaValidation.window(used: nil, reset: 2_000_003_600.5, now: now)
        XCTAssertEqual(future.reset, .reported(Date(timeIntervalSince1970: 2_000_003_600.5)))
        XCTAssertEqual(future.quotaAvailability, .unavailable(.awaitingSource))
        XCTAssertEqual(future.resetAvailability, .available)
        let expired = try ClaudeQuotaValidation.window(used: 73, reset: 1_999_999_999, now: now)
        XCTAssertEqual(expired.reset, .expired(Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertEqual(expired.usedPercentage, 73)
        XCTAssertEqual(expired.quotaAvailability, .unavailable(.stale))
        for value in [0.0, -1, 2_000_000_000_000, Double.greatestFiniteMagnitude, .nan, .infinity] {
            XCTAssertThrowsError(try ClaudeQuotaValidation.window(used: 10, reset: value, now: now)) {
                XCTAssertEqual($0 as? ClaudeContractError, .invalidReset)
            }
        }
        for reset in [#""2000003600""#, "true", "[]", "1e999"] {
            XCTAssertThrowsError(try parse("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":10,\"resets_at\":\(reset)}}}"))
        }
        let noReset = try parse(#"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":null}}}"#)
        XCTAssertEqual(noReset.availability(for: .resetTimeDisplay, at: now), .unavailable(.awaitingSource))
    }

    func testVersionPolicyAndGate() throws {
        let cases: [(String?, ClaudeVersionCompatibility)] = [
            (nil, .missing), ("secret-malformed", .malformed), ("1.0.43", .belowQuotaMinimum),
            ("2.1.79", .belowQuotaMinimum), ("2.1.80", .quotaFieldsOnly), ("2.1.242", .quotaFieldsOnly),
            ("2.1.243", .idleExpiryFix), ("2.1.246", .idleExpiryFix), ("3.0.0", .future)
        ]
        for (version, expected) in cases {
            XCTAssertEqual(ClaudeVersionCompatibility.evaluate(version), expected)
            if expected.permitsQuotaParsing {
                XCTAssertNoThrow(try parse("{}", version: version))
            } else {
                XCTAssertThrowsError(try parse("{}", version: version))
            }
        }
        for invalid in ["", "2.1", "2.1.246-secret", "2.-1.80", "2.1.9999999", String(repeating: "9", count: 40)] {
            XCTAssertNil(ClaudeCodeVersion(invalid))
        }
    }

    func testProvenanceAgeExpiryAndContinuityNeverRenew() throws {
        let sample = try parse(#"{"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":2000003600}}}"#)
        XCTAssertEqual(sample.provenance.observedAt, now)
        XCTAssertEqual(sample.provenance.accountContinuity, .unknown)
        XCTAssertFalse(sample.isStale(at: now))
        XCTAssertTrue(sample.isStale(at: now.addingTimeInterval(901)))
        XCTAssertEqual(sample.availability(for: .resetNotifications, at: now), .unavailable(.continuityUnknown))
        XCTAssertEqual(sample.snapshotDocument().rateLimits.fiveHour?.usedPercentage, 63)
        XCTAssertThrowsError(try ClaudeStatusLineParser.parse(Data("{}".utf8), observedAt: now.addingTimeInterval(301),
                                                              claudeCodeVersion: "2.1.246", now: now))
    }

    func testPrivacyBoundaryAndSchemaSeparation() throws {
        let secrets = ["synthetic-credential", "fake@example.invalid", "synthetic-prompt", "/synthetic/workspace", "/synthetic/transcript"]
        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":2000003600},"spend_limit":{"used_percentage":888}},"credential":"synthetic-credential","email":"fake@example.invalid","prompt":"synthetic-prompt","cwd":"/synthetic/workspace","transcript_path":"/synthetic/transcript","unknown":{"session_id":"synthetic-credential"}}"#
        let sample = try parse(payload)
        let output = String(reflecting: sample) + String(reflecting: sample.snapshotDocument())
        for secret in secrets { XCTAssertFalse(output.contains(secret)) }
        XCTAssertNil(sample.sevenDay)
        // A private value in a known field must also be sanitized on failure.
        for secret in secrets {
            let payload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\"\(secret)\"}}}"
            XCTAssertThrowsError(try parse(payload)) { error in
                XCTAssertFalse(String(reflecting: error).contains(secret))
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
        let ownJSON = #"{"schemaVersion":1,"capturedAt":"2033-05-18T03:33:20Z","rateLimits":{"fiveHour":{"usedPercentage":90}}}"#
        XCTAssertNil(try parse(ownJSON).fiveHour, "Official parser must never decode the owned schema")
        XCTAssertThrowsError(try ClaudeStatusLineParser.parse(Data(repeating: 32, count: 16_385),
            observedAt: now, claudeCodeVersion: "2.1.246", now: now))
    }
}
