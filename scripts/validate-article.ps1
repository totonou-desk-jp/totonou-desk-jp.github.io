<#
.SYNOPSIS
    整うデスクブログの記事Markdownを機械検証する。
.DESCRIPTION
    front matter必須キー・本文の文字数範囲・禁止語（実体験偽装・断定的な煽り表現）・
    価格表記時の変動注記・affiliate.htmlインクルードのid形式・本文中の生URL直書きの禁止を検査する。
    ローカル実行（generate-article.ps1 / revise-article.ps1からの呼び出し）と、
    GitHub Actions（.github/workflows/validate.yml、pwshで同一スクリプトを実行）の両方から
    共通の検証ロジックとして呼び出す。
    禁止語リスト等の判定基準はこのスクリプト内に独立して保持し、
    prompts/article-generation.md（生成プロンプト）側の記述は参照しない（検査の自己参照化防止）。
.PARAMETER Path
    検証対象のMarkdownファイルパス（複数可）。省略時は _posts 配下の全記事を検証する。
.EXAMPLE
    pwsh -File scripts/validate-article.ps1
.EXAMPLE
    pwsh -File scripts/validate-article.ps1 -Path _posts/2026-08-20-desk-no-fixed-place.md
#>
[CmdletBinding()]
param(
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$postsDir = Join-Path $repoRoot '_posts'

if (-not $Path -or $Path.Count -eq 0) {
    if (-not (Test-Path $postsDir)) {
        Write-Host "検証対象の _posts ディレクトリが見つかりません: $postsDir"
        exit 0
    }
    $Path = Get-ChildItem -Path $postsDir -Filter '*.md' | ForEach-Object { $_.FullName }
}

if ($Path.Count -eq 0) {
    Write-Host "検証対象の記事がありません。"
    exit 0
}

# 実体験偽装・断定的な煽り表現の禁止語リスト（本スクリプト固有。prompts/側の記述とは独立に保持する）
$bannedPhrases = @(
    '私が使ってみた',
    '私も使っています',
    '実際に使ってみたところ',
    '使ってみた感想',
    '愛用しています',
    '個人的におすすめ',
    '絶対に',
    '一番人気',
    'No.1',
    'ナンバーワン'
)

$requiredFrontMatterKeys = @('title', 'description', 'date', 'affiliate')
$minChars = 2500
$maxChars = 4000
$filenamePattern = '^\d{4}-\d{2}-\d{2}-[a-z0-9]+(-[a-z0-9]+)*\.md$'
$pricePattern = '(¥[0-9,]+|[0-9,]+円)'
$priceDisclaimerPattern = '変動'
$rawUrlPattern = 'https?://'
$affiliateIncludePattern = '\{%\s*include\s+affiliate\.html\s+id="([^"]*)"\s*%\}'
$affiliateIdFormatPattern = '^[a-z0-9]+(-[a-z0-9]+)*$'

$hasError = $false

foreach ($file in $Path) {
    $fileName = Split-Path -Leaf $file
    $fileErrors = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path $file)) {
        $fileErrors.Add("ファイルが存在しません。")
    } else {
        $raw = Get-Content -Path $file -Raw -Encoding UTF8

        if ($fileName -notmatch $filenamePattern) {
            $fileErrors.Add("ファイル名が日付付きスラッグ形式（YYYY-MM-DD-slug.md）ではありません。")
        }

        $fmMatch = [regex]::Match($raw, '^---\r?\n(.*?)\r?\n---\r?\n(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $fmMatch.Success) {
            $fileErrors.Add("front matter（--- で囲まれたヘッダー）が見つかりません。")
            $frontMatter = ''
            $body = $raw
        } else {
            $frontMatter = $fmMatch.Groups[1].Value
            $body = $fmMatch.Groups[2].Value
        }

        foreach ($key in $requiredFrontMatterKeys) {
            if ($frontMatter -notmatch "(?m)^$key\s*:") {
                $fileErrors.Add("front matterに必須キー '$key' がありません。")
            }
        }

        $bodyLength = $body.Length
        if ($bodyLength -lt $minChars -or $bodyLength -gt $maxChars) {
            $fileErrors.Add("本文の文字数が範囲外です（$bodyLength 字。$minChars〜$maxChars 字を想定）。")
        }

        foreach ($phrase in $bannedPhrases) {
            if ($body.Contains($phrase)) {
                $fileErrors.Add("禁止語が含まれています: '$phrase'")
            }
        }

        if ($body -match $pricePattern -and $body -notmatch $priceDisclaimerPattern) {
            $fileErrors.Add("価格表記がありますが、変動に関する注記が見つかりません。")
        }

        $urlMatches = [regex]::Matches($body, $rawUrlPattern)
        if ($urlMatches.Count -gt 0) {
            $fileErrors.Add("本文に生URLが直書きされています（$($urlMatches.Count)件）。affiliate.htmlのid参照またはpost_urlタグを使用してください。")
        }

        $affMatches = [regex]::Matches($body, $affiliateIncludePattern)
        foreach ($m in $affMatches) {
            $id = $m.Groups[1].Value
            if ($id -eq '' -or $id -notmatch $affiliateIdFormatPattern) {
                $fileErrors.Add("affiliate.htmlのid形式が不正です: '$id'")
            }
        }
    }

    if ($fileErrors.Count -gt 0) {
        $hasError = $true
        Write-Host "[NG] $fileName"
        foreach ($e in $fileErrors) {
            Write-Host "  - $e"
        }
    } else {
        Write-Host "[OK] $fileName"
    }
}

if ($hasError) {
    exit 1
} else {
    exit 0
}
