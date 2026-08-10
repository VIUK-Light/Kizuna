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
    @State private var submissionError: String?

    private let repo: ReportRepository = LocalJSONReportRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(KizunaCopy.text(japanese: "キャラクター: ", english: "Character: ") + character.visibleName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    sectionTitle(KizunaCopy.text(japanese: "通報理由", english: "Report reason"))
                    Picker(KizunaCopy.text(japanese: "理由", english: "Reason"), selection: $reason) {
                        ForEach(ReportReason.allCases) { r in
                            Text(r.localizedDisplayName).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    sectionTitle(KizunaCopy.text(japanese: "詳細 (任意)", english: "Details (optional)"))
                    TextField(
                        KizunaCopy.text(japanese: "具体的な内容を書いてください", english: "Describe what happened (optional)"),
                        text: $detail,
                        axis: .vertical
                    )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    if didSubmit {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(KizunaCopy.text(
                                japanese: "通報を受け付けました。ご協力ありがとうございます。",
                                english: "Your report was saved. Thank you for helping."
                            ))
                                .font(.system(size: 12))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.10)))
                    }

                    if let submissionError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                KizunaCopy.text(
                                    japanese: "通報を保存できませんでした",
                                    english: "The report could not be saved"
                                ),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            Text(submissionError)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await submit() }
                            } label: {
                                Label(
                                    KizunaCopy.text(japanese: "もう一度送信", english: "Try again"),
                                    systemImage: "arrow.clockwise"
                                )
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isSubmitting)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.10))
                        )
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button(KizunaCopy.text(japanese: "送信", english: "Submit")) {
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
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text(KizunaCopy.text(japanese: "キャラクターを通報", english: "Report character"))
                .font(.system(size: 14, weight: .semibold))
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
        submissionError = nil
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
            submissionError = nil
        } catch {
            // 入力内容はそのまま保持し、成功表示へ遷移させない。
            // 保存先の詳細はログに残し、利用者には再試行可能な状態だけを伝える。
            submissionError = KizunaCopy.text(
                japanese: "保存先に書き込めませんでした。空き容量や権限を確認して、もう一度お試しください。",
                english: "The report could not be written to local storage. Check available space or permissions, then try again."
            )
            NSLog("[ReportCharacterView] save failed: %@", String(describing: error))
        }
    }
}
