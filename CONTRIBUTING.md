# Contributing to Kizuna

[English](CONTRIBUTING.en.md)

Kizunaへの関心と貢献ありがとうございます。小さな修正、ドキュメント改善、再現手順の提供、設計提案も歓迎します。

## 行動の基本

- 利用者の意思、プライバシー、現実の生活を尊重してください。
- キャラクター体験と安全性のどちらかを安易に切り捨てないでください。
- IssueやPRに、APIキー、アクセストークン、Cookie、秘密のURL、個人の会話履歴、モデルファイルを掲載しないでください。
- 会話例やログが必要な場合は、匿名化・要約してください。
- 他の参加者への攻撃、差別、嫌がらせは認めません。

詳細な適用範囲、対応方針、非公開の行動問題報告手順は
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)を確認してください。行動問題の詳細を
公開Issue、Pull Request、Discussionへ投稿しないでください。

## 貢献の流れ

1. 大きな機能や設計変更は、実装前にIssueで目的と影響範囲を相談してください。
2. リポジトリをForkし、目的が分かる短いブランチ名を付けてください。
3. 1つのPRには、原則として1つの目的だけを含めてください。
4. 変更に応じたビルド、テスト、手動確認を行ってください。
5. PRテンプレートを埋め、未確認事項や既知の制限を明記してください。

## PRの規模

レビュー可能な大きさを優先します。大規模なリファクタリングと機能追加を同じPRへ混在させないでください。生成物、DerivedData、モデルキャッシュ、個人用Xcode設定はコミットしないでください。

## AI支援による変更

AIツールを使った貢献も受け付けます。ただし、提出者が変更内容を理解し、動作・安全性・ライセンスを確認する責任を負います。

PR本文には次を記載してください。

- AI支援を使用したか
- 使用した場合は、主なツールまたはモデル
- 提出者自身が確認した範囲

未確認の大量生成コード、説明できない変更、既存コードを無断で置き換える変更は受け入れない場合があります。

## 開発環境

- macOS
- Xcode 26.1以降
- XcodeGen
- iOS 26.0 / macOS 26.0以降

`project.yml`を変更した場合は、リポジトリ直下で次を実行してください。

```sh
xcodegen generate
```

macOS確認ビルド:

```sh
xcodebuild -project KizunaAI.xcodeproj -scheme KizunaAI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

iOS Simulator確認ビルド:

```sh
xcodebuild -project KizunaAI.xcodeproj -scheme KizunaAI -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## レビュー基準

メンテナーは主に次を確認します。

- 変更目的が明確か
- Kizunaの設計思想と整合するか
- 利用者の意思、プライバシー、安全性を損なわないか
- キャラクター性や通常の創作体験を不必要に壊さないか
- 秘密情報を含まないか
- 変更に必要な検証が行われているか
- 保守可能で、不要な複雑性を増やしていないか

PRは修正依頼、保留、またはクローズされる場合があります。クローズは貢献者個人への否定ではなく、スコープ、品質、保守性、方針との整合性に基づく判断です。

## 文言の追加（国際化）

UI文言の追加・変更は [docs/i18n.md](docs/i18n.md) の方針に従ってください。

- **新規画面・新規文言で `KizunaCopy.text` を使わない。**
  `Localizable.xcstrings`（String Catalog）にキーを追加して使う。
- 既存画面の `KizunaCopy.text` は、その画面を変更するタイミングで
  あわせて String Catalog へ移行する。
- 複数形が分かれる英語文言は `KizunaCopy.pluralText`（移行後は複数形
  エントリ）を使い、日付・時刻の固定書式（`HH:mm` 等）を書かない。

## ライセンス

提出した変更は、このリポジトリのライセンス条件で配布できるものとします。第三者のコード、画像、モデル、データを追加する場合は、利用条件と出典を明示してください。

## 入口Issueと現在の方向性

- [good first issue](https://github.com/VIUK-Light/Kizuna/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
- [help wanted](https://github.com/VIUK-Light/Kizuna/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
- [公開Roadmap](ROADMAP.md)

ラベルが付いたIssueでも、着手前に完了条件と現在の方針を確認してください。大きな変更、永続化、Security、AI runtime、Web/別プラットフォーム対応は、実装前にIssueで相談してください。
