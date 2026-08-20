<#
.SYNOPSIS
    整うデスクブログの記事Markdownを機械検証する。
.DESCRIPTION
    ファイル名の形式・front matter必須キー・本文の文字数範囲・禁止語（実体験偽装・断定的な煽り表現）・
    価格表記時の変動注記・affiliate.htmlインクルードのid形式・本文中の生URL直書きの禁止・
    序数や助数詞としての漢数字使用・絵文字の使用を検査する。
    あわせて、ファイル先頭のBOMの有無と、affiliate.htmlインクルードのidが`_data/affiliates.yml`の
    itemsに存在するかも検査する（存在検査はaffiliates.ymlを直接読み、prompts/側の記述は参照しない）。
    front matterのdateはファイル名の日付との一致と日付としての妥当性を検査し、本文にaffiliate.html
    インクルードがある場合はfront matterのaffiliateがtrueであることも検査する。
    ローカル実行（generate-article.ps1 / revise-article.ps1からの呼び出し）と、
    GitHub Actions（.github/workflows/validate.yml、pwshで同一スクリプトを実行）の両方から
    共通の検証ロジックとして呼び出す。
    禁止語リスト等の判定基準はこのスクリプト内に独立して保持し、
    prompts/article-generation.md（生成プロンプト）側の記述は参照しない（検査の自己参照化防止）。
    漢数字チェックは「一覧」「一時的」のような通常語彙までは誤検知しないよう、
    序数（第一に等）と助数詞（一つ・二人等）のパターンに限定している。網羅的な検出ではない。
.PARAMETER Path
    検証対象のMarkdownファイルパス（複数可）。省略時は _posts 配下の全記事を検証する。
.EXAMPLE
    powershell -File scripts\validate-article.ps1
.EXAMPLE
    powershell -File scripts\validate-article.ps1 -Path _posts\2026-08-20-desk-no-fixed-place.md
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

# 漢数字の序数（第一に等）・助数詞（一つ・二人等）を検出する。「一覧」「一時的」のような
# 数詞以外の通常語彙は対象にならないよう、序数・助数詞の形に限定したパターンにする。
$kanjiNumeralPattern = '第[一二三四五六七八九十百千万]+|[一二三四五六七八九十]+(つ|人|個|回|本|点|枚|台|冊|匹|杯|着|足|割|倍|番目|つ目)'

# 絵文字の主要ブロック（Unicodeコードポイント範囲）。矢印(U+2190台)等の一般記号は
# 通常の文章表現でも使われうるため対象に含めない。網羅的な絵文字検出ではない。
$emojiCodepointRanges = @(
    @{ From = 0x1F300; To = 0x1FAFF },  # 絵文字と記号のメインブロック一式
    @{ From = 0x2600; To = 0x27BF },    # その他の記号・装飾記号（☀✂✈等）
    @{ From = 0x1F1E6; To = 0x1F1FF },  # 地域表示記号（国旗の構成要素）
    @{ From = 0xFE0F; To = 0xFE0F }     # 絵文字表示指定子（VARIATION SELECTOR-16）
)

function Find-EmojiCharacters {
    param([string]$Text)
    $found = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Text.Length) {
        if ([char]::IsSurrogatePair($Text, $i)) {
            $codepoint = [char]::ConvertToUtf32($Text, $i)
            $i += 2
        } else {
            $codepoint = [int][char]$Text[$i]
            $i += 1
        }
        foreach ($range in $emojiCodepointRanges) {
            if ($codepoint -ge $range.From -and $codepoint -le $range.To) {
                $found.Add([char]::ConvertFromUtf32($codepoint))
                break
            }
        }
    }
    return $found
}

# affiliate.htmlインクルードのid存在検査用に、_data/affiliates.ymlのitems配下のキー一覧を直接読み取る
# （汎用YAMLパーサーは使わず、items配下のキー行（2スペースインデント＋コロン終端）のみを拾う軽量パーサー）。
$affiliatesPath = Join-Path $repoRoot '_data/affiliates.yml'
$affiliateItemKeys = @()
if (Test-Path $affiliatesPath) {
    $affiliatesRaw = Get-Content -Path $affiliatesPath -Raw -Encoding UTF8
    $itemsSectionMatch = [regex]::Match($affiliatesRaw, '(?ms)^items:\s*\r?\n(.*)$')
    if ($itemsSectionMatch.Success) {
        $affiliateItemKeys = [regex]::Matches($itemsSectionMatch.Groups[1].Value, '(?m)^  ([a-zA-Z0-9][a-zA-Z0-9_-]*):\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    }
}

$hasError = $false

foreach ($file in $Path) {
    $fileName = Split-Path -Leaf $file
    $fileErrors = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path $file)) {
        $fileErrors.Add("ファイルが存在しません。")
    } else {
        $resolvedFile = (Resolve-Path -LiteralPath $file).ProviderPath
        $bytes = [System.IO.File]::ReadAllBytes($resolvedFile)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $fileErrors.Add("ファイル先頭にBOMがあります。BOMなしUTF-8で保存してください。")
        }

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

        # front matterのdateがファイル名の日付と一致し、かつ日付として妥当かを検査する。
        # dateキー自体が無い場合は上の必須キー検査で既に[NG]になるため、ここでは追加しない。
        $fmDateMatch = [regex]::Match($frontMatter, '(?m)^date\s*:\s*(\S+)')
        if ($fmDateMatch.Success) {
            $fmDateValue = $fmDateMatch.Groups[1].Value.Trim('"', "'")
            $fmDateForCompare = if ($fmDateValue.Length -ge 10) { $fmDateValue.Substring(0, 10) } else { $fmDateValue }
            $fileDate = if ($fileName -match '^(\d{4}-\d{2}-\d{2})-') { $Matches[1] } else { $null }
            if ($fileDate -and $fmDateForCompare -ne $fileDate) {
                $fileErrors.Add("front matterのdateがファイル名の日付と一致しません（ファイル名: $fileDate / front matter: $fmDateForCompare）。")
            }
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($fmDateForCompare, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                $fileErrors.Add("front matterのdateが日付として不正です（$fmDateValue）。YYYY-MM-DD形式で指定してください。")
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
            } elseif ($affiliateItemKeys -notcontains $id) {
                $fileErrors.Add("affiliate.htmlのid '$id' が _data/affiliates.yml の items に存在しません。")
            }
        }

        if ($affMatches.Count -gt 0 -and $frontMatter -notmatch '(?m)^affiliate\s*:\s*true\s*$') {
            $fileErrors.Add("本文にaffiliate.htmlのインクルードがありますが、front matterの affiliate が true ではありません（記事冒頭の広告表記が出ません）。")
        }

        $kanjiMatches = [regex]::Matches($body, $kanjiNumeralPattern)
        if ($kanjiMatches.Count -gt 0) {
            $foundKanji = ($kanjiMatches | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
            $fileErrors.Add("本文に漢数字の序数・助数詞表現が含まれています（算用数字を使用してください）: $foundKanji")
        }

        $emojiFound = Find-EmojiCharacters -Text $body
        if ($emojiFound.Count -gt 0) {
            $uniqueEmoji = ($emojiFound | Select-Object -Unique) -join ', '
            $fileErrors.Add("本文に絵文字が含まれています: $uniqueEmoji")
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
