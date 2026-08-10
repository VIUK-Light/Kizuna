/*
仕様:
- 役割: AI Studio の「絆」モード用のキャラ設定を行う専用 UI。
  プリセット選択、名前・年齢・性格・口調・関係性・自由記述を編集する。
- 主な型: `PersonaConfigView` (シート表示用フル画面 View), `PersonaModeEntryChip`.
- 編集ポイント: 設定項目の追加、プリセットギャラリーのデザインを変えるときに触る。
- 配置: AI Studio のモードピッカーで「絆」を選んだ時に「設定」チップから開く。
- 実装メモ: macOS の Form/Section は環境によって描画が崩れる (white-on-white) ことがあるので、
  ScrollView + VStack で明示的にレイアウトする。
*/

import SwiftUI

struct PersonaConfigView: View {
    @StateObject private var settings = PersonaSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: PersonaProfile = PersonaPreset.aoi.profile
    @State private var ageText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    presetSection
                    identitySection
                    personalitySection
                    relationshipSection
                    addendumSection
                    previewSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            Divider()
            footer
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .onAppear {
            draft = settings.active
            ageText = draft.age.map(String.init) ?? ""
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text(KizunaCopy.text(japanese: "絆を設定", english: "Kizuna settings"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            // ヘッダーは中央タイトル + 左キャンセル。保存はフッターに寄せる (mac の sheet 様式)。
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                commit()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    // MARK: - Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.06)
                      : Color.white.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(KizunaCopy.text(japanese: "クイック選択", english: "Quick select"))
                Spacer()
                HStack(spacing: 6) {
                    Text(KizunaCopy.text(
                        japanese: "\(PersonaPreset.allCases.count) 人",
                        english: "\(PersonaPreset.allCases.count) presets"
                    ))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(selectedPresetLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selectedPreset == nil ? .secondary : Color.accentColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(PersonaPreset.allCases) { preset in
                    presetCard(preset)
                }
            }
            Text(KizunaCopy.text(
                japanese: "プリセットを選ぶと下の項目が一括で書き換わります。後から自由に調整できます。",
                english: "Selecting a preset fills the fields below. You can adjust everything afterwards."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func presetCard(_ preset: PersonaPreset) -> some View {
        let selected = isPresetSelected(preset)
        return Button {
            draft = preset.profile
            ageText = draft.age.map(String.init) ?? ""
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: iconFor(preset))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(preset.profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(preset.localizedDisplayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// 現在の編集内容と完全一致するカードだけを選択状態にする。
    /// 名前だけが同じカスタムプロフィールをプリセットとして表示しない。
    private func isPresetSelected(_ preset: PersonaPreset) -> Bool {
        draft.matchesEditableContent(of: preset.profile)
    }

    private var selectedPreset: PersonaPreset? {
        PersonaPreset.allCases.first(where: isPresetSelected)
    }

    private var selectedPresetLabel: String {
        selectedPreset?.localizedDisplayName
            ?? KizunaCopy.text(japanese: "カスタム", english: "Custom")
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "基本情報", english: "Basic information"))
            card {
                labeledField(KizunaCopy.text(japanese: "名前", english: "Name")) {
                    TextField(KizunaCopy.text(japanese: "例: アオイ", english: "e.g. Aoi"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(KizunaCopy.text(japanese: "年齢 (任意)", english: "Age (optional)")) {
                    TextField(KizunaCopy.text(japanese: "例: 22", english: "e.g. 22"), text: $ageText)
                        .textFieldStyle(.roundedBorder)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .onChange(of: ageText) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue { ageText = digits }
                            draft.age = Int(digits)
                        }
                }
            }
        }
    }

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "性格", english: "Personality"))
            card {
                TextField(
                    KizunaCopy.text(
                        japanese: "例: 落ち着いていて聞き上手。少し天然。",
                        english: "e.g. Calm, a good listener, and a little absent-minded."
                    ),
                    text: $draft.personality,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            }
        }
    }

    private var relationshipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "関係性と口調", english: "Relationship and tone"))
            card {
                labeledField(KizunaCopy.text(japanese: "関係性", english: "Relationship")) {
                    Picker("", selection: $draft.relation) {
                        ForEach(PersonaRelation.allCases) { r in
                            Text(r.localizedDisplayName).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeledField(KizunaCopy.text(japanese: "口調", english: "Tone")) {
                    Picker("", selection: $draft.tone) {
                        ForEach(PersonaTone.allCases) { t in
                            Text(t.localizedDisplayName).tag(t)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var addendumSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "自由記述", english: "Additional notes"))
            card {
                TextField(
                    KizunaCopy.text(japanese: "例: 趣味は読書。寒がり。", english: "e.g. Enjoys reading and gets cold easily."),
                    text: $draft.freeFormAddendum,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                Text(KizunaCopy.text(
                    japanese: "プロンプトの末尾に追記されます。長くしすぎるとレスポンスが遅くなります。",
                    english: "This is appended to the prompt. Very long notes can slow down replies."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "プロンプトプレビュー", english: "Prompt preview"))
            card {
                Text(draft.promptText.isEmpty
                     ? KizunaCopy.text(japanese: "(プレビューなし)", english: "(No preview)")
                     : draft.promptText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(KizunaCopy.text(
                    japanese: "実際は会話モードの基本指示 (1〜2文・記号禁止・安全ルール) と合わせて送られます。",
                    english: "The conversation mode adds its own short, safe-response instructions."
                ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commit() {
        if ageText.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.age = nil
        }
        settings.active = draft
    }

    private func iconFor(_ preset: PersonaPreset) -> String {
        switch preset {
        case .aoi: return "moon.stars.fill"
        case .haru: return "sun.max.fill"
        case .yui: return "heart.fill"
        case .kai: return "snowflake"
        case .ren: return "graduationcap.fill"
        case .mentor: return "book.fill"
        case .bestie: return "person.2.fill"
        case .sena: return "checkmark.seal.fill"
        case .minato: return "flame.fill"
        case .mio: return "cup.and.saucer.fill"
        case .ray: return "magnifyingglass.circle.fill"
        case .lily: return "leaf.fill"
        case .emma: return "sparkles"
        case .noa: return "memorychip.fill"
        case .sakura: return "flag.checkered"
        case .toma: return "theatermasks.fill"
        case .akari: return "pencil.and.scribble"
        case .shion: return "building.columns.fill"
        case .nana: return "music.mic"
        }
    }
}

// MARK: - Compact entry chip

/// AI Studio コンポーザー周辺に置く「絆:〇〇」チップ。タップで PersonaConfigView を開く。
struct PersonaModeEntryChip: View {
    @StateObject private var settings = PersonaSettings.shared
    @State private var showConfig = false

    var body: some View {
        Button {
            showConfig = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(KizunaCopy.text(japanese: "絆: ", english: "Kizuna: ") + settings.active.name)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.14))
            )
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showConfig) {
            PersonaConfigView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
    }
}
