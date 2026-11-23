import Foundation

/// A private defaults domain for one test, kept in the temporary folder: a named domain would leave
/// an empty plist in ~/Library/Preferences after every run, even after `removePersistentDomain`.
struct TestDefaults {
    let name: String
    let defaults: UserDefaults

    init(prefix: String) {
        name = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: name)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
