import Foundation

/// Internal canary switches for the natural Story initiative experiment.
///
/// These keys are intentionally not exposed in the UI. A new build starts
/// with both model paths disabled, while a development/canary build can turn
/// either path on without changing the persisted Story schema or shipping a
/// second navigation surface. Keeping the keys separate lets NAGI and iori be
/// evaluated and rolled back independently.
enum StoryInitiativeFlags {
    static let nagiUserDefaultsKey = "kizuna.storyInitiative.nagi"
    static let ioriUserDefaultsKey = "kizuna.storyInitiative.iori"

    static func isEnabled(
        for model: StoryGenerationModel,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(for: model))
    }

    static func setEnabled(
        _ enabled: Bool,
        for model: StoryGenerationModel,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: key(for: model))
    }

    private static func key(for model: StoryGenerationModel) -> String {
        switch model {
        case .b31:
            return nagiUserDefaultsKey
        case .e4b:
            return ioriUserDefaultsKey
        }
    }
}
