<#
.SYNOPSIS
    _data/topics.yml のネタを1本消化して記事を生成し、検証・push・PR作成まで行う。
.DESCRIPTION
    処理順: (1) topics.ymlからstatus: queuedの先頭ネタを選ぶ (2) draft/YYYY-MM-DD-<slug>ブランチを作成
    (3) prompts/article-generation.mdを土台にプロンプトを組み立て、claude -pで記事Markdownを生成
    (4) scripts/validate-article.ps1で検証 (5) 検証通過時のみtopics.ymlのstatusをusedへ更新し、
    コミット・push・gh pr create。
    gh CLIが未導入の場合は、pushまで行いPR作成手順を案内して終了する。
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
# 日本語プロンプトをコマンドライン引数で渡すと、claudeが「ご依頼の内容が読み取れませんでした」と応答して生成に失敗した（実測）。
# 標準入力で渡すと日本語が往復することを確認したため、パイプ渡しに統一する。$OutputEncodingは標準入力へ書き出す文字コード、
# [Console]::OutputEncodingは標準出力を解釈する文字コードで、日本語の往復には両方の固定が要る。
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
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

function Remove-WrappingCodeFence {
    # claude -pの出力が```で丸ごと包まれることがある（実測: 2026-08-20のスケジューラ実行でoutput全体が
    # ```markdown フェンスに包まれ、front matter判定が不合格になった）。フェンス行と先頭空白以外のバイトは
    # 変更しない（行の分割・再結合をしないため改行コードは変わらず、validate-article.ps1の文字数カウントに
    # 影響しない）。前置き文（「記事は以下です」等）は対象外とし、除去しない（未実測パターンへの推測的な
    # 除去は本文誤削のリスクがあるため、サニティ不合格からのリトライに委ねる）。
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return [PSCustomObject]@{ Text = $Text; FenceRemoved = $false }
    }
    # 先頭の空白・空行を除去する（front matterがテキスト先頭バイトから始まることを保証する）。
    $trimmed = $Text -replace '^\s+', ''
    # 先頭の非空行が```言語名または```単独行なら、その行を除去する。
    $leadingFence = [regex]::Match($trimmed, '^```[^\r\n]*\r?\n')
    if (-not $leadingFence.Success) {
        return [PSCustomObject]@{ Text = $trimmed; FenceRemoved = $false }
    }
    $withoutLeadingFence = $trimmed.Substring($leadingFence.Length)
    # 先頭フェンスを除去した場合に限り、末尾の```単独行（+後続空白）を除去する
    # （記事本文が正当にコードブロックで終わるケースを誤って削らないためのガード）。
    $trailingFence = [regex]::Match($withoutLeadingFence, '\r?\n```[ \t]*\s*\z')
    if ($trailingFence.Success) {
        $withoutLeadingFence = $withoutLeadingFence.Substring(0, $trailingFence.Index)
    }
    return [PSCustomObject]@{ Text = $withoutLeadingFence; FenceRemoved = $true }
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
# ```を含む文は二重引用符付きヒアストリング（$fullPrompt側）の中で直接書くとバッククォート（PowerShellの
# エスケープ文字）として解釈されてしまうため、バッククォートを処理しない単一引用符の文字列として先に組み立てる。
$fenceWarning = '出力全体をコードフェンス（```）で囲まないこと。1行目は --- で始めること。'
$fullPrompt = @"
$promptTemplate

## 今回のテーマ
- タイトル案: $($selectedTopic.Title)
- 出典: $($selectedTopic.SourceRef)

## 既存記事一覧（内部リンク候補）
$existingPostsList

## 出力ファイル名（参考情報。ファイルはこのスクリプトが作成する）
_posts/$postFileName

## 出力方法（厳守）
ファイルの作成・編集ツールは一切使わないこと。記事Markdownの中身だけを、そのまま応答本文として出力すること。
$fenceWarning
"@

# 5〜6. Claude Code CLI呼び出し（記事Markdown本体のみを標準出力させる）→ 正規化 → 機械検証、を最大3試行
# （初回＋リトライ2回）まで繰り返す。本文文字数はLLMが数えられないため一発生成では確率的に下限割れしうる
# （実測: 2026-08-20のスケジューラ実行で2,268字・2,499字が不合格）。失敗は2系統に分ける。
#   - 環境起因（終了コード非0・空出力）: 認証失効等は再試行しても直らないため、即座に例外にする
#   - 生成品質起因（正規化後もfront matter開始でない／validate不合格）: 次の試行へ進み、不合格理由を
#     プロンプト末尾へ付加してフィードバックする
# BOM付きUTF-8で書き出すとJekyllのfront matter判定（先頭が---か）に失敗し記事が公開されない場合があるため、
# BOMなしUTF-8で明示的に書き出す（Out-File -Encoding UTF8はWindows PowerShell 5.1ではBOM付きになる）。
$postPath = Join-Path $repoRoot "_posts/$postFileName"
$maxAttempts = 3
$attemptFeedback = $null
$attemptFailures = New-Object System.Collections.Generic.List[string]
$validateSucceeded = $false

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Host "記事生成 試行 $attempt/$maxAttempts"

    $attemptPrompt = $fullPrompt
    if ($attemptFeedback) {
        $attemptPrompt = @"
$fullPrompt

## 前回出力の不合格理由（今回の出力で必ず解消すること）
$attemptFeedback
"@
    }

    $article = $attemptPrompt | claude -p | Out-String
    $claudeExit = $LASTEXITCODE
    # claude CLIは認証失効等のエラー文を標準出力に返すことがある（実測: OAuth失効時「Failed to authenticate: ...」）。
    # 終了コード非0または空出力は環境起因（再試行しても直らない）とみなし、リトライせず即座に例外にする。
    if ($claudeExit -ne 0 -or [string]::IsNullOrWhiteSpace($article)) {
        $head = if ($article -and $article.Length -gt 120) { $article.Substring(0, 120) } else { $article }
        throw "claude CLIの記事生成に失敗しました（終了コード: $claudeExit / 出力先頭: $head）。環境起因の可能性があります。'claude' を単体で実行して認証状態を確認してください。ブランチ $branch はローカルに残っています。"
    }

    # 出力全体がコードフェンスで包まれることがある（実測: 2026-08-20のスケジューラ実行）ため、
    # front matter開始（---）の判定前に正規化する。
    $normalized = Remove-WrappingCodeFence -Text $article
    if ($normalized.FenceRemoved) {
        Write-Host "出力先頭のコードフェンスを除去しました。"
    }

    if ($normalized.Text -notmatch '^---') {
        $head = if ($normalized.Text.Length -gt 120) { $normalized.Text.Substring(0, 120) } else { $normalized.Text }
        $reason = "出力がfront matterの開始（---）で始まっていません（出力先頭: $head）。認証エラーではありません（形式ゆらぎ）。"
        Write-Host "[試行 $attempt/$maxAttempts 不合格] $reason"
        $attemptFailures.Add("試行 ${attempt}/${maxAttempts}: $reason")
        $attemptFeedback = '出力の1行目が --- で始まっていませんでした。出力全体をコードフェンス（```）で囲まず、1行目を --- にしてください。'
        continue
    }

    [System.IO.File]::WriteAllText($postPath, $normalized.Text, (New-Object System.Text.UTF8Encoding($false)))

    # 機械検証。Write-HostはWindows PowerShell 5.1では情報ストリーム(6)へ出力されるため6>&1で捕捉し、
    # ログへの記録を維持するため捕捉後にWrite-Hostで再出力する。
    $validateOutput = & (Join-Path $repoRoot 'scripts/validate-article.ps1') -Path $postPath 6>&1
    $validateExit = $LASTEXITCODE
    foreach ($line in $validateOutput) {
        Write-Host $line
    }

    if ($validateExit -eq 0) {
        $validateSucceeded = $true
        break
    }

    $reason = "validate-article.ps1が不合格でした（生成品質起因。認証エラーではありません）。"
    Write-Host "[試行 $attempt/$maxAttempts 不合格] $reason"
    $attemptFailures.Add("試行 ${attempt}/${maxAttempts}: $reason")
    $attemptFeedback = ($validateOutput | Out-String).Trim()
}

if (-not $validateSucceeded) {
    Write-Host "$maxAttempts 回の試行すべてで検証に通りませんでした。push/PR作成を中止します。"
    foreach ($f in $attemptFailures) {
        Write-Host "  - $f"
    }
    if (Test-Path $postPath) {
        Write-Host "ブランチ $branch とファイル $postPath はローカルに残しています。"
    } else {
        Write-Host "ブランチ $branch はローカルに残っていますが、記事ファイルは作成されていません（全試行が出力形式の不合格でした）。"
    }
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
