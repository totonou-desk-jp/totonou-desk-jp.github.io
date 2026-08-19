<#
.SYNOPSIS
    _data/topics.yml のネタを1本消化して記事を生成し、検証・push・PR作成まで行う。
.DESCRIPTION
    処理順: (1) topics.ymlからstatus: queuedの先頭ネタを選ぶ (2) draft/YYYY-MM-DD-<slug>ブランチを作成
    (3) prompts/article-generation.mdを土台にプロンプトを組み立て、claude -pで記事Markdownを生成
    (4) topics.ymlのstatusをusedへ更新 (5) scripts/validate-article.ps1で検証
    (6) 検証通過時のみコミット・push・gh pr create。
    gh CLIが未導入/未認証の場合は、pushまで行いPR作成手順を案内して終了する
    （承認済み設計の確定事項: gh CLI未導入のためリモートpush・PR作成は段階0完了後の後続作業）。
.PARAMETER Topic
    指定時はtopics.ymlのバックログを使わず、このテーマ文字列で生成する（手動テスト・単発トピック用）。
.PARAMETER SkipPush
    指定時はpush・PR作成を行わず、ローカルでの生成・検証結果のみ確認する。
#>
[CmdletBinding()]
param(
    [string]$Topic,
    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Get-NextQueuedTopic {
    param([string]$TopicsPath)
    $content = Get-Content -Path $TopicsPath -Raw -Encoding UTF8
    # topics.ymlはこのスクリプトが読み書きする単純な固定構造のみを想定した軽量パーサー。
    # 汎用YAMLパーサーではないため、フォーマット（キーの順序・インデント）を崩すと正しく解釈できない。
    $entries = [regex]::Matches(
        $content,
        '(?ms)^\s*-\s*slug:\s*(?<slug>\S+)\s*\r?\n\s*title:\s*(?<title>.+?)\s*\r?\n\s*source_ref:\s*(?<source>.+?)\s*\r?\n\s*status:\s*(?<status>\S+)'
    )
    foreach ($e in $entries) {
        if ($e.Groups['status'].Value -eq 'queued') {
            return [PSCustomObject]@{
                Slug      = $e.Groups['slug'].Value
                Title     = $e.Groups['title'].Value.Trim('"', "'")
                SourceRef = $e.Groups['source'].Value.Trim('"', "'")
            }
        }
    }
    return $null
}

function Set-TopicStatusUsed {
    param([string]$TopicsPath, [string]$Slug)
    $content = Get-Content -Path $TopicsPath -Raw -Encoding UTF8
    $pattern = "(?ms)(-\s*slug:\s*$([regex]::Escape($Slug))\s*\r?\n(?:.*?\r?\n)*?\s*status:\s*)queued"
    $updated = [regex]::Replace($content, $pattern, '${1}used', 1)
    Set-Content -Path $TopicsPath -Value $updated -Encoding UTF8 -NoNewline
}

# 1. テーマ決定
$topicsPath = Join-Path $repoRoot '_data/topics.yml'
if ($Topic) {
    $topic = [PSCustomObject]@{ Slug = $null; Title = $Topic; SourceRef = '手動指定' }
} else {
    $topic = Get-NextQueuedTopic -TopicsPath $topicsPath
    if (-not $topic) {
        Write-Host "topics.yml に status: queued のネタがありません。_data/topics.yml を確認してください。"
        exit 1
    }
}

# 2. ブランチ作成
git fetch origin main
git checkout main
git pull origin main
$date = Get-Date -Format 'yyyy-MM-dd'
$slug = if ($topic.Slug) { $topic.Slug } else { ($topic.Title -replace '[^a-zA-Z0-9]+', '-').ToLower().Trim('-') }
$branch = "draft/$date-$slug"
git checkout -b $branch

# 3. 既存記事一覧（内部リンク候補としてプロンプトに渡す）
$existingPosts = Get-ChildItem -Path (Join-Path $repoRoot '_posts') -Filter '*.md' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name }
$existingPostsList = if ($existingPosts) { ($existingPosts -join "`n") } else { '（既存記事なし）' }

# 4. プロンプト組み立て
$promptTemplate = Get-Content -Path (Join-Path $repoRoot 'prompts/article-generation.md') -Raw -Encoding UTF8
$postFileName = "$date-$slug.md"
$fullPrompt = @"
$promptTemplate

## 今回のテーマ
- タイトル案: $($topic.Title)
- 出典: $($topic.SourceRef)

## 既存記事一覧（内部リンク候補）
$existingPostsList

## 出力先
_posts/$postFileName
"@

# 5. Claude Code CLI呼び出し（記事Markdown本体のみを標準出力させる）
$postPath = Join-Path $repoRoot "_posts/$postFileName"
claude -p $fullPrompt | Out-File -FilePath $postPath -Encoding UTF8

# 6. topics.ymlを更新
if ($topic.Slug) {
    Set-TopicStatusUsed -TopicsPath $topicsPath -Slug $topic.Slug
}

# 7. 機械検証
& (Join-Path $repoRoot 'scripts/validate-article.ps1') -Path $postPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "validate-article.ps1 が失敗しました。push/PR作成を中止します。ブランチ $branch とファイルはローカルに残しています。"
    exit 1
}

if ($SkipPush) {
    Write-Host "SkipPush指定のため、push/PR作成を行わずに終了します。生成物: $postPath"
    exit 0
}

# 8. コミット・push
git add $postPath $topicsPath
git commit -m "feat(posts): $($topic.Title) を追加"
git push -u origin $branch

# 9. PR作成（gh CLI前提。未導入/未認証時はpushまでで終了する）
$ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghAvailable) {
    Write-Host "gh CLIが見つかりません。ブランチ $branch はpush済みです。'gh pr create' を手動実行するか、gh CLI導入後に再実行してください。"
    exit 0
}
gh pr create `
    --title "記事: $($topic.Title)" `
    --body "自動生成記事です。出典ネタ: $($topic.SourceRef)`n`nvalidate-article.ps1: 通過済み" `
    --base main `
    --head $branch
