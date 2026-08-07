[English](README.en.md)

# Kizuna

**ユーザーの意思と現実の生活を尊重しながら、AIキャラクターとの関係や物語を育てるSwiftUIアプリ。**

Kizunaは、キャラクターとの継続的な会話・関係・物語を楽しめる、iOS / macOS向けのオープンソースAIアプリです。
安全性を理由に体験を壊しすぎず、同時に依存や現実の人間関係からの孤立を促さない設計を目指しています。
<img width="780" height="1780" alt="Simulator Screenshot - iPhone 17 Pro Max - 2026-08-07 at 08 07 07" src="https://github.com/user-attachments/assets/ad662dd4-9b05-46ea-bb28-abaca04a2a94" />


> Kizunaは、利用者を支配するAIでも、利用者を突き放すAIでもありません。

## 特徴

- **関係と物語が続くキャラクターAI** — 単発のチャットではなく、世界観・記憶・関係性を扱います。
- **キャラクター性を維持する安全設計** — 必要な場面でも、会話を一律の拒否文へ置き換えません。
- **依存を目的にしない** — 利用時間や継続率の最大化、独占的な誘導を設計目標にしません。
- **利用者が管理できる** — 会話、記憶、モデル、接続先、秘密情報を利用者側で管理できる構成です。
- **ローカル / リモートモデル対応** — UIと推論ランタイムを分離し、モデル提供元へ直接依存しない設計です。
- **SwiftUIネイティブ** — iOSとmacOSで共通のプロダクト体験を提供します。

## Kizunaが目指す安全性

一般的な安全対策では、危険な単語を検出するとキャラクター性や物語の文脈まで失われることがあります。Kizunaは、創作・ロールプレイ・現実の相談を区別しながら、危険度に応じて対応することを目指します。

- 通常の創作や親密な会話を不必要に中断しない
- 現実の危険がある場合は、キャラクターとして対話を続けながら支援先への導線を追加する
- 「私だけを見て」「他の人と話さないで」など、孤立や依存を促す継続的な誘導を避ける
- AIであること、回答に誤りがあり得ることを隠さない
- 個人的な会話や秘密情報を、体験の代償として必要以上に収集しない

## 開発状況

Kizunaは現在開発中です。機能提案、バグ報告、ドキュメント改善、Pull Requestを歓迎します。

| 項目 | 内容 |
| --- | --- |
| 開発環境 | Xcode 26.1以降 / XcodeGen |
| 対応予定 | iOS 26.0 / macOS 26.0以降 |
| UI | SwiftUI |
| ローカル推論 | llama.cpp / LiteRT-LM |
| 秘密情報 | Keychain |

## プロジェクト生成とビルド

```sh
xcodegen generate
```

macOSの署名なし確認ビルド:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

iOS Simulatorの署名なし確認ビルド:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 主な構成

```text
KizunaAI/
├── App/                       # 起動、設定、ワークスペース
├── AI/
│   ├── CharacterLibrary/      # キャラクター、記憶、物語、安全性
│   ├── PersonaChatService.swift
│   ├── LocalAssistantModelManager.swift
│   └── LocalAssistantRuntimeBridge.swift
├── Security/                  # Keychain
├── ThirdParty/                # llama.cpp / LiteRT-LM
└── project.yml                # XcodeGen設定
```

## コントリビューション

IssueやPull Requestでは、可能な範囲で次の情報を含めてください。

- 再現手順、期待した結果、実際の結果
- iOS / macOS、実機 / Simulator、OS、Xcodeのバージョン
- 使用したモデル形式と、ローカル / リモートの生成経路
- APIキーや個人情報を除いたログやスクリーンショット

会話履歴、APIキー、アクセストークン、秘密のURLなどは公開しないでください。

## ライセンスと第三者コンポーネント

第三者コンポーネントのライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) と `Licenses/` を参照してください。
