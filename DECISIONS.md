# Kizuna 設計判断記録

最終更新: 2026-08-14 (JST)

## プロダクト体験

1. Kizunaの中心価値は「Characterとすぐ話せ、積み重ねに根拠がある時だけ世界が半歩動く」。
2. ユーザー向け導線は「会話 / ストーリー / マイページ」の3タブに固定する。
3. Characterタップは即時に既存会話を再開し、なければ会話を作る。World作成、モード選択、長い説明を間に挟まない。
4. 上部プロフィールアイコンは置かない。プロフィール画像はマイページからユーザー自身の画像へ変更できる既存機能を維持する。
5. PersonaChatは削除しない。Persona履歴は通常の会話履歴として到達可能にし、共通engineへ移す場合もコピー移行で元データを残す。
6. 「どんな物語から始める？」「好きな世界観」「会話で伝えておきたいこと」や新しいPrivate Space / 安全モード導線は追加しない。

## Storyの自然な展開

1. StoryEvent、イベントFSM、pendingWorldMove、固定5〜8ターン、start / continue / resolve / abandon、イベントカード、専用タイトル、専用通知、追加LLM呼び出しは採用しない。
2. 通常応答の中で、現在Sceneの具体的対立・目的、StoryState、active Character、現在Sessionの関連Memoryに因果的な根拠がある場合だけ、0〜1件の短い観測可能な変化を許可する。
3. 何も起きない方が自然なら変化を作らない。新人物、電話、ノック、停電などをイベントらしさのために発明しない。
4. ユーザーの台詞、確定行動、感情、内心は生成しない。ユーザーが別方向へ進めた場合はその入力を優先する。
5. 通常会話では表情・視線・間などのcharacter reactionまでに留め、Storyの構造化World stateを発明しない。

## データ整合性

1. Story Turnはbegin / commit / fail / cancel / retryとrevisionを中心に原子的に扱う。生成中にJSON lockを保持しない。
2. 同じturnIDのbegin / commitは冪等にし、User messageの重複やAI replyの二重確定を防ぐ。
3. pending Turnは起動時にinterruptedとして復元し、再試行または破棄を明示的に選べるようにする。
4. reply、StoryState、progress、hooks、scene summary、active cast、Memoryの確定は同じ論理Turnで扱う。補助保存が失敗してもモデルを再実行しない。
5. 壊れたsession fileやPersonaデータを正常recordだけで自動上書きしない。破損時は書き込みを止め、read-onlyまたは明示的復旧にする。
6. Sessionを越えてMemory、summary、active castを漏らさない。自動MemoryにはSession IDとTurn IDを付け、Undo済み・存在しないTurn由来のMemoryは注入しない。
7. STATE_UPDATEはFoundation-only Parserで処理し、metadataは成否にかかわらず可視本文から除去する。truncated JSON、複数marker、空Patch、不正値、Safety rewrite前のPatchは適用しない。

## Personaデータ

1. ReasoningMode.persona、runtime preset、persona.threads.v1のschema、既存migrationは維持する。
2. 書き出しはraw UserDefaults blob、機械可読JSON、人間可読textを用意し、thread ID、Character ID、role、本文、日時、schema version、app versionを含める。
3. 全会話削除や破損データresetは明示操作だけにする。自動reset、purge、到達不能化は行わない。
4. 旧reader / exportを削除できるのは、少なくとも2つの公開buildかつ90日経過後の遅い方以降。

## 実験・安全

1. storyInitiativeNAGIとstoryInitiativeIoriは別flagで、既定OFF。通常Release buildはUserDefaultsやstale developer stateに関係なくOFF。
2. DebugまたはKIZUNA_INTERNAL_CANARYだけが明示launch argumentでcanaryを有効化できる。ユーザー向け設定は追加しない。
3. 評価はJA / EN × iori / NAGI × 16 scenarios × 3 seeds、192 paired turns / 384 model outputsとする。
4. baselineとinitiativeは同じshared contextを使い、pair input hashは一致、condition-specific prompt hashは差分として記録する。
5. generation failureは捨てずにstatus付きで保存する。blind artifactは不完全出力を拒否する。
6. blind A/Bはcondition、model、scenario、seed、latency、hash、pair IDを評価者へ出さず、private answer keyで対応付ける。
7. tieはrated pairとして0.5を加算し、preference shareを計算する。120以上のrated pairs、preference share、bootstrap下限、agency、safety、irrelevant、continuity、latency、operational failureを全てGO gateにする。
8. GO未達時は機能を既定ONにせず、StoryEvent FSMで救済しない。

## 開発・公開運用

1. 共有canonical checkoutは編集しない。SSD上のclean worktreeで作業する。
2. PRは依存順に1本ずつ作り、直前のPRがmainへマージされるまで次のPRを作らない。
3. commit、push、PR、Issue、レビューコメントはVIUK-Codex-Bot / 148663275+VIUK-Codex-Bot@users.noreply.github.comで行う。
4. VIUK-XVがレビューとマージを行う。Codex側は自動マージしない。
5. Ready PRのCI compileは必須だが、ローカルのフルアプリbuildは必須にしない。
6. prompt機能はflagをOFFにして即時rollbackできる。保存schemaはoptional追加で旧データを削除しない。
