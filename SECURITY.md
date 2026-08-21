# Security Policy

## 非公開の脆弱性報告

Kizunaでは、脆弱性の受付にGitHub Private vulnerability reportingを使用します。
報告者は、次の非公開フォームから詳細を送信してください。

**[Report a vulnerability（非公開報告フォーム）](https://github.com/VIUK-Light/Kizuna/security/advisories/new)**

このリポジトリではPrivate vulnerability reportingを有効にしています。Maintainerは、
GitHubの **Settings → Advanced Security → Private vulnerability reporting** を無効化せず、
Security / Advisories画面に **Report a vulnerability** が表示されることを継続的に確認します。

次の公開スペースには、脆弱性の詳細を投稿しないでください。

- Issues
- Pull Requests
- Discussions
- 公開チャット、SNS、その他の公開ページ

非公開報告フォームが表示されない場合は、脆弱性の存在や詳細を公開してはいけません。
これは受付設定の障害として扱い、MaintainerがPrivate vulnerability reportingを復旧してから
報告を受け付けます。公開Issueをfallbackにしてはいけません。

この報告経路はセキュリティ脆弱性専用です。行動上の懸念やコミュニティ運営に関する相談は、
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)の報告手順を確認してください。

## 報告に含める情報

可能な範囲で次の情報を含めてください。

- 影響を受けるバージョンまたはコミット
- 影響を受けるiOS / macOS環境
- 脆弱性の種類と想定される影響
- 安全に共有できる再現条件
- 回避策がある場合はその内容

APIキー、アクセストークン、Cookie、個人の会話履歴、実在する利用者のデータは送信しないでください。

## 対象

特に次の領域をセキュリティ上重要な領域として扱います。

- Keychainと秘密情報管理
- モデルやランタイムのダウンロード・検証
- 外部API通信
- ローカルモデル実行境界
- 会話履歴、記憶、個人データの保存
- GitHub Actionsと依存関係

## 対応と公開時期

Maintainerは、Private vulnerability reportingで受け取った内容を非公開で確認し、
影響範囲、再現性、対応の優先度を判断します。初回確認や修正の期限は、報告内容と
対応可能な範囲に応じて個別に決まります。

修正方法、回避策、利用者への影響を確認する前に、脆弱性の詳細を公開しません。
必要に応じて、修正リリース、GitHub Security Advisory、CVE、協調公開の時期をMaintainerと
報告者で調整します。

## Supported versions

Kizunaは開発中です。セキュリティ修正は原則として最新の`main`と、公開されている場合は
最新リリースを対象にします。古いコミットや未サポートの派生版について、修正を保証する
ものではありません。

## Private vulnerability reporting

Kizuna uses GitHub Private vulnerability reporting as its permanent intake channel for security
vulnerabilities. Submit a report through the **[private Report a vulnerability form](https://github.com/VIUK-Light/Kizuna/security/advisories/new)**.

Do not disclose vulnerability details in public Issues, Pull Requests, Discussions, chats, or
social media. If the private form is unavailable, do not use a public Issue as a fallback; the
maintainers must restore the repository setting before accepting a detailed report.

The private reporting channel is for security vulnerabilities only. For sensitive conduct
concerns, follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Include the affected version or commit, affected iOS / macOS environment, vulnerability type,
impact, safe reproduction conditions, and mitigations when available. Never include API keys,
access tokens, cookies, private conversation history, or real user data.

Maintainers will triage reports privately and coordinate remediation and disclosure timing with
the reporter when appropriate. Kizuna is under active development; security fixes target the
latest `main` and, when published, the latest release.
