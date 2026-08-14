# Kizuna 作業状態

最終更新: 2026-08-14 (JST)

## 現在地

- Worktree: /Volumes/SSD/Workspace/Projects/Kizuna_ai_acceptance_20260814
- Branch: codex/story-acceptance-20260814
- HEAD: 232915c
- HEAD message: [Docs] Record Kizuna plan status and decisions
- implementation commit: d3639df6679ed73d12cd7daae05c4afb8931b073
- 最新確認時点でworktreeはclean
- 共有canonical checkoutは変更していない

## GitHub

- Repository: VIUK-Light/Kizuna
- PR: https://github.com/VIUK-Light/Kizuna/pull/261
- PR state: OPEN
- PR head: VIUK-Codex-Bot:codex/story-acceptance-20260814
- PR author: VIUK-Codex-Bot
- PR merge: 未実施
- Issue: https://github.com/VIUK-Light/Kizuna/issues/260
- Issue state: OPEN（PR #261のマージ後にCloses #260で閉じる予定）
- GitHub active account: VIUK-Codex-Bot
- commit email: 148663275+VIUK-Codex-Bot@users.noreply.github.com

## PR #261の検証状態

pass:

- CodeQL / GitHub Actions
- Dependency Review
- Gemma Script Tests
- Swift Build
- XcodeGen Drift
- iOS Device Compile
- iOS Simulator Compile
- iOS UI Smoke
- macOS Unit Tests
- CodeRabbit

未完了:

- CodeQL / Swift: Build KizunaAI for analysis が長時間実行中。失敗とは確認されていない。

ローカルでpass:

- Python評価器テスト 7件
- 192 paired turns / 384 outputs相当のsynthetic matrix
- 16シナリオfixtureのversion・ID・oracle検証
- Swift parse
- XcodeGen生成とproject drift確認
- plutil -lint
- git diff --check

未実行:

- ローカルのフルアプリbuild（方針どおり）

## CodeRabbitの未対応レビュー

PRはCHANGES_REQUESTED。未解決の指摘は6件として記録する。

1. blind評価テストでcontext内の識別キーも検査し、zip(..., strict=True)にする。
2. user_agency_violationとsafety_hard_violationのGO gateはinitiative側だけを判定し、baselineの内訳は報告だけにする。
3. fixtureのlocalized fieldを型別に厳密化する。user_message / sceneはstring、story_state / characterはobject、history / hard_factsはarray。
4. blind A/B順序のhashに公開pair IDだけでなく、runごとのsecret saltを使う。saltはblind公開データへ出さず、private key metadataだけに保持する。
5. CLIのblind output pathとkey output pathが同一なら、書き込み前に拒否する。
6. safety判断を必要とするJA / ENシナリオを少なくとも1組fixtureへ追加し、safety_classをordinary以外にする。fixture versionとhashを更新する。

対応方針: 6件をすべて現行仕様と照合し、有効なものは同じPRへ修正する。新しいPRは作らない。レビューthreadへの返信・resolveは、修正と検証後に行う。

## 重要な注意

- PR #261が未マージのため、PR #261から派生する新PRを作らない。
- fetch_comments.pyはhead repositoryをVIUK-Codex-Bot/Kizunaとして解決するため、upstream PR #261のthread取得にはそのまま使えなかった。thread取得時はVIUK-Light/Kizunaを明示したGraphQL queryを使う。
- CodeQLがpendingでも自動マージしない。
- PRコメント・commit・Issue操作は常にVIUK-Codex-Bot名義で行う。
