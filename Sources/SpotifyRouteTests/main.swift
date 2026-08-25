import Foundation

var failures = 0
failures += runVolumeFloorRuleTests()
failures += runProtocolTests()
failures += runSettingsTests()
failures += runDestinationAudibilityTests()
failures += runRouteControllerTests()
failures += runCommandServerTests()
failures += runRouteDisplayTests()

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
