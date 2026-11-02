import Foundation
// A suite must not be the running application's own domain. Use standard in
// the bundle; CLI harnesses join that domain through a suite when permitted.
enum ProducerDefaults {
    static let shared: UserDefaults = {
        let domain = "org.interviewproducer.mac"
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName:domain) ?? .standard
    }()
}
