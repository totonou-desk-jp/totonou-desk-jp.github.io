<#
.SYNOPSIS
    PRのレビューコメントを取り込み、対象記事を修正して同じブランチへ追いpushする。
.DESCRIPTION
    gh pr view --json でPRの会話コメント・レビュー本文と変更ファイルを取得し、claude -pに現在の記事本文と
    修正指示を渡して修正稿を生成する。修正後はscripts/validate-article.ps1で再検証し、通過した場合のみ
    コミット・pushする（同じPRへ自動的に反映される）。
.PARAMETER PullRequestNumber
    修正対象のPR番号。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber
)

$ErrorActionPreference = 'Stop'
# 日本語プロンプトをコマンドライン引数で渡すと、claudeが「ご依頼の内容が読み取れませんでした」と応答して生成に失敗した（実測）。
# 標準入力で渡すと日本語が往復することを確認したため、パイプ渡しに統一する。$OutputEncodingは標準入力へ書き出す文字コード、
# [Console]::OutputEncodingは標準出力を解釈する文字コードで、日本語の往復には両方の固定が要る。
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-Git {
    # gitはネイティブコマンドのため$ErrorActionPreference='Stop'では失敗が捕捉されない。
    # $LASTEXITCODEを明示的に検査し、失敗時は例外として上位へ伝える。
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') が失敗しました（終了コード $LASTEXITCODE）。"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghAvailable) {
    Write-Host "gh CLIが見つかりません。'gh auth login' の完了後に再実行してください。"
    exit 1
}

# 1. PR情報取得
# gh pr view --json comments が返すのは会話タブのIssueコメントのみで、レビュー（Approve/Request changes）の
# 本文はreviews側に入るため、両方を取得して結合する。
$prJson = gh pr view $PullRequestNumber --json headRefName,comments,reviews,files | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $prJson) {
    throw "gh pr view に失敗しました（PR #$PullRequestNumber）。PR番号と 'gh auth status' を確認してください。"
}
$branch = $prJson.headRefName
$commentBodies = @($prJson.comments | ForEach-Object { $_.body }) + @($prJson.reviews | ForEach-Object { $_.body })
$comments = ($commentBodies | Where-Object { $_ -and $_.Trim() -ne '' }) -join "`n---`n"

if (-not $comments) {
    Write-Host "PR #$PullRequestNumber に修正指示のコメントが見つかりません。"
    exit 1
}

# 2. 対象記事ファイルの特定（_posts配下の変更ファイルのうち先頭の1件）
$targetFile = $prJson.files | Where-Object { $_.path -like '_posts/*.md' } | Select-Object -First 1 -ExpandProperty path
if (-not $targetFile) {
    Write-Host "PR #$PullRequestNumber に _posts 配下の記事ファイルが見つかりません。"
    exit 1
}

Invoke-Git fetch origin $branch
Invoke-Git checkout $branch
if ((git rev-parse --abbrev-ref HEAD) -ne $branch) {
    throw "PRブランチへの切り替えに失敗しました: $branch"
}
Invoke-Git pull origin $branch

# 3. 修正プロンプト組み立て
$targetPath = Join-Path $repoRoot $targetFile
$currentArticle = Get-Content -Path $targetPath -Raw -Encoding UTF8
$revisePrompt = @"
以下の記事を、次の修正指示に従って書き直してください。
front matterの構造・全体の文体は維持し、指摘箇所のみ修正した完全なMarkdownを出力してください（説明文は不要です）。

## 修正指示（PRコメント）
$comments

## 現在の記事
$currentArticle
"@

# 4. Claude Code CLI呼び出し
# BOM付きUTF-8で書き出すとJekyllのfront matter判定（先頭が---か）に失敗する場合があるため、
# BOMなしUTF-8で明示的に書き出す（Out-File -Encoding UTF8はWindows PowerShell 5.1ではBOM付きになる）。
$revisedArticle = $revisePrompt | claude -p | Out-String
$claudeExit = $LASTEXITCODE
# claude CLIは認証失効等のエラー文を標準出力に返すことがある。
# エラー文で既存記事を上書きしないよう、終了コードとfront matter開始（---）を確認してから書き出す。
if ($claudeExit -ne 0 -or $revisedArticle -notmatch '^\s*---') {
    $head = if ($revisedArticle -and $revisedArticle.Length -gt 120) { $revisedArticle.Substring(0, 120) } else { $revisedArticle }
    throw "claude CLIの修正稿生成に失敗しました（終了コード: $claudeExit / 出力先頭: $head）。'claude' を単体で実行して認証状態を確認してください。記事ファイルは上書きしていません。"
}
[System.IO.File]::WriteAllText($targetPath, $revisedArticle, (New-Object System.Text.UTF8Encoding($false)))

# 5. 機械検証
& (Join-Path $repoRoot 'scripts/validate-article.ps1') -Path $targetPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "validate-article.ps1 が失敗しました。pushを中止します。$targetFile を確認してください。"
    exit 1
}

# 6. コミット・追いpush
Invoke-Git add $targetFile
if (-not (git status --porcelain -- $targetFile)) {
    Write-Host "修正内容に変化がありませんでした。PRコメントの指示内容を確認してください。"
    exit 1
}
Invoke-Git commit -m "fix(posts): PR #$PullRequestNumber のレビュー指摘を反映"
Invoke-Git push origin $branch

Write-Host "PR #$PullRequestNumber のブランチ $branch に修正をpushしました。"
