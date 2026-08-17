/*
仕様:
- 役割: ペルソナチャットの入力欄（コンポーザー）。
- 主な型: `PersonaComposer`.
- 編集ポイント: 送信UI、キーボードツールバー、送信可否判定を変えるときに触る。
- 構成: PersonaChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Composer

struct PersonaComposer: View {
    let thread: PersonaThread
    @ObservedObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @Binding private var text: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(thread: PersonaThread, draft: Binding<String>) {
        self.thread = thread
        _text = draft
    }

    private var isGeneratingThisThread: Bool {
        service.activeGenerationThreadID == thread.id && service.phase == .thinking
    }

    private var isGeneratingAnotherThread: Bool {
        guard let activeThreadID = service.activeGenerationThreadID,
              service.phase == .thinking else { return false }
        return activeThreadID != thread.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isGeneratingAnotherThread {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(KizunaCopy.text(
                        japanese: "別のスレッドで生成中です。完了するまで送信できません。",
                        english: "Another thread is generating. You can send after it finishes."
                    ))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)
                .help(KizunaCopy.appName)

                TextField(KizunaCopy.text(japanese: "メッセージを送る…", english: "Message…"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(colorScheme == .dark
                                  ? Color(red: 0.20, green: 0.20, blue: 0.24)
                                  : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onSubmit(submit)

                Button {
                    if isGeneratingThisThread {
                        service.cancel()
                    } else {
                        submit()
                    }
                } label: {
                    Image(systemName: isGeneratingThisThread ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(isGeneratingThisThread || canSubmit ? Color.accentColor : Color.secondary.opacity(0.25))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!isGeneratingThisThread && !canSubmit)
                .help(isGeneratingAnotherThread
                      ? KizunaCopy.text(japanese: "別のスレッドで生成中です", english: "Another thread is generating")
                      : "")
                .accessibilityLabel(isGeneratingThisThread
                                    ? KizunaCopy.text(japanese: "生成を停止", english: "Stop generating")
                                    : KizunaCopy.text(japanese: "送信", english: "Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .personaKeyboardDismissToolbar($focused)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isPersistenceRecoveryRequired
            && !isGeneratingAnotherThread
    }

    private func submit() {
        guard canSubmit else { return }
        let toSend = text
        guard service.send(toSend, to: thread) else { return }
        text = ""
        focused = false
    }
}

private extension View {
    @ViewBuilder
    func personaKeyboardDismissToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(KizunaCopy.text(japanese: "閉じる", english: "Done")) { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}
