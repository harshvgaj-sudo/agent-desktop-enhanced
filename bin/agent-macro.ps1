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
        [string[]]$CommandArgs
    )
    $res = & $BridgePath @CommandArgs
    try {
        return ($res | ConvertFrom-Json)
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
    if (-not $findRes.ok -or -not $findRes.data.matches -or $findRes.data.matches.Count -eq 0) {
        return @{ ok = $false; error = "Element '$Name' with role '$Role' not found in $App" }
    }
    
    $targetRef = $findRes.data.matches[0].ref_id
    if (-not $targetRef) {
        return @{ ok = $false; error = "Match found for '$Name' but had no actionable ref_id" }
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
    if (-not $findRes.ok -or -not $findRes.data.matches -or $findRes.data.matches.Count -eq 0) {
        # Fallback to search without exact role
        $findRes = Invoke-AgentDesk @("find", "--app", $App, "--name", $FieldName, "--first")
        if (-not $findRes.ok -or -not $findRes.data.matches -or $findRes.data.matches.Count -eq 0) {
            return @{ ok = $false; error = "Field '$FieldName' not found in $App" }
        }
    }

    $fieldRef = $findRes.data.matches[0].ref_id
    if (-not $fieldRef) {
        return @{ ok = $false; error = "Field '$FieldName' has no actionable ref_id" }
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
            Snapshot-App -App $args[1]
        }
        "find-click" {
            Find-And-Click -App $args[1] -Name $args[2] -Role $(if ($args.Count -gt 3) { $args[3] } else { "button" })
        }
        "set-field" {
            Set-AppField -App $args[1] -FieldName $args[2] -Value $args[3]
        }
        "wait-window" {
            Wait-AppWindow -Title $args[1] -TimeoutMs $(if ($args.Count -gt 2) { [int]$args[2] } else { 15000 })
        }
        default {
            Write-Host "Usage: agent-macro.ps1 <snapshot|find-click|set-field|wait-window> [args...]"
        }
    }
}
