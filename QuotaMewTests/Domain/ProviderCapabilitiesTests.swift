import XCTest
@testable import QuotaMew

final class ProviderCapabilitiesTests: XCTestCase {
    func testCodexPreservesExistingProductCapabilitiesWithoutInventingAuthSemantics() {
        for capability in ProviderCapability.allCases {
            XCTAssertEqual(ProviderID.codex.capabilities.support(for: capability),
                           capability == .broadAuthDiagnostic ? .unverified : .supported)
        }
    }

    func testClaudeConditionalAndUnsupportedInventory() {
        for capability in ProviderCapability.allCases {
            let conditional: Set<ProviderCapability> = [.quota, .resetTimeDisplay, .broadAuthDiagnostic]
            XCTAssertEqual(ProviderID.claude.capabilities.support(for: capability),
                           conditional.contains(capability) ? .conditional : .unsupported)
        }
    }

    func testConsentSupportAndRuntimeAreIndependent() {
        let capabilities = ProviderID.claude.capabilities
        for providerEnabled in [false, true] {
            for featureEnabled in [false, true] {
                for runtime: ProviderRuntimeAvailability in [.available, .unknown, .unavailable(.awaitingSource)] {
                    let assessment = capabilities.assessment(for: .quota, runtime: runtime,
                        enablement: .init(providerEnabled: providerEnabled, featureEnabled: featureEnabled))
                    XCTAssertEqual(assessment.support, .conditional)
                    XCTAssertEqual(assessment.runtime, runtime)
                    XCTAssertEqual(assessment.isUsable, providerEnabled && featureEnabled && runtime == .available)
                }
            }
        }
        for capability in [ProviderCapability.resetNotifications, .accountActivity, .activityInsights, .reserveBucket] {
            XCTAssertFalse(capabilities.assessment(for: capability, runtime: .available,
                enablement: .init(providerEnabled: true, featureEnabled: true)).isUsable)
        }
    }
}
