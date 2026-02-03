# OBS-friendly dialog watcher (NO ANSI CODES)
# Named speakers, colors, timestamps, clean output
# A = Neo (Builder) | B = Clue (Challenger)

param(
  [string]$Root="C:\ai_control\R1_DIALOG",
  [int]$TailLines=300
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$log = Join-Path $Root "logs\dialog.txt"
if (-not (Test-Path $log)) {
  throw "Missing dialog log: $log"
}

$printing = $false
$currentSpeaker = ""
$currentColor = "White"

Write-Host "=== LIVE DIALOG ===" -ForegroundColor DarkGray
Write-Host ""

Get-Content -Path $log -Tail $TailLines -Wait -Encoding UTF8 | ForEach-Object {

  $line = $_
  $ts = (Get-Date -Format "HH:mm:ss")

  # ---- Neo (A) ----
  if ($line.StartsWith("[A T")) {
    Write-Host ""
    Write-Host "[$ts] Neo:" -ForegroundColor Cyan
    $currentSpeaker = "Neo"
    $currentColor = "Cyan"
    $printing = $true
    return
  }

  # ---- Clue (B) ----
  if ($line.StartsWith("[B T")) {
    Write-Host ""
    Write-Host "[$ts] Clue:" -ForegroundColor Green
    $currentSpeaker = "Clue"
    $currentColor = "Green"
    $printing = $true
    return
  }

  # ---- System ----
  if ($line.StartsWith("[SYSTEM]")) {
    Write-Host ""
    Write-Host "[$ts] SYSTEM: $($line.Substring(8))" -ForegroundColor DarkGray
    $printing = $false
    return
  }

  # ---- Content lines ----
  if ($printing) {
    Write-Host $line -ForegroundColor $currentColor
  }
}

