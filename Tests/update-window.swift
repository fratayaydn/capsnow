import Foundation

@main
struct UpdateTests {
    static func main() {
        assert(availableUpdate(stored: "v1.10.0", running: "1.9.9") == "1.10.0")
        assert(availableUpdate(stored: "1.2.3", running: "1.2.3") == nil)
        assert(availableUpdate(stored: "1.2", running: "1.2.0") == nil)
        assert(availableUpdate(stored: "1.2.2", running: "1.2.3") == nil)
        assert(availableUpdate(stored: nil, running: "1.2.3") == nil)
        for invalid: Any in [123, "", "v", "1..2", "1.2.3.4", "1.2-beta", "1/2", "-1.0", "1. 2", "١.٢"] {
            assert(availableUpdate(stored: invalid, running: "1.0.0") == nil)
        }
        assert(availableUpdate(stored: "1.999999999999999999999999.0", running: "1.10.0") != nil)
        print("Passed update window checks: stored newer, equal, older, missing and invalid versions.")
    }
}
