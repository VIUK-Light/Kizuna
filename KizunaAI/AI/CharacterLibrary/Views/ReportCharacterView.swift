/*
仕様:
- 役割: キャラクター通報シート。理由と詳細をローカル JSON に保存。
  将来は API 送信に差し替え可能。
- 主な型: `ReportCharacterView`.
*/

import SwiftUI

struct ReportCharacterView: View {
    let character: CharacterProfile
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .inappropriate
    @State private var detail: String = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false

    private let repo: ReportRepository = LocalJSONReportRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("キャラクター: \(character.displayName.isEmpty ? character.name : character.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    sectionTitle("通報理由")
                    Picker("理由", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    sectionTitle("詳細 (任意)")
                    TextField("具体的な内容を書いてください", text: $detail, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    if didSubmit {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("通報を受け付けました。ご協力ありがとうございます。")
                                .font(.system(size: 12))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.10)))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("送信") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || didSubmit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button("閉じる") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text("キャラクターを通報").font(.system(size: 14, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 48, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let report = CharacterReport(
            characterId: character.id,
            reason: reason,
            detail: detail
        )
        do {
            try await repo.saveReport(report)
            didSubmit = true
        } catch {
            NSLog("[ReportCharacterView] save failed: %@", String(describing: error))
        }
    }
}
