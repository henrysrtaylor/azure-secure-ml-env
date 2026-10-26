param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$VmName,
    [string]$IdleMinutes = '0',
    [string]$InstallTools = 'true'
)
# Runs on each VM at deployment through a run command. Failures are logged and never fail the deployment.
$ErrorActionPreference = 'Continue'
$log = 'C:\ProvisionTools.log'
function Log($m) { "$(Get-Date -Format s) $m" | Out-File $log -Append -Encoding ascii }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Install-FromUrl($name, $url, $file, $filePath, $arguments) {
    try {
        $target = Join-Path $env:TEMP $file
        Log "downloading $name"
        Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
        Log "installing $name"
        $proc = Start-Process -FilePath $filePath -ArgumentList ($arguments -replace '__FILE__', $target) -Wait -PassThru
        Log "$name finished with exit code $($proc.ExitCode)"
    }
    catch { Log "$name failed: $_" }
}

if ($InstallTools -eq 'true' -or $InstallTools -eq 'True') {
    # Edge opens ml.azure.com and the portal; this only relaxes Internet Explorer's enhanced security mode.
    try {
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -ErrorAction Stop
        Log 'disabled IE enhanced security for administrators'
    }
    catch { Log "IE enhanced security change failed: $_" }

    Install-FromUrl 'Git' 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' 'git.exe' '__FILE__' '/VERYSILENT /NORESTART /SP-'
    Install-FromUrl 'Python' 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe' 'python.exe' '__FILE__' '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0'
    Install-FromUrl 'VS Code' 'https://update.code.visualstudio.com/latest/win32-x64/stable' 'vscode.exe' '__FILE__' '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addtopath'
    Install-FromUrl 'Azure CLI' 'https://aka.ms/installazurecliwindows' 'azure-cli.msi' 'msiexec.exe' '/i "__FILE__" /quiet /norestart'
}

# Idle shutdown: every 5 minutes a task checks for activity and deallocates the VM (so compute stops billing)
# after IdleMinutes with no active session and no CPU load. The VM's own identity makes the call.
if ([int]$IdleMinutes -gt 0) {
    try {
        $dir = 'C:\ProgramData\IdleShutdown'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @{ IdleMinutes = [int]$IdleMinutes; SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; VmName = $VmName } | ConvertTo-Json | Set-Content "$dir\config.json"
        (Get-Date).ToUniversalTime().ToString('o') | Set-Content "$dir\last-active.txt"

        $check = @'
$dir = 'C:\ProgramData\IdleShutdown'
$cfg = Get-Content "$dir\config.json" -Raw | ConvertFrom-Json
$stateFile = "$dir\last-active.txt"
$active = $false
# Any logged-on user whose session is Active (a disconnected session counts as idle).
$q = quser 2>$null
if ($q) { foreach ($l in ($q | Select-Object -Skip 1)) { if ($l -match '\sActive\s') { $active = $true } } }
# A busy machine (for example a training job) also counts as active.
if (-not $active) {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 3).CounterSamples | Measure-Object -Property CookedValue -Average
    if ($cpu.Average -ge 15) { $active = $true }
}
if ($active -or -not (Test-Path $stateFile)) {
    (Get-Date).ToUniversalTime().ToString('o') | Set-Content $stateFile
    return
}
$last = [datetime]::Parse((Get-Content $stateFile -Raw).Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
if (((Get-Date).ToUniversalTime() - $last).TotalMinutes -ge $cfg.IdleMinutes) {
    $token = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/'
    $uri = "https://management.azure.com/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$($cfg.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($cfg.VmName)/deallocate?api-version=2024-03-01"
    "$(Get-Date -Format s) idle for $($cfg.IdleMinutes) minutes, deallocating" | Out-File "$dir\idle.log" -Append -Encoding ascii
    Invoke-RestMethod -Method Post -Headers @{ Authorization = "Bearer $($token.access_token)" } -Uri $uri | Out-Null
}
'@
        Set-Content -Path "$dir\check.ps1" -Value $check
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $dir\check.ps1"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'IdleShutdown' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Log "idle shutdown configured: $IdleMinutes minutes"
    }
    catch { Log "idle shutdown setup failed: $_" }
}

Log 'done'
exit 0
