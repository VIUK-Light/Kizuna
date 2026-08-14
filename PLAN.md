# Kizuna 継続作業計画

最終更新: 2026-08-14 (JST)

## 目的

Kizunaを「会話 + ストーリー」として整理し、会話を邪魔せず、現在のScene・StoryState・Character・Memoryに根拠がある時だけStory内の世界を自然に半歩動かす。

PersonaChatは削除しない。ユーザー向けの入口は「会話 / ストーリー / マイページ」の3タブとし、CharacterをタップしたらWorld作成やモード選択を挟まず直ちに会話を開始する。

## 守る条件

- StoryEvent、イベントFSM、pendingWorldMove、固定ターン数、イベントカード、専用ラベル、専用通知、追加LLM呼び出しを追加しない。
- ユーザーの台詞・確定行動・感情・内心をAIが代筆しない。
- Storyの変化は0〜1件の観測可能なmicro changeに限定し、因果的な根拠がなければ何も変えない。
- Persona履歴・既存データを自動削除、purge、reset、到達不能化しない。
- 破損データは正常データだけで黙って上書きせず、read-onlyまたは復旧待ちとして扱う。
- 各PRは、直前のPRがmainへマージされた後に作成する。PRが開いている間は新しいPRを作らず、修正は同じPRへ積む。
- マージはVIUK-XVが行う。自動マージしない。

## 依存順と進捗

1. テスト・CI基盤 — 完了
2. UI / 情報設計 — 完了
3. Story Turnの原子的保存 — 完了
4. Session境界・State更新・STATE_UPDATE Parser — 完了
5. 応答の取消・再生成・回復 — 完了
6. Personaデータ保護・書き出し — 完了
7. 自然なStory initiativeのbaseline / canary導入 — PR #259としてmainへマージ済み
8. 実験入力・出力契約、16シナリオfixture、blind評価器、内部canary評価経路 — PR #261で実装済みだが未マージ

## 現在の次作業

1. PR #261のCodeRabbit未解決6件を現行仕様と照合する。
2. 有効な指摘だけを同じbranchへ修正し、回帰テストを追加する。
3. 同じPRへpushし、CIとCodeQL / Swiftを再確認する。
4. VIUK-XVへレビュー・マージを依頼する。自動マージしない。
5. マージ後にIssue #260が閉じたこと、mainのcommit、required checks、fixture評価器を確認する。
6. その後、PR #261で実験の実入力を作成し、GO条件を満たすまでinitiativeを既定ONにしない。
7. NAGIのGO後にioriをcanary評価し、ioriのbyte制限・実機評価・安全条件を確認する。

## 完了条件

- 3タブ、即時会話、Storyの全Session到達、Persona履歴保護がmain上で維持されている。
- Turn保存・Session境界・Parser・Undo / retry / cancelの整合性がテストで証明されている。
- PR #261がマージされ、Issue #260が解決状態になる。
- JA / EN × iori / NAGI × 16シナリオ × 3 seedの実験入力が同一契約で記録される。
- 192 paired turns / 384 model outputsの実験を、失敗出力を隠さずblind評価できる。
- 120以上のrated blind pairs、選好率、95% bootstrap下限、agency / safety / irrelevant / continuity / latencyの全GO条件を満たすまで既定ONにしない。
- GOしなかった場合にStoryEvent FSMなどで救済しない。

## 検証方針

- ローカルは対象テスト・Swift parse・XcodeGen Drift・plutil lint・git diff --checkを実行する。
- Ready PRではCIのUnit、macOS、iOS Simulator、iOS Device、XcodeGen、必要なUI smokeを確認する。
- フルアプリのローカルbuildは必須にしない。
- 実験のblind keyは評価者へ渡さず、生成JSONL・blind JSONL・rating JSONL・report JSONを分離する。

## 作業場所

- 共有canonical checkout: /Volumes/SSD/Workspace/Projects/Kizuna_ai（読み取り専用）
- 現在の隔離worktree: /Volumes/SSD/Workspace/Projects/Kizuna_ai_acceptance_20260814
- 現在のbranch: codex/story-acceptance-20260814
