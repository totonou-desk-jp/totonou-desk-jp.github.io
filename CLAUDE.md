# CLAUDE.md — 整うデスク ブログ実装ルール

このリポジトリは「整うデスク」ブログ（デスク周り・机の整え方の実用記事メディア）。設計の正本は
`D:\Claude_Code\AI_DropShipping_Store\research\blog-design-plan.md`（承認記録は同ファイル冒頭）。
本ファイルの規約は本リポジトリでの実装作業において常に優先される。

## ブランド

- ブランド名: 「整うデスク」。SNS（TikTok・Instagram）で先行運用中のブランドの新チャネル。
  詳細は `D:\Claude_Code\AI_DropShipping_Store\research\stage1-plan.md`
- コンセプト・トーン: 「机の上を、静かに整える」。静かで簡潔、煽らない。「絶対に」「一番」等の断定的な煽り文言は使わない
- 対象読者: 在宅ワーク・デスク環境の整え方に関心がある層

## 絶対規約

1. 記事本文は日本語・算用数字（漢数字は使わない）
2. 絵文字は使用しない
3. 実体験を装う表現（「私が使ってみた」等）は禁止。比較データの捏造は禁止。価格を書く場合は変動する可能性がある旨の注記を必ず添える
4. アフィリエイトリンクは `_data/affiliates.yml` のキーを参照するインクルード（`{% include affiliate.html id="..." %}`）のみで挿入する。本文への生URL直書きは禁止
5. 記事Markdownは `scripts/validate-article.ps1` を通過してからコミット・PR作成する
6. 内部リンクは `{% post_url YYYY-MM-DD-slug %}` タグで張る（リンク先が存在しないとビルドが失敗し、内部リンク切れを機械的に検出できる）

## 承認フロー

生成 → `draft/YYYY-MM-DD-<slug>` ブランチへコミット・push → `gh pr create` → 人間がPR画面で読み、
**マージ＝承認＝公開**。差し戻しは PR コメントに指示を書き、`scripts/revise-article.ps1` が指示を取得して
修正・追い push する。詳しい手順は `docs/operations-runbook.md` を参照。

## URL・移設可搬性

- baseurl: `/totonou-desk`、パーマリンク: `/posts/:slug/`（日付をURLに含めない）
- サイト内リンクは必ず `relative_url` フィルタ（または `post_url` タグ）を経由する。ベースパスの変更は
  `_config.yml` の `baseurl` 一箇所で完結させる

## 生成パイプライン

- `prompts/article-generation.md`: 記事生成プロンプト（実行基盤に依存しない資産）
- `scripts/generate-article.ps1`: `_data/topics.yml` からネタを選び、生成・検証・ブランチ作成・push・PR作成まで行う
- `scripts/revise-article.ps1`: PRコメントの指摘を取り込み、修正して追い push する
- `scripts/validate-article.ps1`: 機械検証（ローカル・GitHub Actions共通で使用する同一スクリプト）
- 定期実行: 毎週日曜21時（`scripts/register-scheduled-task.ps1` でWindowsタスクスケジューラに登録）

## データ

- `_data/affiliates.yml`: アフィリエイトプログラムの有効フラグと商品キー→リンクの対応。リンク未確定時は
  商品名のみのテキスト表示にフォールバックする
- `_data/topics.yml`: 記事ネタのバックログ（`status: queued` / `used`）

## Pages標準ビルドの制約

GitHub Pages標準ビルド（Jekyll、`github-pages` gem）を使う。使用プラグインは
`jekyll-seo-tag` / `jekyll-sitemap` / `jekyll-feed` の3種のみ（Pagesのプラグインwhitelist内）。
ローカルにRuby等のビルド環境は用意しない。
