# kizuna
Kizunaは、VIUK-Lightが掲げる「責任なるAI」という目標のもと開発された、AIとの対話を通してキャラクターとの関係や物語を育てていくアプリです。

### 明るい未来へ
依存させることが目的ではありません。
AIへの依存問題は日々取り上げられています。しかしAIは悪なのでしょうか。AIを通じで新たな娯楽や幸せ、居場所を獲得した人も多いと思います。確かにAIへの依存は現実に大きく影響してしまいます。しかしそれを対策しようと必要以上に冷たくしてしまうと、居場所がなくなってしまうかもしれません。安全性を高めることは重要ですが高めすぎないことも重要です。

#### 「過度な安全性は安全性の失敗」です。


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



## APIキーと秘密情報

旧VIUK One の API キーや平文の秘密情報は、新アプリへコピーも同梱もされません。右上の設定画面からNAGI APIキーを再設定してください。同じ画面でioriローカルモデルのURL、アクセストークン、ダウンロード、起動確認も管理できます。

開発実行では、必要に応じて `GEMMA_API_KEY`、`GOOGLE_API_KEY`、`GEMINI_API_KEY`、`OLLAMA_WEB_SEARCH_API_KEY`、`OLLAMA_API_KEY`、`TEXTRAZOR_API_KEY` の環境変数を使用できます。永続保存する秘密情報は `AISecretStore` を通して Keychain に保存し、`Info.plist`、ソースコード、UserDefaultsへ平文で追加しないでください。

旧プロジェクトに平文キーが残っていた場合は、そのキーを無効化して再発行することを推奨します。

## サードパーティー

同梱するランタイムとライブラリのライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。
