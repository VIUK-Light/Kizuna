/*
仕様:
- 役割: CharacterReport の保存。将来はサーバー送信に差し替えるが、まずローカル保管。
- 主な型: `ReportRepository` (protocol), `LocalJSONReportRepository`.
*/

import Foundation

protocol ReportRepository: AnyObject {
    func fetchReports() async throws -> [CharacterReport]
    func saveReport(_ report: CharacterReport) async throws
    func deleteReport(id: UUID) async throws
}

final class LocalJSONReportRepository: ReportRepository {
    private let store = LocalJSONStore<CharacterReport>(fileName: "reports.json")

    func fetchReports() async throws -> [CharacterReport] {
        try await store.load()
    }

    func saveReport(_ report: CharacterReport) async throws {
        try await store.appendOrReplace(report, idEquals: { $0.id == $1.id })
    }

    func deleteReport(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
}
