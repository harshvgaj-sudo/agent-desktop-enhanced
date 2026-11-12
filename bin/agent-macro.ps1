<#
.SYNOPSIS
    agent-macro.ps1 - High-Level Compound Automation Engine for AI Agents.
    Reduces multi-step desktop tasks into single compound calls.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgePath = Join-Path $ScriptDir "agent-desk.ps1"
if (-not (Test-Path $BridgePath)) {
    $cmd = Get-Command "agent-desk.ps1" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        $BridgePath = $cmd.Source
    } else {
        $BridgePath = Join-Path $env:APPDATA "npm\agent-desk.ps1"
    }
}

function Invoke-AgentDesk {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments=$true)]
        [object[]]$CommandArgs
    )
    $flattened = @()
    foreach ($item in $CommandArgs) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string])) {
            foreach ($sub in $item) {
                if ($null -ne $sub) { $flattened += [string]$sub }
            }
        } else {
            $flattened += [string]$item
        }
    }
    $res = & $BridgePath @flattened
    $joined = ($res -join "`n").Trim()
    if (-not $joined) { return $null }
    try {
        return ($joined | ConvertFrom-Json)
    } catch {
        return $res
    }
}

function Snapshot-App {
    param(
        [Parameter(Mandatory=$true)][string]$App,
        [switch]$Skeleton
    )
    $cmd = @("snapshot", "--app", $App, "-i", "--compact")
    if ($Skeleton) { $cmd += "--skeleton" }
    return (Invoke-AgentDesk @cmd)
}

function Find-And-Click {
    param(
        [Parameter(Mandatory=$true)][string]$App,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Role = "button"
    )
    # Step 1: Find target ref
    $findRes = Invoke-AgentDesk @("find", "--app", $App, "--role", $Role, "--name", $Name, "--first")
    
    $targetRef = $null
    if ($findRes.data.match) {
        $targetRef = $findRes.data.match.ref_id
    } elseif ($findRes.data.matches -and $findRes.data.matches.Count -gt 0) {
        $targetRef = $findRes.data.matches[0].ref_id
    }

    if (-not $findRes.ok -or -not $targetRef) {
        return @{ ok = $false; error = "Element '$Name' with role '$Role' not found in $App" }
    }

    # Step 2: Click the target
    $clickRes = Invoke-AgentDesk @("click", $targetRef)
    return $clickRes
}

function Set-AppField {
    param(
        [Parameter(Mandatory=$true)][string]$App,
        [Parameter(Mandatory=$true)][string]$FieldName,
        [Parameter(Mandatory=$true)][string]$Value
    )
    # Step 1: Find field ref
    $findRes = Invoke-AgentDesk @("find", "--app", $App, "--role", "textfield", "--name", $FieldName, "--first")
    
    $fieldRef = $null
    if ($findRes.data.match) {
        $fieldRef = $findRes.data.match.ref_id
    } elseif ($findRes.data.matches -and $findRes.data.matches.Count -gt 0) {
        $fieldRef = $findRes.data.matches[0].ref_id
    }

    if (-not $fieldRef) {
        # Fallback to search without exact role
        $findRes = Invoke-AgentDesk @("find", "--app", $App, "--name", $FieldName, "--first")
        if ($findRes.data.match) {
            $fieldRef = $findRes.data.match.ref_id
        } elseif ($findRes.data.matches -and $findRes.data.matches.Count -gt 0) {
            $fieldRef = $findRes.data.matches[0].ref_id
        }
    }

    if (-not $findRes.ok -or -not $fieldRef) {
        return @{ ok = $false; error = "Field '$FieldName' not found in $App" }
    }

    # Step 2: Set Value
    $setRes = Invoke-AgentDesk @("set-value", $fieldRef, $Value)
    return $setRes
}

function Wait-AppWindow {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [int]$TimeoutMs = 15000
    )
    return (Invoke-AgentDesk @("wait", "--window", $Title, "--timeout", "$TimeoutMs"))
}

# CLI dispatcher if executed directly from terminal
if ($args.Count -gt 0) {
    $verb = $args[0].ToLower()
    switch ($verb) {
        "snapshot" {
            $rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
            $useSkeleton = ($rest -contains "-Skeleton") -or ($rest -contains "--skeleton")
            $appTarget = ($rest | Where-Object { $_ -notmatch '^-{1,2}skeleton$' } | Select-Object -First 1)
            if (-not $appTarget) {
                Write-Host "Usage: agent-macro.ps1 snapshot <app> [-Skeleton]"
                exit 1
            }
            Snapshot-App -App $appTarget -Skeleton:$useSkeleton
        }
        "find-click" {
            if ($args.Count -lt 3) {
                Write-Host "Usage: agent-macro.ps1 find-click <app> <name> [role]"
                exit 1
            }
            Find-And-Click -App $args[1] -Name $args[2] -Role $(if ($args.Count -gt 3) { $args[3] } else { "button" })
        }
        "set-field" {
            if ($args.Count -lt 4) {
                Write-Host "Usage: agent-macro.ps1 set-field <app> <fieldName> <value>"
                exit 1
            }
            Set-AppField -App $args[1] -FieldName $args[2] -Value $args[3]
        }
        "wait-window" {
            if ($args.Count -lt 2) {
                Write-Host "Usage: agent-macro.ps1 wait-window <title> [timeoutMs]"
                exit 1
            }
            Wait-AppWindow -Title $args[1] -TimeoutMs $(if ($args.Count -gt 2) { [int]$args[2] } else { 15000 })
        }
        default {
            Write-Host "Usage: agent-macro.ps1 <snapshot|find-click|set-field|wait-window> [args...]"
            exit 1
        }
    }
}
