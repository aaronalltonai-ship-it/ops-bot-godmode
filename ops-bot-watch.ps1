param(
  [int]$IntervalSeconds = 900,
  [int]$MaxTasks = 3,
  [int]$MaxConcurrentAgents = 3,
  [string]$AgentName = "ops-bot",
  [bool]$EnableBackup = $true,
  [int]$BackupMaxTasks = 2,
  [switch]$AllTasks,
  [switch]$LocalQueue,
  [switch]$AutoDone,
  [switch]$Once,
  [switch]$DryRun,
  [switch]$GodMode,
  [switch]$ResetState
)

$ErrorActionPreference = "Stop"

$root = "D:\workspace\ops-bot"
$queueDir = Join-Path $root "queue"
$outDir = Join-Path $root "out"
$outDeliverablesDir = Join-Path $outDir "deliverables"
$outUpdatesDir = Join-Path $outDir "updates"
$outLogsDir = Join-Path $outDir "logs"
$repoRoot = "D:\workspace\notion-api-webhook-repo"
$repoWorkspaceDir = Join-Path $repoRoot "workspace\projects\ops-bot"
$repoDeliverablesDir = Join-Path $repoWorkspaceDir "deliverables"
$repoUpdatesDir = Join-Path $repoWorkspaceDir "updates"
$repoLogsDir = Join-Path $repoWorkspaceDir "logs"
$repoLogsNotionDeliverablesDir = Join-Path $repoLogsDir "notion-deliverables"
$repoQueueDir = Join-Path $repoWorkspaceDir "queue"
$repoStateFile = Join-Path $repoWorkspaceDir "state.json"
$stateFile = Join-Path $root "state.json"
$promptTemplate = Join-Path $root "prompt-template.txt"
$logsDir = "D:\workspace\logs"
$logsNotionDeliverablesDir = Join-Path $logsDir "notion-deliverables"
$appLog = Join-Path $logsDir "app.log"
$deployCsv = Join-Path $logsDir "deployments.csv"
$updatesFile = Join-Path $logsDir "notion-updates.md"

function Ensure-Paths {
  if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
  if (-not (Test-Path $queueDir)) { New-Item -ItemType Directory -Path $queueDir | Out-Null }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
  if (-not (Test-Path $outDeliverablesDir)) { New-Item -ItemType Directory -Path $outDeliverablesDir | Out-Null }
  if (-not (Test-Path $outUpdatesDir)) { New-Item -ItemType Directory -Path $outUpdatesDir | Out-Null }
  if (-not (Test-Path $outLogsDir)) { New-Item -ItemType Directory -Path $outLogsDir | Out-Null }
  if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
  if (-not (Test-Path $logsNotionDeliverablesDir)) { New-Item -ItemType Directory -Path $logsNotionDeliverablesDir | Out-Null }
  if (-not (Test-Path $appLog)) { New-Item -ItemType File -Path $appLog | Out-Null }
  if (-not (Test-Path $deployCsv)) {
    "timestamp,project,taskId,webUrl,railwayUrl,apkPathOrUrl,ipaStatusOrUrl,screenshots,licenseMasked,notes" | Out-File -FilePath $deployCsv -Encoding ascii
  }
  if (-not (Test-Path $updatesFile)) { New-Item -ItemType File -Path $updatesFile | Out-Null }
  if (-not (Test-Path $promptTemplate)) { throw "Missing prompt template: $promptTemplate" }
  # optional repo mirror structure
  if (Test-Path $repoRoot) {
    foreach ($p in @($repoWorkspaceDir,$repoDeliverablesDir,$repoUpdatesDir,$repoLogsDir,$repoLogsNotionDeliverablesDir,$repoQueueDir)) {
      if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    }
  }
}

function Read-EnvFile {
  param([string]$path)
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  Get-Content $path | Where-Object { $_ -notmatch '^\s*$|^#' } | ForEach-Object {
    $parts = $_ -split '=', 2
    if ($parts.Length -eq 2) { $map[$parts[0].Trim()] = $parts[1].Trim() }
  }
  return $map
}

function Get-NotionConfig {
  $envLocal = Read-EnvFile "D:\online-store\.env.local"
  if (-not $envLocal.Count) { $envLocal = Read-EnvFile "D:\online-store\.env" }
  $token = $envLocal["NOTION_TOKEN"]
  $dbId = $envLocal["NOTION_DATABASE_TASKS"]
  if (-not $token) { throw "Missing NOTION_TOKEN in D:\online-store\.env.local" }
  if (-not $dbId) { throw "Missing NOTION_DATABASE_TASKS in D:\online-store\.env.local" }
  return @{ token = $token; dbId = $dbId }
}

function Load-State {
  if ($ResetState -and (Test-Path $stateFile)) { Remove-Item $stateFile -Force }
  if (-not (Test-Path $stateFile)) {
    return @{ processed = @{}; jobs = @{} }
  }
  try {
    $json = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    if (-not $json.processed -or -not ($json.processed -is [hashtable])) { $json.processed = @{} }
    if (-not $json.jobs -or -not ($json.jobs -is [hashtable])) { $json.jobs = @{} }
    return $json
  } catch {
    return @{ processed = @{}; jobs = @{} }
  }
}

function Save-State($state) {
  function Normalize-HashtableKeys {
    param($obj)
    switch ($obj) {
      { $_ -is [hashtable] } {
        $out = @{}
        foreach ($k in $_.Keys) {
          $key = [string]$k
          $out[$key] = Normalize-HashtableKeys $_[$k]
        }
        return $out
      }
      { $_ -is [System.Collections.IDictionary] } {
        $out = @{}
        foreach ($k in $_.Keys) {
          $key = [string]$k
          $out[$key] = Normalize-HashtableKeys $_[$k]
        }
        return $out
      }
      { $_ -is [System.Collections.IEnumerable] -and -not ($_ -is [string]) } {
        return (@($_) | ForEach-Object { Normalize-HashtableKeys $_ })
      }
      default { return $obj }
    }
  }
  $normalized = Normalize-HashtableKeys $state
  $normalized | ConvertTo-Json -Depth 8 | Out-File -FilePath $stateFile -Encoding ascii
}

function Query-Tasks($token, $dbId, $agentName, $pageSize, $allTasks) {
  $headers = @{ Authorization = "Bearer $token"; 'Notion-Version' = '2022-06-28'; 'Content-Type' = 'application/json' }
  if ($allTasks) {
    $filter = @{ and = @(
      @{ property = 'Status'; status = @{ does_not_equal = 'Done' } }
    ) }
  } else {
    $filter = @{ and = @(
      @{ property = 'Agent'; select = @{ equals = $agentName } },
      @{ property = 'Status'; status = @{ does_not_equal = 'Done' } }
    ) }
  }
  $body = @{ 
    page_size = $pageSize;
    filter = $filter;
    sorts = @(
      @{ property = 'Priority'; direction = 'descending' },
      @{ timestamp = 'last_edited_time'; direction = 'descending' }
    )
  } | ConvertTo-Json -Depth 8

  return Invoke-RestMethod -Method Post -Uri ("https://api.notion.com/v1/databases/$dbId/query") -Headers $headers -Body $body
}

function Get-LocalQueueTasks($queueDir) {
  if (-not (Test-Path $queueDir)) { return @() }
  $files = Get-ChildItem $queueDir -Filter "*.prompt.txt" -ErrorAction SilentlyContinue
  $tasks = @()
  foreach ($f in $files) {
    $id = $f.BaseName
    $title = $id
    $url = ""
    try {
      $lines = Get-Content $f.FullName -First 40
      foreach ($ln in $lines) {
        if ($ln -match "Title:\s*(.+)$") { $title = $Matches[1].Trim(); continue }
        if ($ln -match "Notion URL:\s*(.+)$") { $url = $Matches[1].Trim(); continue }
      }
    } catch { }
    $task = [PSCustomObject]@{
      id = $id
      url = $url
      properties = @{
        Name = @{
          type  = "title"
          title = @(@{ plain_text = $title })
        }
      }
    }
    $tasks += $task
  }
  return $tasks
}

function Get-TaskTitle($page) {
  $props = $page.properties.PSObject.Properties
  $titleProp = $props | Where-Object { $_.Value.type -eq 'title' } | Select-Object -First 1
  if ($titleProp) { return ($titleProp.Value.title | ForEach-Object { $_.plain_text }) -join '' }
  return "(untitled)"
}

function Update-NotionStatus($token, $pageId, $statusName) {
  $headers = @{ Authorization = "Bearer $token"; 'Notion-Version' = '2022-06-28'; 'Content-Type' = 'application/json' }
  $body = @{ properties = @{ Status = @{ status = @{ name = $statusName } } } } | ConvertTo-Json -Depth 6
  Invoke-RestMethod -Method Patch -Uri ("https://api.notion.com/v1/pages/$pageId") -Headers $headers -Body $body | Out-Null
}

function Split-Text($text, [int]$maxLen) {
  $parts = @()
  if (-not $text) { return $parts }
  for ($i = 0; $i -lt $text.Length; $i += $maxLen) {
    $len = [Math]::Min($maxLen, $text.Length - $i)
    $parts += $text.Substring($i, $len)
  }
  return $parts
}

function Convert-LinesToBlocks($lines) {
  $blocks = @()
  foreach ($line in $lines) {
    $t = $line.TrimEnd()
    if ($t -eq "") { continue }
    $chunks = Split-Text $t 1800
    foreach ($chunk in $chunks) {
      $blocks += @{
        object = "block"
        type = "paragraph"
        paragraph = @{
          rich_text = @(
            @{ type = "text"; text = @{ content = $chunk } }
          )
        }
      }
    }
  }
  return $blocks
}

function Append-NotionUpdate($token, $pageId, $updatePath) {
  if (-not (Test-Path $updatePath)) { return $false }
  $lines = Get-Content $updatePath
  $blocks = Convert-LinesToBlocks $lines
  if (-not $blocks -or $blocks.Count -eq 0) { return $false }
  $headers = @{ Authorization = "Bearer $token"; 'Notion-Version' = '2022-06-28'; 'Content-Type' = 'application/json' }
  $body = @{ children = $blocks } | ConvertTo-Json -Depth 8
  Invoke-RestMethod -Method Patch -Uri ("https://api.notion.com/v1/blocks/$pageId/children") -Headers $headers -Body $body | Out-Null
  return $true
}

function Try-Append-NotionUpdate($token, $taskId, $state) {
  $processedEntry = $state.processed[$taskId]
  if ($processedEntry -and $processedEntry.notionUpdated -eq $true) { return $false }
  $updatePath = Join-Path $outUpdatesDir "$($taskId).update.md"
  if (-not (Test-Path $updatePath)) { $updatePath = Join-Path $queueDir "$($taskId).update.md" }
  if (-not (Test-Path $updatePath)) { Log-Line "NOUPDATE taskId=$taskId"; return $false }
  $ok = $false
  try {
    $ok = Append-NotionUpdate $token $taskId $updatePath
  } catch {
    Log-Line "NOTION UPDATE FAILED taskId=$taskId"
    return $false
  }
  if ($ok) {
    Log-Line "NOTION UPDATE taskId=$taskId"
    if ($processedEntry) { $processedEntry.notionUpdated = $true }
    return $true
  }
  return $false
}

function Log-Line($message) {
  $ts = Get-Date -Format o
  "$ts $message" | Add-Content -Path $appLog -Encoding ascii
}

function Sync-OutArtifacts {
  try {
    if (Test-Path $appLog) { Copy-Item -Path $appLog -Destination (Join-Path $outLogsDir "app.log") -Force }
    if (Test-Path $deployCsv) { Copy-Item -Path $deployCsv -Destination (Join-Path $outLogsDir "deployments.csv") -Force }
    if (Test-Path $updatesFile) { Copy-Item -Path $updatesFile -Destination (Join-Path $outLogsDir "notion-updates.md") -Force }
    if (Test-Path $logsNotionDeliverablesDir) {
      $target = Join-Path $outLogsDir "notion-deliverables"
      Copy-Item -Path $logsNotionDeliverablesDir -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {
    Log-Line "SYNC-OUT ERROR $($_.Exception.Message)"
  }
}

# Ensure deliverable filenames follow slug_taskId.ext to avoid duplicates
function Normalize-DeliverableNames {
  param([string]$dirPath = $outDeliverablesDir)
  if (-not (Test-Path $dirPath)) { return }

  function Get-KebabSlug($name) {
    $clean = $name -replace '[^A-Za-z0-9]+','-' -replace '^-+','' -replace '-+$',''
    if (-not $clean) { $clean = "deliverable" }
    return $clean.ToLower()
  }

  Get-ChildItem -Path $dirPath -File -Recurse | ForEach-Object {
    $file = $_
    $guidMatch = [regex]::Match($file.BaseName, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if (-not $guidMatch.Success) { return } # skip if no taskId to anchor
    $taskId = $guidMatch.Value

    # slug = part before guid (or whole name minus guid)
    $prefix = $file.BaseName.Substring(0, $guidMatch.Index)
    if (-not $prefix) { $prefix = "deliverable" }
    $slug = Get-KebabSlug $prefix

    $newName = "$slug`_$taskId$($file.Extension)"
    if ($newName -ieq $file.Name) { return }

    $target = Join-Path $file.DirectoryName $newName

    # avoid overwrite: if target exists but different content, append numeric suffix
    $n = 1
    while (Test-Path $target) {
      if ((Get-FileHash $file.FullName).Hash -eq (Get-FileHash $target).Hash) { return } # same content
      $target = Join-Path $file.DirectoryName "$slug`_$taskId`_$n$($file.Extension)"
      $n++
    }
    try {
      Rename-Item -Path $file.FullName -NewName (Split-Path $target -Leaf)
      Log-Line "RENAMED_DELIVERABLE old=$($file.Name) new=$(Split-Path $target -Leaf)"
    } catch {
      Log-Line "RENAME_FAIL file=$($file.FullName) err=$($_.Exception.Message)"
    }
  }
}

# Mirror artifacts into the GitHub workspace repo (best-effort; no failure throw)
function Sync-ToRepo {
  param([string]$taskId = "")
  if (-not (Test-Path $repoRoot)) { return }
  try {
    if (Test-Path $outDeliverablesDir) { Copy-Item $outDeliverablesDir\* $repoDeliverablesDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $outUpdatesDir) { Copy-Item $outUpdatesDir\* $repoUpdatesDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $outLogsDir) { Copy-Item $outLogsDir\* $repoLogsDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $logsNotionDeliverablesDir) { Copy-Item $logsNotionDeliverablesDir\* $repoLogsNotionDeliverablesDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $queueDir) { Copy-Item $queueDir\*.update.md $repoQueueDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $stateFile) { Copy-Item $stateFile $repoStateFile -Force -ErrorAction SilentlyContinue }

    $gitStatus = & git -C $repoRoot status --short 2>$null
    if ($gitStatus -and $gitStatus.Trim().Length -gt 0) {
      & git -C $repoRoot add workspace > $null 2>&1
      $msg = "ops-bot: sync artifacts"
      if ($taskId) { $msg = "$msg ($taskId)" }
      & git -C $repoRoot commit -m $msg > $null 2>&1
      & git -C $repoRoot push origin master > $null 2>&1
      Log-Line "REPO-COMMIT taskId=$taskId"
    }
  } catch {
    Log-Line "REPO-SYNC ERROR $($_.Exception.Message)"
  }
}

function Invoke-OpsBotTask($task, $token) {
  $title = Get-TaskTitle $task
  $taskId = $task.id
  $taskUrl = $task.url
  Write-Host "START: $title" -ForegroundColor Cyan
  Log-Line "START taskId=$taskId title=$title"

  if ($DryRun) {
    Log-Line "DRYRUN taskId=$taskId"
    Write-Host "SKIP (dry run): $title" -ForegroundColor Yellow
    return "dryrun"
  }

  $template = Get-Content $promptTemplate -Raw
  $prompt = $template.Replace("{{TASK_TITLE}}", $title).Replace("{{TASK_ID}}", $taskId).Replace("{{TASK_URL}}", $taskUrl).Replace("{{AGENT_NAME}}", $AgentName)
  $promptFile = Join-Path $queueDir "$($taskId).prompt.txt"
  $prompt | Out-File -FilePath $promptFile -Encoding ascii

  $outputFile = Join-Path $queueDir "$($taskId).last-message.txt"

  $dispatch = $env:OPS_BOT_DISPATCH
  $dispatchConfig = $env:OPS_BOT_CONFIG
  $groqCmd = $env:OPS_BOT_GROQ   # optional path to groq runner script/cli
  $cmdArgs = @(
    "exec",
    "--skip-git-repo-check",
    "--dangerously-bypass-approvals-and-sandbox",
    "-C", "D:\workspace",
    "--add-dir", "D:\workspace",
    "--add-dir", "D:\workspace\logs",
    "--add-dir", "D:\workspace\ops-bot",
    "-o", $outputFile,
    "-"
  )

  $attempt = 0
  do {
    $attempt++
    if ($dispatch -and (Test-Path $dispatch) -and $dispatchConfig) {
      try {
        & powershell -NoLogo -ExecutionPolicy Bypass -File $dispatch -ConfigPath $dispatchConfig -PromptFile $promptFile -OutputFile $outputFile -TaskId $taskId
        $exitCode = $LASTEXITCODE
      } catch {
        $exitCode = 1
      }
    } elseif ($groqCmd -and (Get-Command $groqCmd -ErrorAction SilentlyContinue)) {
      try {
        $prompt | & $groqCmd -o $outputFile
        $exitCode = $LASTEXITCODE
      } catch {
        $exitCode = 1
      }
    } else {
      try {
        $prompt | & codex @cmdArgs
        $exitCode = $LASTEXITCODE
      } catch {
        $exitCode = 1
      }
    }

    if ($exitCode -eq 0) {
      if ($AutoDone) {
        Update-NotionStatus $token $taskId "Done"
        Log-Line "DONE taskId=$taskId (Notion marked Done)"
      } else {
        Log-Line "DONE taskId=$taskId"
      }
      Write-Host "DONE: $title" -ForegroundColor Green
      return "done"
    }

    Log-Line "FAILED taskId=$taskId attempt=$attempt"
    Write-Host "FAILED: $title (attempt #$attempt)" -ForegroundColor Red

    if (-not $GodMode) {
      return "failed"
    }

    Write-Host "GODMODE retrying $title (attempt #$attempt)" -ForegroundColor Yellow
    Log-Line "GODMODE retry attempt=$attempt taskId=$taskId"
    Start-Sleep -Seconds 5
  } while ($true)
}

function Start-BackupJob($task, $token, $agentName, $autoDone) {
  $title = Get-TaskTitle $task
  $taskId = $task.id
  $taskUrl = $task.url
  $job = Start-Job -ScriptBlock {
    param($taskId, $title, $taskUrl, $agentName, $autoDone, $promptTemplate, $queueDir)
    $ErrorActionPreference = "Stop"
    $result = "failed"
    try {
      $template = Get-Content $promptTemplate -Raw
      $prompt = $template.Replace("{{TASK_TITLE}}", $title).Replace("{{TASK_ID}}", $taskId).Replace("{{TASK_URL}}", $taskUrl).Replace("{{AGENT_NAME}}", $agentName)
      $promptFile = Join-Path $queueDir "$($taskId).prompt.txt"
      $prompt | Out-File -FilePath $promptFile -Encoding ascii

      $outputFile = Join-Path $queueDir "$($taskId).last-message.txt"
      $dispatch = $env:OPS_BOT_DISPATCH
      $dispatchConfig = $env:OPS_BOT_CONFIG
      if ($dispatch -and (Test-Path $dispatch) -and $dispatchConfig) {
        $prompt | & powershell -NoLogo -ExecutionPolicy Bypass -File $dispatch -ConfigPath $dispatchConfig -PromptFile $promptFile -OutputFile $outputFile -TaskId $taskId
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { $result = "done" }
      } else {
        $cmdArgs = @(
          "exec",
          "--skip-git-repo-check",
          "--dangerously-bypass-approvals-and-sandbox",
          "-C", "D:\\workspace",
          "--add-dir", "D:\\workspace",
          "--add-dir", "D:\\workspace\\logs",
          "--add-dir", "D:\\workspace\\ops-bot",
          "-o", $outputFile,
          "-"
        )

        $prompt | & codex @cmdArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { $result = "done" }
      }
    } catch {
      $result = "failed"
    }
    [PSCustomObject]@{ taskId = $taskId; result = $result; title = $title }
  } -ArgumentList $taskId, $title, $taskUrl, $agentName, $autoDone, $promptTemplate, $queueDir
  return $job
}

Ensure-Paths
$state = Load-State

Write-Host "ops-bot watch started (Agent=$AgentName, AllTasks=$AllTasks, Interval=$IntervalSeconds s, MaxTasks=$MaxTasks, MaxConcurrentAgents=$MaxConcurrentAgents, Backup=$EnableBackup/$BackupMaxTasks)" -ForegroundColor Green
if ($GodMode) {
  Log-Line "GODMODE enabled: retrying failed tasks continuously until success"
  Write-Host "GODMODE is active; failed tasks will retry indefinitely" -ForegroundColor Magenta
}

while ($true) {
  try {
    if ($LocalQueue) {
      $cfg = $null
      $tasks = Get-LocalQueueTasks $queueDir
    } else {
      $cfg = Get-NotionConfig
      $resp = Query-Tasks $cfg.token $cfg.dbId $AgentName 50 $AllTasks
      $tasks = $resp.results
    }

    if (-not $tasks -or $tasks.Count -eq 0) {
      if ($LocalQueue) {
        Write-Host "No local queue tasks" -ForegroundColor DarkGray
      } elseif ($AllTasks) {
        Write-Host "No tasks (Status != Done)" -ForegroundColor DarkGray
      } else {
        Write-Host "No tasks for Agent=$AgentName" -ForegroundColor DarkGray
      }
    } else {
      # queue only new & unprocessed tasks (never redo completed)
      foreach ($t in $tasks) {
        $id = $t.id
        if ($state.processed.ContainsKey($id)) {
          $existingStatus = $state.processed[$id].status
          if ($existingStatus -ne "queued") { continue } # already handled once
          if (-not $state.processed[$id].ContainsKey("notionUpdated")) { $state.processed[$id].notionUpdated = $false }
        } else {
          $state.processed[$id] = @{ status = "queued"; updated = (Get-Date -Format o); notionUpdated = $false }
        }
      }

      # finalize any completed backup jobs
      if ($state.jobs.Count -gt 0) {
        foreach ($kv in @($state.jobs.GetEnumerator())) {
          $jobId = $kv.Key
          $taskId = $kv.Value.taskId
          $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
          if ($job -and $job.State -in @("Completed","Failed","Stopped")) {
            $jobResult = Receive-Job -Id $jobId -ErrorAction SilentlyContinue | Select-Object -First 1
            Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
            $status = "failed"
            if ($jobResult -and $jobResult.result -eq "done") { $status = "done" }
            $state.processed[$taskId] = @{ status = $status; updated = (Get-Date -Format o); notionUpdated = ($state.processed[$taskId].notionUpdated -eq $true) }
            $state.jobs.Remove($jobId)
            Log-Line "BACKUP $status taskId=$taskId"
            if ($jobResult -and $jobResult.title) {
              Write-Host "BACKUP $($status.ToUpper()): $($jobResult.title)" -ForegroundColor Green
            }
            if ($cfg -and $AutoDone -and $status -eq "done") {
              Update-NotionStatus $cfg.token $taskId "Done"
              Log-Line "DONE taskId=$taskId (Notion marked Done)"
            }
            if ($cfg -and $status -ne "dryrun") {
              [void](Try-Append-NotionUpdate $cfg.token $taskId $state)
            }
            Normalize-DeliverableNames
            Sync-ToRepo $taskId
            Save-State $state
          }
        }
      }

      $queuedAll = $state.processed.GetEnumerator() | Where-Object { $_.Value.status -eq "queued" }
      $queued = $queuedAll | Select-Object -First $MaxTasks
      foreach ($q in $queued) {
        $task = $tasks | Where-Object { $_.id -eq $q.Key } | Select-Object -First 1
        if (-not $task) { continue }
        $tokenArg = $null
        if ($cfg) { $tokenArg = $cfg.token }
        $result = Invoke-OpsBotTask $task $tokenArg
        $state.processed[$q.Key] = @{ status = $result; updated = (Get-Date -Format o); notionUpdated = ($state.processed[$q.Key].notionUpdated -eq $true) }
        if ($cfg -and $result -ne "dryrun") {
          [void](Try-Append-NotionUpdate $cfg.token $q.Key $state)
        }
        Normalize-DeliverableNames
        Sync-ToRepo $q.Key
        Save-State $state
      }

      if ($EnableBackup) {
        $runningBackups = @($state.jobs.GetEnumerator()).Count
        $availableSlots = $MaxConcurrentAgents - 1 - $runningBackups
        if ($availableSlots -lt 0) { $availableSlots = 0 }
        $backupLimit = [Math]::Min($BackupMaxTasks, $availableSlots)
        if ($cfg -and $backupLimit -gt 0 -and ($queuedAll.Count -gt $MaxTasks)) {
          $backup = $queuedAll | Select-Object -Skip $MaxTasks -First $backupLimit
        foreach ($b in $backup) {
          $task = $tasks | Where-Object { $_.id -eq $b.Key } | Select-Object -First 1
          if (-not $task) { continue }
          $job = Start-BackupJob $task $cfg.token $AgentName $AutoDone
          $state.jobs[$job.Id] = @{ taskId = $task.id; updated = (Get-Date -Format o) }
          $state.processed[$task.id] = @{ status = "backup-running"; updated = (Get-Date -Format o); notionUpdated = ($state.processed[$task.id].notionUpdated -eq $true) }
          Save-State $state
          Write-Host "BACKUP START: $(Get-TaskTitle $task)" -ForegroundColor DarkCyan
          Log-Line "BACKUP START taskId=$($task.id)"
        }
        }
      }
    }
  } catch {
    Log-Line "ERROR $($_.Exception.Message)"
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  }

  if ($Once) { break }
  Sync-OutArtifacts
  Normalize-DeliverableNames
  Sync-ToRepo
  Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "ops-bot watch stopped" -ForegroundColor Green
