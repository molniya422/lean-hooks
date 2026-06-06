# lean-hooks installer for Windows
param()

$Target = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "$env:USERPROFILE\.claude" }
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== lean-hooks Installer (Windows) ==="
Write-Host "Target: $Target"

# Create directories
$dirs = @("harness", "skill-feedback", "multiagent-feedback", "rules", "memory", "projects", "data")
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path "$Target\$d" | Out-Null
}

# Copy harness scripts
Write-Host "[1/3] Installing harness scripts..."
Copy-Item "$Source\harness\*.sh" "$Target\harness\" -Force
Copy-Item "$Source\harness\*.py" "$Target\harness\" -Force

# Copy templates
Write-Host "[2/3] Installing templates..."
Copy-Item "$Source\templates\skill-feedback\*" "$Target\skill-feedback\" -Force -ErrorAction SilentlyContinue
Copy-Item "$Source\templates\multiagent-feedback\*" "$Target\multiagent-feedback\" -Force -ErrorAction SilentlyContinue
Copy-Item "$Source\templates\rules\*" "$Target\rules\" -Force -ErrorAction SilentlyContinue
Copy-Item "$Source\templates\memory\*" "$Target\memory\" -Force -ErrorAction SilentlyContinue

# Config files
Write-Host "[3/3] Setting up config..."
if (-not (Test-Path "$Target\settings.json")) {
    Copy-Item "$Source\settings.template.json" "$Target\settings.json"
    Write-Host "  Created settings.json from template"
} else {
    Write-Host "  settings.json exists - merge hooks manually"
}
if (-not (Test-Path "$Target\CLAUDE.md")) {
    Copy-Item "$Source\CLAUDE.md.template" "$Target\CLAUDE.md"
    Write-Host "  Created CLAUDE.md from template"
} else {
    Write-Host "  CLAUDE.md exists - merge manually"
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Set HARNESS_PYTHON env var if Python is not auto-detected."
Write-Host "Restart Claude Code to activate hooks."
