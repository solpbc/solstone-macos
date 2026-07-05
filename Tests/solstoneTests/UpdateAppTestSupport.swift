import Foundation

struct IsolatedUserDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "solstone-update-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
