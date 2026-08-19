<#
.SYNOPSIS
    PRのレビューコメントを取り込み、対象記事を修正して同じブランチへ追いpushする。
.DESCRIPTION
    gh pr view --json でPRのコメントと変更ファイルを取得し、claude -pに現在の記事本文と修正指示を渡して
    修正稿を生成する。修正後はscripts/validate-article.ps1で再検証し、通過した場合のみ
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
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghAvailable) {
    Write-Host "gh CLIが見つかりません。'gh auth login' の完了後に再実行してください。"
    exit 1
}

# 1. PR情報取得
$prJson = gh pr view $PullRequestNumber --json headRefName,comments,files | ConvertFrom-Json
$branch = $prJson.headRefName
$comments = ($prJson.comments | ForEach-Object { $_.body }) -join "`n---`n"

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

git fetch origin $branch
git checkout $branch
git pull origin $branch

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
claude -p $revisePrompt | Out-File -FilePath $targetPath -Encoding UTF8

# 5. 機械検証
& (Join-Path $repoRoot 'scripts/validate-article.ps1') -Path $targetPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "validate-article.ps1 が失敗しました。pushを中止します。$targetFile を確認してください。"
    exit 1
}

# 6. コミット・追いpush
git add $targetFile
git commit -m "fix(posts): PR #$PullRequestNumber のレビュー指摘を反映"
git push origin $branch

Write-Host "PR #$PullRequestNumber のブランチ $branch に修正をpushしました。"
