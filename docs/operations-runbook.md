# 運用手順書（整うデスク ブログ）

設計の正本は `D:\Claude_Code\AI_DropShipping_Store\research\blog-design-plan.md`。本書はその「段階0」「段階3」に対応する実作業手順をまとめる。

## 段階0: ユーザー作業（完了）

サイト骨格・生成パイプラインの実装（本リポジトリの大半）と以下のユーザー作業はいずれも完了済み。2026-08-20にリポジトリをOrganizationへ移管・リネームし（`totonou-desk-jp/totonou-desk-jp.github.io`）、サイトは `https://totonou-desk-jp.github.io/` で公開されている。以下の番号付き手順は移管前の初回セットアップ時の記録。

1. GitHubアカウントの確認（Freeプランで可。Pagesはpublicリポジトリで無料公開できる）
2. [gh CLI](https://cli.github.com/) のインストール（インストーラーの実行にUAC承認が必要なため、ユーザー作業）
3. `gh auth login` によるGitHub認証
4. GitHub上にリポジトリ `totonou-desk`（public）を作成
5. ローカルの `D:\Claude_Code\totonou-desk` をリモートリポジトリに紐付けてpush
   ```
   git remote add origin https://github.com/<GitHubユーザー名>/totonou-desk.git
   git push -u origin main
   ```
6. リポジトリの Settings → Pages で、Source を「Deploy from a branch」・ブランチを `main`・ディレクトリを `/`（ルート）に設定して有効化
7. `_config.yml` の `url:` を `https://<GitHubユーザー名>.github.io` に更新してコミット（当時のbaseurl設定は `/totonou-desk`）
8. Pages公開後、`https://<GitHubユーザー名>.github.io/totonou-desk/` でトップページ・サンプル記事・固定ページ（運営者情報／プライバシーポリシー／広告ポリシー）の表示を確認する

## 週次サイクル（段階0完了後）

| タイミング | 作業 | 担当 |
|---|---|---|
| 毎週日曜21:00 | `scripts/generate-article.ps1` が自動実行される（Task Scheduler登録後）。`_data/topics.yml` からネタを1本選び、記事を生成・検証し、draftブランチをpushしてPRを作成する | AI（自動） |
| PR作成後、数日以内 | GitHubのPR画面（PC/スマホアプリ）で記事を読み、問題がなければマージする。マージ＝承認＝公開（Pagesが自動的に再ビルドされる） | あなた（約5分） |
| 差し戻したい場合 | PRにレビューコメントで修正指示を書き、`powershell -File scripts\revise-article.ps1 -PullRequestNumber <PR番号>` を実行する。修正稿が同じブランチへ追いpushされ、同じPRに反映される。再度PR画面で確認しマージする | あなた＋AI |

## Task Scheduler登録手順

段階0（gh CLI認証）完了後、運用開始時に以下を実行する。

```
powershell -File D:\Claude_Code\totonou-desk\scripts\register-scheduled-task.ps1
```

- 毎週日曜21:00に `scripts/generate-article.ps1` を実行するタスクを登録する
- PCの電源が入っていない等でスケジュール実行を逃した場合は、`StartWhenAvailable` 設定により次回PC起動時に実行される
- 登録内容の確認・削除
  ```
  Get-ScheduledTask -TaskName 'TotonouDesk-WeeklyArticleGeneration'
  Unregister-ScheduledTask -TaskName 'TotonouDesk-WeeklyArticleGeneration' -Confirm:$false
  ```

## トラブルシュート

- `gh` コマンドが見つからない: gh CLIが未インストール、またはPATHが通っていない。インストール後にターミナルを開き直す
- `gh pr create` が失敗する: `gh auth status` で認証状態を確認し、必要なら `gh auth login` を再実行する
- `validate-article.ps1` が失敗する: 出力されたエラー内容に従って `_posts/` 配下の該当ファイルを修正し、再実行する（検査項目は `scripts/validate-article.ps1` の実装を参照）
- 生成された記事の内容に問題がある: PRをマージせず、レビューコメントで指摘してから `revise-article.ps1` を使う（直接ローカルでファイルを書き換えてpushしても動作はするが、承認証跡がPRコメントに残らなくなる）
- 日曜の自動実行後にPRが作成されていない: `logs\generate-article.log` の末尾を確認する（週次実行の標準出力・エラーはこのファイルに追記される）

## 段階4（後日・別ラウンド、本書の対象外）

もしもアフィリエイト・楽天ROOMの登録完了後、`_data/affiliates.yml` に実データを投入し、両媒体の規約を確認したうえで広告表記の文言を最終化する。solie.jpへの移設は将来タスクとしてスコープ外。
