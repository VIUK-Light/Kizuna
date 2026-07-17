# VIUK 絆

VIUK One 内の「絆AI」を独立した iOS / macOS アプリとして動かすプロジェクトです。アプリの Bundle ID は `com.viuk.KizunaAI`、表示名は「VIUK 絆」です。

## 開発環境

- Xcode 26.1 以降
- XcodeGen
- iOS 26.0 / macOS 26.0 以降

macOS向けに必要なllama.cppのarm64静的ライブラリは `ThirdParty/llama.cpp/lib/macos-arm64` に整理して同梱しています。`build-mac`以下のCMake生成物はGit管理しません。

## プロジェクト生成とビルド

`KizunaAI.xcodeproj` は `project.yml` から生成します。設定を変更したときは、リポジトリ直下で次を実行してください。

```sh
xcodegen generate
```

macOS の署名なし確認ビルド:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

iOS Simulator の署名なし確認ビルド:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 初回起動時のデータ移行

macOS版の初回起動時に、VIUK One の既存データが新アプリ専用領域へコピーされます。コピー中は専用の準備画面を表示し、元データは削除しません。

| データ | コピー元 | コピー先 |
| --- | --- | --- |
| キャラクター・物語 | `~/Library/Application Support/VIUK/CharacterLibrary` | `~/Library/Application Support/VIUK/KizunaAI/CharacterLibrary` |
| ローカルAIモデル | `~/Library/Application Support/VIUK One/LocalModels` | `~/Library/Application Support/VIUK/KizunaAI/LocalModels` |

ペルソナの会話スレッド、選択中プロフィール、物語ごとの生成モデル設定も、旧VIUK OneのUserDefaultsから新アプリへコピーされます。

ローカルAIモデルが約5.1 GBある環境では、初回起動時に同程度のコピー時間と空き容量が必要になる場合があります。コピーが完了するまでアプリを終了せず、十分な空き容量を確保してください。

iOSではBundle IDごとにアプリコンテナが分離されるため、旧アプリの端末内データを直接読み取れません。コードと同梱アセットは移行済みですが、iOSのユーザーデータは新規領域から開始します。

## APIキーと秘密情報

旧VIUK One の API キーや平文の秘密情報は、新アプリへコピーも同梱もされません。右上の設定画面からNAGI APIキーを再設定してください。同じ画面でioriローカルモデルのURL、アクセストークン、ダウンロード、起動確認も管理できます。

開発実行では、必要に応じて `GEMMA_API_KEY`、`GOOGLE_API_KEY`、`GEMINI_API_KEY`、`OLLAMA_WEB_SEARCH_API_KEY`、`OLLAMA_API_KEY`、`TEXTRAZOR_API_KEY` の環境変数を使用できます。永続保存する秘密情報は `AISecretStore` を通して Keychain に保存し、`Info.plist`、ソースコード、UserDefaultsへ平文で追加しないでください。

旧プロジェクトに平文キーが残っていた場合は、そのキーを無効化して再発行することを推奨します。

## サードパーティー

同梱するランタイムとライブラリのライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。
