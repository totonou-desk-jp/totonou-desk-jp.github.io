# 整うデスク（totonou-desk）

デスク周り・机の整え方の実用記事を配信するブログ。GitHub Pages（Jekyll標準ビルド）で構築し、
週1回AIが記事を生成、人間がPRレビューで承認して公開する「承認ゲート付き95%自動」の運用を行う。

設計の正本は `D:\Claude_Code\AI_DropShipping_Store\research\blog-design-plan.md`。
実装規約は `CLAUDE.md`、運用手順は `docs/operations-runbook.md` を参照。

## 構成

- サイト本体: `_layouts/`, `_includes/`, `_data/`, `_posts/`, `pages/`, `index.md`, `assets/`
- 生成パイプライン: `prompts/article-generation.md`, `scripts/generate-article.ps1`,
  `scripts/revise-article.ps1`, `scripts/validate-article.ps1`, `scripts/register-scheduled-task.ps1`
- CI: `.github/workflows/validate.yml`（PR時に `validate-article.ps1` を実行）
- 運用: `docs/operations-runbook.md`

## ブランド画像について

`assets/images/` の4点（`icon.png` / `icon-zoom.png` / `banner.png` / `banner-x.png`）は、
`D:\Claude_Code\AI_DropShipping_Store\assets\totonou-desk\` にある原本のコピーである。
画像の作成・更新は原本側で行い、更新後にこのディレクトリへ再コピーする。
