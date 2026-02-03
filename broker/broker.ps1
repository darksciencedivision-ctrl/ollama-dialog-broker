# C:\ai_control\R1_DIALOG\broker.ps1
# STABLE AUTOPILOT DIALOG BROKER (8-hour friendly)
#
# Features:
# - Two models alternate turns: Builder (A) then Challenger (B)
# - Autopilot topic rotation (no human input required)
# - Rolling summary anchor to prevent drift + repetition
# - Turn numbers in logs
# - Latency per Ollama call logged
# - Pacing delay between turns
# - Manual topic override via inbox\topic.txt (resets conversation)
# - Live steering via inbox\interject.txt (no reset)
# - "Too-short output" guardrail + one retry (prevents "Turn X." spam)
# - STOP file ends the broker
#
# Logs:
# - logs\dialog.txt  : conversation lines with turn + latency
# - logs\system.txt  : system + errors + rotation events

param(
  [string]$Root = "C:\ai_control\R1_DIALOG",
  [string]$OllamaBaseUrl = "http://127.0.0.1:11434",

  # Models (must match 'ollama list' names)
  [string]$ModelA = "qwen2.5:14b-instruct",     # Builder
  [string]$ModelB = "dolphin-llama3:latest",    # Challenger (replace with exact name from ollama list if needed)

  # Autopilot
  [bool]$Autopilot = $true,
  [int]$TopicRotateEveryTurns = 30,   # rotate topic after this many turns (0 disables)
  [int]$SummaryEveryTurns = 10,       # refresh anchor summary every N turns (0 disables)

  # Pacing / streaming feel
  [int]$TurnDelayMs = 2000,           # pause after each turn (watchable + cooler GPU)
  [int]$PollMs = 250,

  # Output limits
  [int]$MaxTurnChars = 1700,
  [int]$MaxTurnLines = 12,

  # Ollama generation controls
  [int]$NumPredict = 240,
  [double]$Temperature = 0.55,
  [double]$TopP = 0.9,
  [int]$HttpTimeoutSec = 900,

  # Error behavior
  [int]$ErrorSleepMs = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Paths
$Inbox         = Join-Path $Root "inbox"
$Logs          = Join-Path $Root "logs"
$TopicFile     = Join-Path $Inbox "topic.txt"
$InterjectFile = Join-Path $Inbox "interject.txt"
$DialogFile    = Join-Path $Logs  "dialog.txt"
$SystemFile    = Join-Path $Logs  "system.txt"
$StopFile      = Join-Path $Root  "STOP"

# Ensure dirs/files
foreach ($p in @($Inbox, $Logs)) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
foreach ($f in @($DialogFile, $SystemFile)) {
  if (-not (Test-Path -LiteralPath $f)) { New-Item -ItemType File -Force -Path $f | Out-Null }
}

function AppendUtf8NoBom([string]$path, [string]$line) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($path, $line + "`r`n", $enc)
}

function Log-System([string]$msg) {
  $ts = Get-Date -Format "s"
  AppendUtf8NoBom $SystemFile ("[SYSTEM] " + $ts + " " + $msg)
}

function NormalizeNL([string]$s) {
  if ($null -eq $s) { return "" }
  return ($s -replace "(\r\n|\n|\r)+","`n").Trim()
}

function TruncateTurn([string]$s) {
  $s = NormalizeNL $s
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }

  if ($s.Length -gt $MaxTurnChars) {
    $s = $s.Substring(0, $MaxTurnChars) + "`n...(truncated)"
  }

  $lines = $s -split "`n"
  if ($lines.Count -gt $MaxTurnLines) {
    $keep = $lines[0..($MaxTurnLines-1)] -join "`n"
    $s = $keep + "`n...(truncated)"
  }

  while ($s -match "`n`n`n") { $s = $s -replace "`n`n`n", "`n`n" }
  return $s.Trim()
}

function ReadTextIfExists([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim() } catch { return "" }
}

function ReadAndClear([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  try {
    $txt = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $txt
  } catch { return "" }
}

function Invoke-Ollama([string]$Model, [string]$Prompt) {
  $uri = ($OllamaBaseUrl.TrimEnd("/") + "/api/generate")
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Prompt is empty" }

  # Defensive prompt cap
  if ($Prompt.Length -gt 9000) { $Prompt = $Prompt.Substring(0, 9000) }

  $payload = @{
    model  = $Model
    prompt = $Prompt
    stream = $false
    options = @{
      num_predict = $NumPredict
      temperature = $Temperature
      top_p = $TopP
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $payload -ContentType "application/json" -TimeoutSec $HttpTimeoutSec
    $sw.Stop()
    return @([string]$resp.response, [int]$sw.ElapsedMilliseconds)
  } catch {
    $sw.Stop()
    Log-System ("HTTP error calling Ollama (" + $Model + "): " + $_.Exception.Message)
    throw
  }
}

function Write-Dialog([string]$speaker, [int]$turn, [int]$latMs, [string]$text) {
  $t = TruncateTurn $text
  $line = "[" + $speaker + " T" + $turn.ToString("0000") + " " + $latMs + "ms] " + (NormalizeNL $t)
  AppendUtf8NoBom $DialogFile $line
}

# Guardrail: detect "Turn X." cop-out or ultra-short replies
function Is-TooShort([string]$text, [int]$turn) {
  $t = NormalizeNL $text
  if ([string]::IsNullOrWhiteSpace($t)) { return $true }

  $lines = $t.Split("`n")
  $nonEmpty = ($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

  # if it only returned 1-2 lines, it's basically refusing to participate
  if ($nonEmpty -lt 6) { return $true }

  $first = $lines[0].Trim()
  if ($first -eq ("Turn " + $turn + ".")) {
    # must have at least 5 additional content lines
    if ($nonEmpty -lt 6) { return $true }
  }

  # also reject extremely short overall text
  if ($t.Length -lt 120) { return $true }

  return $false
}

# ---------- Autopilot Topic Selection ----------
function ProposeTopics([string]$seed) {
  $p = New-Object System.Collections.Generic.List[string]
  $p.Add("You are selecting discussion topics for a live stream.")
  $p.Add("Return EXACTLY 3 topic options, one per line, numbered 1-3.")
  $p.Add("Tone: stoic, dry humor, no emojis, no memes.")
  $p.Add("Topics must be safe for general YouTube and non-instructional.")
  $p.Add("Allowed domains: philosophy, AI futures, science, ethics, human condition, engineering, creativity.")
  $p.Add("Avoid: self-harm, illegal instructions, hate, pornography.")
  $p.Add("")
  if (-not [string]::IsNullOrWhiteSpace($seed)) {
    $p.Add("Seed / last theme: " + $seed)
  } else {
    $p.Add("Seed / last theme: (none)")
  }
  $p.Add("")
  $p.Add("Now output the 3 topics:")

  $out = Invoke-Ollama -Model $ModelA -Prompt ($p -join "`n")
  $raw = TruncateTurn $out[0]
  Log-System ("Topic options proposed (A) lat=" + $out[1] + "ms")
  return $raw
}

function ChooseTopic([string]$optionsText) {
  $p = New-Object System.Collections.Generic.List[string]
  $p.Add("Pick the single best topic from the 3 options.")
  $p.Add("Return ONLY the chosen topic text. No numbering. No extra lines.")
  $p.Add("Tone: stoic, dry humor, no emojis, no memes.")
  $p.Add("")
  $p.Add("Options:")
  $p.Add($optionsText)
  $p.Add("")
  $p.Add("Chosen topic:")

  $out = Invoke-Ollama -Model $ModelB -Prompt ($p -join "`n")
  $chosen = TruncateTurn $out[0]
  Log-System ("Topic chosen (B) lat=" + $out[1] + "ms")

  $first = (NormalizeNL $chosen).Split("`n")[0].Trim()
  return $first
}

function RefreshTopic([string]$seed) {
  try {
    $opts = ProposeTopics $seed
    $t = ChooseTopic $opts
    if ([string]::IsNullOrWhiteSpace($t)) { throw "Empty chosen topic" }
    return $t
  } catch {
    $fallback = @(
      "What does it mean for intelligence to be 'useful' rather than 'true'?",
      "How do humans change when AI becomes a daily cognitive prosthetic?",
      "Can meaning be defined operationally without killing it?",
      "What would a 'good' post-human future actually optimize?",
      "How should systems trade freedom vs. coordination under constraints?"
    )
    $r = Get-Random -Minimum 0 -Maximum $fallback.Count
    return $fallback[$r]
  }
}

# ---------- Prompt Builders (hard format to prevent 'Turn X.' spam) ----------
function BuildPromptA([int]$turn, [string]$topic, [string]$anchor, [string]$lastB, [string]$interject) {
  $p = New-Object System.Collections.Generic.List[string]
  $p.Add("You are Builder (A). Address Challenger (B) directly.")
  $p.Add("Tone: stoic, dry humor. No emojis. No memes.")
  $p.Add("Hard format rules:")
  $p.Add("1) Line 1 must be exactly: Turn $turn.")
  $p.Add("2) Then write 6 to 10 additional lines of actual content.")
  $p.Add("3) No blank lines. No headings. No bullets.")
  $p.Add("4) Each content line must be 1 sentence max.")
  $p.Add("5) Do NOT stop after the Turn line.")
  $p.Add("")
  $p.Add("TOPIC: " + $topic)

  if (-not [string]::IsNullOrWhiteSpace($anchor)) {
    $p.Add("ANCHOR (continue from this):")
    $p.Add($anchor)
  }
  if (-not [string]::IsNullOrWhiteSpace($lastB)) {
    $p.Add("B LAST:")
    $p.Add($lastB)
  }
  if (-not [string]::IsNullOrWhiteSpace($interject)) {
    $p.Add("OPERATOR INTERJECTION (answer first in 2 lines):")
    $p.Add($interject)
  }

  $p.Add("")
  $p.Add("Now write A's next turn. Speak to B, not the audience.")
  return ($p -join "`n")
}

function BuildPromptB([int]$turn, [string]$topic, [string]$anchor, [string]$lastA, [string]$interject) {
  $p = New-Object System.Collections.Generic.List[string]
  $p.Add("You are Challenger (B). Address Builder (A) directly.")
  $p.Add("Tone: stoic, dry humor. No emojis. No memes.")
  $p.Add("Hard format rules:")
  $p.Add("1) Line 1 must be exactly: Turn $turn.")
  $p.Add("2) Then write 6 to 10 additional lines of actual content.")
  $p.Add("3) No blank lines. No headings. No bullets.")
  $p.Add("4) Each content line must be 1 sentence max.")
  $p.Add("5) Do NOT stop after the Turn line.")
  $p.Add("Content requirements:")
  $p.Add("- Include exactly one critique, and exactly one test/constraint.")
  $p.Add("")
  $p.Add("TOPIC: " + $topic)

  if (-not [string]::IsNullOrWhiteSpace($anchor)) {
    $p.Add("ANCHOR (continue from this):")
    $p.Add($anchor)
  }
  if (-not [string]::IsNullOrWhiteSpace($lastA)) {
    $p.Add("A LAST:")
    $p.Add($lastA)
  }
  if (-not [string]::IsNullOrWhiteSpace($interject)) {
    $p.Add("OPERATOR INTERJECTION (answer first in 2 lines):")
    $p.Add($interject)
  }

  $p.Add("")
  $p.Add("Now write B's reply. Speak to A, not the audience.")
  return ($p -join "`n")
}

function BuildAnchorSummary([string]$topic, [string]$lastA, [string]$lastB, [string]$priorAnchor) {
  $p = New-Object System.Collections.Generic.List[string]
  $p.Add("Create a compact continuity anchor for an ongoing live debate.")
  $p.Add("Return 5-8 short lines. No blank lines. No headings. No bullets.")
  $p.Add("Keep it factual to what was actually said. No invention.")
  $p.Add("Tone: stoic and minimal.")
  $p.Add("")
  $p.Add("TOPIC: " + $topic)

  if (-not [string]::IsNullOrWhiteSpace($priorAnchor)) {
    $p.Add("PRIOR ANCHOR:")
    $p.Add($priorAnchor)
  }
  if (-not [string]::IsNullOrWhiteSpace($lastA)) {
    $p.Add("A LAST:")
    $p.Add($lastA)
  }
  if (-not [string]::IsNullOrWhiteSpace($lastB)) {
    $p.Add("B LAST:")
    $p.Add($lastB)
  }

  $p.Add("")
  $p.Add("New anchor summary:")

  $out = Invoke-Ollama -Model $ModelA -Prompt ($p -join "`n")
  Log-System ("Anchor summary generated (A) lat=" + $out[1] + "ms")
  return (TruncateTurn $out[0])
}

# ---------- Startup ----------
Write-Host "[BROKER] Stable Autopilot broker running."
Write-Host "[BROKER] Autopilot: $Autopilot"
Write-Host "[BROKER] A (Builder): $ModelA"
Write-Host "[BROKER] B (Challenger): $ModelB"
Write-Host "[BROKER] Topic file: $TopicFile"
Write-Host "[BROKER] Interject file: $InterjectFile"
Write-Host "[BROKER] Dialog log: $DialogFile"
Write-Host "[BROKER] System log: $SystemFile"
Write-Host "[BROKER] Stop: create file $StopFile"

Log-System "Broker start"
Log-System ("Autopilot=" + $Autopilot)
Log-System ("A=" + $ModelA + " B=" + $ModelB)

[int]$turn = 0
[string]$topic = ""
[string]$anchor = ""
[string]$lastA = ""
[string]$lastB = ""
[string]$next = "A"
[string]$topicHash = ""

# Autopilot seed topic
if ($Autopilot -and [string]::IsNullOrWhiteSpace($topic)) {
  $topic = RefreshTopic ""
  $anchor = ""
  $lastA = ""
  $lastB = ""
  $next = "A"
  $turn = 0
  Log-System ("Autopilot initial topic: " + $topic)
  AppendUtf8NoBom $DialogFile ("[SYSTEM] Topic: " + $topic)
}

while ($true) {
  if (Test-Path -LiteralPath $StopFile) {
    Log-System "STOP detected. Exiting."
    break
  }

  # Manual topic override (resets)
  $manual = ReadTextIfExists $TopicFile
  if (-not [string]::IsNullOrWhiteSpace($manual)) {
    $h = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manual))
    if ($h -ne $topicHash) {
      $topicHash = $h
      $topic = $manual
      $anchor = ""
      $lastA = ""
      $lastB = ""
      $next = "A"
      $turn = 0
      Log-System ("Manual topic set: " + $topic)
      AppendUtf8NoBom $DialogFile ("[SYSTEM] Topic: " + $topic)
    }
  }

  # Autopilot topic rotation
  if ($Autopilot -and $TopicRotateEveryTurns -gt 0 -and -not [string]::IsNullOrWhiteSpace($topic)) {
    if ($turn -ge $TopicRotateEveryTurns -and ($turn % $TopicRotateEveryTurns -eq 0) -and $next -eq "A") {
      $old = $topic
      $topic = RefreshTopic $old
      $anchor = ""
      $lastA = ""
      $lastB = ""
      $next = "A"
      $turn = 0
      Log-System ("Topic rotated: " + $topic)
      AppendUtf8NoBom $DialogFile ("[SYSTEM] Topic: " + $topic)
    }
  }

  if ([string]::IsNullOrWhiteSpace($topic)) {
    if ($Autopilot) {
      $topic = RefreshTopic ""
      Log-System ("Autopilot topic (reseed): " + $topic)
      AppendUtf8NoBom $DialogFile ("[SYSTEM] Topic: " + $topic)
      $turn = 0
      $next = "A"
    } else {
      Start-Sleep -Milliseconds $PollMs
      continue
    }
  }

  # One-shot interjection
  $interject = ReadAndClear $InterjectFile
  if (-not [string]::IsNullOrWhiteSpace($interject)) {
    Log-System ("Interject received: " + (NormalizeNL $interject))
  }

  try {
    $turn++

    if ($next -eq "A") {
      $prompt = BuildPromptA -turn $turn -topic $topic -anchor $anchor -lastB $lastB -interject $interject
      $res = Invoke-Ollama -Model $ModelA -Prompt $prompt
      $text = TruncateTurn $res[0]
      $lat  = [int]$res[1]

      # One retry if model returns the Turn label or too little content
      if (Is-TooShort -text $text -turn $turn) {
        Log-System ("A output too short at turn " + $turn + ", retrying once.")
        $prompt2 = $prompt + "`n`nYou returned only the Turn label or too little content. Re-emit the turn with 6-10 content lines."
        $res2 = Invoke-Ollama -Model $ModelA -Prompt $prompt2
        $text = TruncateTurn $res2[0]
        $lat  = [int]$res2[1]
      }

      $lastA = $text
      Write-Dialog -speaker "A" -turn $turn -latMs $lat -text $text
      Log-System ("A turn=" + $turn + " lat=" + $lat + "ms")
      $next = "B"
    }
    else {
      $prompt = BuildPromptB -turn $turn -topic $topic -anchor $anchor -lastA $lastA -interject $interject
      $res = Invoke-Ollama -Model $ModelB -Prompt $prompt
      $text = TruncateTurn $res[0]
      $lat  = [int]$res[1]

      if (Is-TooShort -text $text -turn $turn) {
        Log-System ("B output too short at turn " + $turn + ", retrying once.")
        $prompt2 = $prompt + "`n`nYou returned only the Turn label or too little content. Re-emit the turn with 6-10 content lines."
        $res2 = Invoke-Ollama -Model $ModelB -Prompt $prompt2
        $text = TruncateTurn $res2[0]
        $lat  = [int]$res2[1]
      }

      $lastB = $text
      Write-Dialog -speaker "B" -turn $turn -latMs $lat -text $text
      Log-System ("B turn=" + $turn + " lat=" + $lat + "ms")
      $next = "A"
    }

    # Rolling anchor refresh
    if ($SummaryEveryTurns -gt 0 -and ($turn % $SummaryEveryTurns -eq 0) -and $next -eq "A") {
      $anchor = BuildAnchorSummary -topic $topic -lastA $lastA -lastB $lastB -priorAnchor $anchor
      Log-System ("Anchor refreshed at turn " + $turn)
      AppendUtf8NoBom $DialogFile ("[SYSTEM] Anchor: " + (NormalizeNL $anchor))
    }

  } catch {
    Log-System ("Error: " + $_.Exception.Message)
    Start-Sleep -Milliseconds $ErrorSleepMs
  }

  Start-Sleep -Milliseconds $TurnDelayMs
}

Log-System "Broker exit"
