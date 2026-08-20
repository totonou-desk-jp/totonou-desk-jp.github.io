<#
.SYNOPSIS
    _data/topics.yml のネタを1本消化して記事を生成し、検証・push・PR作成まで行う。
.DESCRIPTION
    処理順: (1) topics.ymlからstatus: queuedの先頭ネタを選ぶ (2) draft/YYYY-MM-DD-<slug>ブランチを作成
    (3) prompts/article-generation.mdを土台にプロンプトを組み立て、claude -pで記事Markdownを生成
    (4) scripts/validate-article.ps1で検証 (5) 検証通過時のみtopics.ymlのstatusをusedへ更新し、
    コミット・push・gh pr create。
    gh CLIが未導入の場合は、pushまで行いPR作成手順を案内して終了する
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

function Invoke-Git {
    # gitはネイティブコマンドのため$ErrorActionPreference='Stop'では失敗が捕捉されない。
    # $LASTEXITCODEを明示的に検査し、失敗時は例外として上位へ伝える。
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') が失敗しました（終了コード $LASTEXITCODE）。"
    }
}

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
    [System.IO.File]::WriteAllText($TopicsPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
}

# 1. テーマ決定
$topicsPath = Join-Path $repoRoot '_data/topics.yml'
$affiliatesPath = Join-Path $repoRoot '_data/affiliates.yml'
if ($Topic) {
    $selectedTopic = [PSCustomObject]@{ Slug = $null; Title = $Topic; SourceRef = '手動指定' }
} else {
    $selectedTopic = Get-NextQueuedTopic -TopicsPath $topicsPath
    if (-not $selectedTopic) {
        Write-Host "topics.yml に status: queued のネタがありません。_data/topics.yml を確認してください。"
        exit 1
    }
}

$date = Get-Date -Format 'yyyy-MM-dd'
$slug = if ($selectedTopic.Slug) { $selectedTopic.Slug } else { ($selectedTopic.Title -replace '[^a-zA-Z0-9]+', '-').ToLower().Trim('-') }
if ([string]::IsNullOrEmpty($slug)) {
    throw "テーマ「$($selectedTopic.Title)」から英数字のスラッグを生成できませんでした。-Topic には英数字を含む文字列を指定するか、_data/topics.yml にslug付きのエントリとして追加してください。"
}

# 2. ブランチ作成
Invoke-Git fetch origin main
Invoke-Git checkout main
Invoke-Git pull origin main
$branch = "draft/$date-$slug"
Invoke-Git checkout -b $branch
if ((git rev-parse --abbrev-ref HEAD) -ne $branch) {
    throw "draftブランチへの切り替えに失敗しました: $branch"
}

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
- タイトル案: $($selectedTopic.Title)
- 出典: $($selectedTopic.SourceRef)

## 既存記事一覧（内部リンク候補）
$existingPostsList

## 出力先
_posts/$postFileName
"@

# 5. Claude Code CLI呼び出し（記事Markdown本体のみを標準出力させる）
# BOM付きUTF-8で書き出すとJekyllのfront matter判定（先頭が---か）に失敗し記事が公開されない場合があるため、
# BOMなしUTF-8で明示的に書き出す（Out-File -Encoding UTF8はWindows PowerShell 5.1ではBOM付きになる）。
$postPath = Join-Path $repoRoot "_posts/$postFileName"
$article = claude -p $fullPrompt | Out-String
if ([string]::IsNullOrWhiteSpace($article)) {
    throw "記事生成に失敗しました（出力が空です）。"
}
[System.IO.File]::WriteAllText($postPath, $article, (New-Object System.Text.UTF8Encoding($false)))

# 6. 機械検証
& (Join-Path $repoRoot 'scripts/validate-article.ps1') -Path $postPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "validate-article.ps1 が失敗しました。push/PR作成を中止します。ブランチ $branch とファイルはローカルに残しています。"
    exit 1
}

# 7. topics.ymlを更新（検証通過後のみ。検証失敗時にネタが消費されたまま記事が残らないようにする）
if ($selectedTopic.Slug) {
    Set-TopicStatusUsed -TopicsPath $topicsPath -Slug $selectedTopic.Slug
}

if ($SkipPush) {
    Write-Host "SkipPush指定のため、push/PR作成を行わずに終了します。生成物: $postPath"
    exit 0
}

# 8. コミット・push
# _data/affiliates.ymlも対象に含める。生成プロンプトの指示（prompts/article-generation.md）で
# 未登録のアフィリエイトキーをitemsへ追加した場合、その追記を同じPRに載せるため。
Invoke-Git add $postPath $topicsPath $affiliatesPath
Invoke-Git commit -m "feat(posts): $($selectedTopic.Title) を追加"
Invoke-Git push -u origin $branch

# 9. PR作成（gh CLI前提。未導入の場合はpushまでで終了する）
$ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghAvailable) {
    Write-Host "gh CLIが見つかりません。ブランチ $branch はpush済みです。'gh pr create' を手動実行するか、gh CLI導入後に再実行してください。"
    exit 0
}
gh pr create `
    --title "記事: $($selectedTopic.Title)" `
    --body "自動生成記事です。出典ネタ: $($selectedTopic.SourceRef)`n`nvalidate-article.ps1: 通過済み" `
    --base main `
    --head $branch
