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
    static let nagiLaunchArgument = "--kizuna-story-initiative-nagi"
    static let ioriLaunchArgument = "--kizuna-story-initiative-iori"

    static func isEnabled(
        for model: StoryGenerationModel,
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG || KIZUNA_INTERNAL_CANARY
        return defaults.bool(forKey: key(for: model))
            || arguments.contains(launchArgument(for: model))
        #else
        // Release builds have no public or persisted activation path. This
        // prevents a stale developer default from silently enabling the
        // experiment in a shipped build.
        return false
        #endif
    }

    static func setEnabled(
        _ enabled: Bool,
        for model: StoryGenerationModel,
        defaults: UserDefaults = .standard
    ) {
        #if DEBUG || KIZUNA_INTERNAL_CANARY
        defaults.set(enabled, forKey: key(for: model))
        #endif
    }

    static func launchArgument(for model: StoryGenerationModel) -> String {
        switch model {
        case .b31:
            return nagiLaunchArgument
        case .e4b:
            return ioriLaunchArgument
        }
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
