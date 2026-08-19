<#
.SYNOPSIS
    「整うデスク」記事の週次自動生成をWindowsタスクスケジューラに登録する。
.DESCRIPTION
    毎週日曜21:00に scripts/generate-article.ps1 を実行するタスクを登録する。
    PCの電源が入っていない等でスケジュールされた時刻に実行できなかった場合は、
    StartWhenAvailable設定（タスクスケジューラの「スケジュールされた開始を逃した場合はすぐにタスクを開始する」）により、
    次回PC起動時に実行される。
    実行には gh CLI のインストールと認証（gh auth login）が完了している必要がある（段階0のユーザー作業）。
.PARAMETER TaskName
    登録するタスク名。省略時は既定値を使う。
.EXAMPLE
    powershell -File .\scripts\register-scheduled-task.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'TotonouDesk-WeeklyArticleGeneration'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts/generate-article.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "generate-article.ps1 が見つかりません: $scriptPath"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
    -WorkingDirectory $repoRoot

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 21:00

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description '整うデスク: 週次記事生成（scripts/generate-article.ps1）' -Force | Out-Null

Write-Host "タスク '$TaskName' を登録しました（毎週日曜21:00開始）。"
Write-Host "PCの電源が入っていない場合は、次回起動時にStartWhenAvailable設定で実行されます。"
Write-Host "登録内容の確認・削除は、タスクスケジューラ（taskschd.msc）または以下のコマンドで行えます。"
Write-Host "  確認: Get-ScheduledTask -TaskName '$TaskName'"
Write-Host "  削除: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
