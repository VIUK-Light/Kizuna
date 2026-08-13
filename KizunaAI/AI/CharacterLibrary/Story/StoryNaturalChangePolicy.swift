import Foundation

/// Keeps an ordinary story turn to one small, observable change at most. The
/// model still decides whether a change is warranted; this policy prevents one
/// response from changing several independent parts of the world at once.
enum StoryNaturalChangePolicy {
    private enum ChangeGroup {
        case environment
        case relationship
        case character
        case inventory
        case objective
    }

    static func acceptedPatch(
        from patch: StoryStatePatch,
        currentState: StoryState? = nil
    ) -> StoryStatePatch? {
        // A scene transition can coherently update several environmental
        // fields (for example, moving location also changing the weather).
        // It still counts as one change group. Unrelated groups are rejected
        // instead of partially applying a response that the narrative did not
        // establish.
        let environment = (
            location: changedText(patch.location, from: currentState?.location),
            timeOfDay: changedText(patch.timeOfDay, from: currentState?.timeOfDay),
            mood: changedText(patch.mood, from: currentState?.mood),
            weather: changedText(patch.weather, from: currentState?.weather)
        )
        let relationship = changedText(
            patch.relationshipStage,
            from: currentState?.relationshipStage
        )
        let characterChanges = (patch.characterUpdates ?? []).compactMap {
            normalizedCharacterChange($0, currentState: currentState)
        }
        let inventoryChanges = (patch.inventoryChanges ?? []).compactMap {
            normalizedInventoryChange($0, currentState: currentState)
        }

        // Silently selecting the first character/item would make the stored
        // state disagree with the generated prose. Fail closed when a single
        // response attempts to change multiple members of either collection.
        guard characterChanges.count <= 1, inventoryChanges.count <= 1 else {
            return nil
        }

        // An explicit empty array can resolve the last active objective. A
        // missing key means that objectives were not part of this change.
        let normalizedGoals: [String]?
        if let goals = patch.activeGoals {
            if goals.isEmpty {
                normalizedGoals = []
            } else {
                let values = goals.compactMap(normalizedText)
                guard !values.isEmpty else { return nil }
                normalizedGoals = Array(values.prefix(6))
            }
        } else {
            normalizedGoals = nil
        }
        let objectiveChanged: Bool
        if let normalizedGoals, let currentState {
            objectiveChanged = normalizedGoals
                != Array(currentState.activeGoals.compactMap(normalizedText).prefix(6))
        } else {
            objectiveChanged = normalizedGoals != nil
        }

        var groups: [ChangeGroup] = []
        if [environment.location, environment.timeOfDay, environment.mood, environment.weather]
            .contains(where: { $0 != nil }) { groups.append(.environment) }
        if relationship != nil { groups.append(.relationship) }
        if !characterChanges.isEmpty { groups.append(.character) }
        if !inventoryChanges.isEmpty { groups.append(.inventory) }
        if objectiveChanged { groups.append(.objective) }
        guard groups.count == 1, let group = groups.first else { return nil }

        var accepted = patch
        switch group {
        case .environment:
            accepted.location = environment.location
            accepted.timeOfDay = environment.timeOfDay
            accepted.mood = environment.mood
            accepted.weather = environment.weather
            accepted.relationshipStage = nil
            accepted.characterUpdates = nil
            accepted.inventoryChanges = nil
            accepted.activeGoals = nil
        case .relationship:
            accepted.location = nil
            accepted.timeOfDay = nil
            accepted.mood = nil
            accepted.weather = nil
            accepted.relationshipStage = relationship
            accepted.characterUpdates = nil
            accepted.inventoryChanges = nil
            accepted.activeGoals = nil
        case .character:
            accepted.location = nil
            accepted.timeOfDay = nil
            accepted.mood = nil
            accepted.weather = nil
            accepted.relationshipStage = nil
            accepted.characterUpdates = characterChanges
            accepted.inventoryChanges = nil
            accepted.activeGoals = nil
        case .inventory:
            accepted.location = nil
            accepted.timeOfDay = nil
            accepted.mood = nil
            accepted.weather = nil
            accepted.relationshipStage = nil
            accepted.characterUpdates = nil
            accepted.inventoryChanges = inventoryChanges
            accepted.activeGoals = nil
        case .objective:
            accepted.location = nil
            accepted.timeOfDay = nil
            accepted.mood = nil
            accepted.weather = nil
            accepted.relationshipStage = nil
            accepted.characterUpdates = nil
            accepted.inventoryChanges = nil
            accepted.activeGoals = normalizedGoals
        }
        return accepted
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func changedText(_ value: String?, from current: String?) -> String? {
        guard let value = normalizedText(value) else { return nil }
        return value == normalizedText(current) ? nil : value
    }

    private static func normalizedCharacterChange(
        _ update: StoryCharacterStatePatch,
        currentState: StoryState?
    ) -> StoryCharacterStatePatch? {
        let name = normalizedText(update.characterName) ?? ""
        guard update.characterId != nil || !name.isEmpty else { return nil }

        let current = currentState?.characterStates.first { state in
            if let characterId = update.characterId {
                return state.characterId == characterId
            }
            return normalizedText(state.characterName) == name
        }
        let change = StoryCharacterStatePatch(
            characterId: update.characterId,
            characterName: name,
            mood: changedText(update.mood, from: current?.mood),
            goal: changedText(update.goal, from: current?.goal),
            relationship: changedText(update.relationship, from: current?.relationship),
            innerThought: changedText(update.innerThought, from: current?.innerThought)
        )
        let hasFieldChange = [change.mood, change.goal, change.relationship, change.innerThought]
            .contains(where: { $0 != nil })
        return hasFieldChange ? change : nil
    }

    private static func normalizedInventoryChange(
        _ change: StoryInventoryChange,
        currentState: StoryState?
    ) -> StoryInventoryChange? {
        guard let name = normalizedText(change.name) else { return nil }
        let current = currentState?.inventory.first {
            normalizedText($0.name) == name
        }
        switch change.action {
        case .remove:
            guard current != nil else { return nil }
            return StoryInventoryChange(action: .remove, name: name, detail: nil, owner: nil)
        case .add, .update:
            let detail = normalizedText(change.detail)
            let owner = normalizedText(change.owner)
            let isSame = normalizedText(current?.detail) == detail
                && normalizedText(current?.owner) == owner
            guard current == nil || !isSame else { return nil }
            return StoryInventoryChange(
                action: change.action,
                name: name,
                detail: detail,
                owner: owner
            )
        }
    }
}
