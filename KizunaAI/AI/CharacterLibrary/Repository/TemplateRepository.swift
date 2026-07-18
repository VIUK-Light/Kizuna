/*
仕様:
- 役割: CharacterTemplate の保存・取得。初回起動で seed する。
- 主な型: `TemplateRepository` (protocol), `LocalJSONTemplateRepository`.
*/

import Foundation

protocol TemplateRepository: AnyObject {
    func fetchTemplates() async throws -> [CharacterTemplate]
    func saveTemplate(_ template: CharacterTemplate) async throws
    func deleteTemplate(id: String) async throws
}

final class LocalJSONTemplateRepository: TemplateRepository {
    private let store = LocalJSONStore<CharacterTemplate>(fileName: "templates.json")

    func fetchTemplates() async throws -> [CharacterTemplate] {
        try await store.load()
    }

    func saveTemplate(_ template: CharacterTemplate) async throws {
        try await store.appendOrReplace(template, idEquals: { $0.id == $1.id })
    }

    func deleteTemplate(id: String) async throws {
        try await store.delete(matching: { $0.id == id })
    }
}
