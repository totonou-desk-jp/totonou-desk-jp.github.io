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

function Remove-WrappingCodeFence {
    # claude -pの出力が```で丸ごと包まれることがある（generate-article.ps1と同じ形式ゆらぎ。
    # 実測: 2026-08-20のスケジューラ実行でoutput全体が```markdownフェンスに包まれ、front matter判定が
    # 不合格になった）。フェンス行と先頭空白以外のバイトは変更しない（行の分割・再結合をしないため改行コード
    # は変わらず、validate-article.ps1の文字数カウントに影響しない）。前置き文（「記事は以下です」等）は
    # 対象外とし、除去しない（未実測パターンへの推測的な除去は本文誤削のリスクがあるため、サニティ不合格を
    # そのままエラーにすることに委ねる）。generate-article.ps1と同一ロジックを複製したもの。
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
# ```を含む文は二重引用符付きヒアストリング（$revisePrompt側）の中で直接書くとバッククォート（PowerShellの
# エスケープ文字）として解釈されてしまうため、バッククォートを処理しない単一引用符の文字列として先に組み立てる。
$fenceWarning = '出力全体をコードフェンス（```）で囲まないこと。1行目は --- で始めること。'
$revisePrompt = @"
以下の記事を、次の修正指示に従って書き直してください。
front matterの構造・全体の文体は維持し、指摘箇所のみ修正した完全なMarkdownを出力してください（説明文は不要です）。
$fenceWarning

## 修正指示（PRコメント）
$comments

## 現在の記事
$currentArticle
"@

# 4. Claude Code CLI呼び出し
$revisedArticle = $revisePrompt | claude -p | Out-String
$claudeExit = $LASTEXITCODE
# claude CLIは認証失効等のエラー文を標準出力に返すことがある。終了コード非0または空出力は環境起因
# （認証失効等）とみなし、認証状態の確認を促すメッセージにする。
if ($claudeExit -ne 0 -or [string]::IsNullOrWhiteSpace($revisedArticle)) {
    $head = if ($revisedArticle -and $revisedArticle.Length -gt 120) { $revisedArticle.Substring(0, 120) } else { $revisedArticle }
    throw "claude CLIの修正稿生成に失敗しました（終了コード: $claudeExit / 出力先頭: $head）。環境起因の可能性があります。'claude' を単体で実行して認証状態を確認してください。記事ファイルは上書きしていません。"
}

# 出力全体がコードフェンスで包まれることがある（generate-article.ps1と同じ形式ゆらぎ）ため、
# front matter開始（---）の判定前に正規化する。revise-article.ps1は手動実行のためリトライは行わず、
# 正規化後も不合格ならエラーにする（人がその場で再実行できるため）。
$normalized = Remove-WrappingCodeFence -Text $revisedArticle
if ($normalized.FenceRemoved) {
    Write-Host "出力先頭のコードフェンスを除去しました。"
}
# エラー文で既存記事を上書きしないよう、front matter開始（---）を確認してから書き出す。
if ($normalized.Text -notmatch '^---') {
    $head = if ($normalized.Text.Length -gt 120) { $normalized.Text.Substring(0, 120) } else { $normalized.Text }
    throw "claude CLIの修正稿がfront matterの開始（---）で始まっていません（出力先頭: $head）。認証エラーではありません（形式ゆらぎ）。記事ファイルは上書きしていません。"
}
# BOM付きUTF-8で書き出すとJekyllのfront matter判定（先頭が---か）に失敗する場合があるため、
# BOMなしUTF-8で明示的に書き出す（Out-File -Encoding UTF8はWindows PowerShell 5.1ではBOM付きになる）。
[System.IO.File]::WriteAllText($targetPath, $normalized.Text, (New-Object System.Text.UTF8Encoding($false)))

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
