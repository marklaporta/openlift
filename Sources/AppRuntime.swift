import Foundation

enum AppRuntime {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("OPENLIFT_UI_TESTING")
    static let isAdaptiveWorkflowUITesting = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"
    )

    static func prepareForUITesting() {
        guard isUITesting else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "openlift.lastActivatedTemplateId")
        defaults.removeObject(forKey: "openlift.lastActivatedTemplateName")
    }
}
