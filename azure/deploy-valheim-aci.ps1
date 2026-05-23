# Deploy game servers (Valheim/Windrose) to Azure Container Instances (ACI).
# Prerequisites: Azure CLI (az), Docker, logged in to Azure (az login).
# Usage: .\deploy-valheim-aci.ps1 -Game "valheim" -UserName "kk" -ServerName "My Server" -WorldName "Dedicated" -ServerPass "YourPassword"
# Windrose: .\deploy-valheim-aci.ps1 -Game "windrose" -UserName "kk" -ServerName "My Windrose Server" -ServerPass "YourPassword" [-WindroseDirectPort 3000]
# Optional: -KeyVaultSecretName "valheim-server-1-password" to use Key Vault instead of -ServerPass
# Versioning: use -ImageTag to deploy a specific image (e.g. 20260208). Use -PinVersion with a tag to disable in-container Steam updates (lock at that version).
# World modifiers: optional -CombatModifier, -DeathPenaltyModifier, -ResourcesModifier, -RaidsModifier, -PortalsModifier, -WorldSeed map to Valheim's -modifier/-worldseed flags.

param(
    [ValidateSet("valheim", "windrose")]
    [string]$Game = "valheim",
    [Parameter(Mandatory = $true)]
    [string]$UserName,
    [Parameter(Mandatory = $true)]
    [string]$ServerName,
    [string]$WorldName,
    [Parameter(ParameterSetName = "Password")]
    [string]$ServerPass,
    [Parameter(ParameterSetName = "KeyVault")]
    [string]$KeyVaultSecretName,
    [string]$InstanceName = "",
    [string]$CombatModifier = "",
    [string]$DeathPenaltyModifier = "",
    [string]$ResourcesModifier = "",
    [string]$RaidsModifier = "",
    [string]$PortalsModifier = "",
    [string]$WorldSeed = "",
    [string]$ImageTag = "",
    [switch]$SkipImageBuild,
    [switch]$PinVersion,
    [int]$WindroseDirectPort = 3000
)

function Format-YamlScalar {
    param([string]$Value)
    if ($null -eq $Value) { return "''" }
    if ($Value -match '[:#\[\]{}|>&*!%@`,]') {
        return "'" + ($Value -replace "'", "''") + "'"
    }
    return $Value
}

function New-AciContainerGroupDeployFile {
    param(
        [string]$OutputPath,
        [string]$ContainerGroupName,
        [string]$Location,
        [string]$Image,
        [decimal]$Cpu,
        [decimal]$MemoryInGb,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$FileShareName,
        [string]$MountPath,
        [string]$RegistryServer,
        [string]$RegistryUsername,
        [string]$RegistryPassword,
        [array]$Ports,
        [string[]]$EnvironmentVariables,
        [string[]]$SecureEnvironmentVariables
    )

    $yaml = New-Object System.Text.StringBuilder
    [void]$yaml.AppendLine("location: $(Format-YamlScalar $Location)")
    [void]$yaml.AppendLine("name: $(Format-YamlScalar $ContainerGroupName)")
    [void]$yaml.AppendLine("properties:")
    [void]$yaml.AppendLine("  osType: Linux")
    [void]$yaml.AppendLine("  restartPolicy: Always")
    [void]$yaml.AppendLine("  ipAddress:")
    [void]$yaml.AppendLine("    type: Public")
    [void]$yaml.AppendLine("    ports:")
    foreach ($p in $Ports) {
        [void]$yaml.AppendLine("    - protocol: $($p.protocol)")
        [void]$yaml.AppendLine("      port: $($p.port)")
    }
    [void]$yaml.AppendLine("  imageRegistryCredentials:")
    [void]$yaml.AppendLine("  - server: $(Format-YamlScalar $RegistryServer)")
    [void]$yaml.AppendLine("    username: $(Format-YamlScalar $RegistryUsername)")
    [void]$yaml.AppendLine("    password: $(Format-YamlScalar $RegistryPassword)")
    [void]$yaml.AppendLine("  volumes:")
    [void]$yaml.AppendLine("  - name: gamedata")
    [void]$yaml.AppendLine("    azureFile:")
    [void]$yaml.AppendLine("      shareName: $(Format-YamlScalar $FileShareName)")
    [void]$yaml.AppendLine("      storageAccountName: $(Format-YamlScalar $StorageAccountName)")
    [void]$yaml.AppendLine("      storageAccountKey: $(Format-YamlScalar $StorageAccountKey)")
    [void]$yaml.AppendLine("  containers:")
    [void]$yaml.AppendLine("  - name: $(Format-YamlScalar $ContainerGroupName)")
    [void]$yaml.AppendLine("    properties:")
    [void]$yaml.AppendLine("      image: $(Format-YamlScalar $Image)")
    [void]$yaml.AppendLine("      ports:")
    foreach ($p in $Ports) {
        [void]$yaml.AppendLine("      - protocol: $($p.protocol)")
        [void]$yaml.AppendLine("        port: $($p.port)")
    }
    [void]$yaml.AppendLine("      resources:")
    [void]$yaml.AppendLine("        requests:")
    [void]$yaml.AppendLine("          cpu: $Cpu")
    [void]$yaml.AppendLine("          memoryInGb: $MemoryInGb")
    [void]$yaml.AppendLine("      environmentVariables:")
    foreach ($entry in $EnvironmentVariables) {
        $idx = $entry.IndexOf("=")
        if ($idx -lt 1) { continue }
        $name = $entry.Substring(0, $idx)
        $value = $entry.Substring($idx + 1)
        [void]$yaml.AppendLine("      - name: $(Format-YamlScalar $name)")
        [void]$yaml.AppendLine("        value: $(Format-YamlScalar $value)")
    }
    foreach ($entry in $SecureEnvironmentVariables) {
        $idx = $entry.IndexOf("=")
        if ($idx -lt 1) { continue }
        $name = $entry.Substring(0, $idx)
        $value = $entry.Substring($idx + 1)
        [void]$yaml.AppendLine("      - name: $(Format-YamlScalar $name)")
        [void]$yaml.AppendLine("        secureValue: $(Format-YamlScalar $value)")
    }
    [void]$yaml.AppendLine("      volumeMounts:")
    [void]$yaml.AppendLine("      - name: gamedata")
    [void]$yaml.AppendLine("        mountPath: $(Format-YamlScalar $MountPath)")

    [System.IO.File]::WriteAllText($OutputPath, $yaml.ToString())
}

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $ScriptDir "azure-config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$subscriptionId = $config.subscriptionId
$resourceGroup = $config.resourceGroup
$region = $config.region
$acrName = $config.acr.name
$acrLoginServer = $config.acr.loginServer
$storageAccountName = $config.storage.accountName
$fileShareName = $config.storage.fileShareName
$fileShareBackups = $config.storage.fileShareBackups
$keyVaultName = $config.keyVault.name
$cpu = $config.aci.cpu
$memoryInGb = $config.aci.memoryInGb
if (-not $ImageTag) { $ImageTag = $config.acr.defaultImageTag }
if (-not $ImageTag) { $ImageTag = "latest" }

# Load game-specific configuration.
$gameConfig = $config.games.$Game
if (-not $gameConfig) {
    Write-Error "Game '$Game' not found in azure-config.json games section."
}
if (-not $gameConfig.enabled) {
    Write-Error "Game '$Game' is disabled in azure-config.json."
}

$gameDisplayName = if ($gameConfig.displayName) { [string]$gameConfig.displayName } else { $Game }
$imageRepository = [string]$gameConfig.imageRepository
$mountPath = [string]$gameConfig.mountPath
$repoFolder = [string]$gameConfig.repoFolder
$ports = @($gameConfig.ports)

if (-not $imageRepository) { Write-Error "games.$Game.imageRepository is required." }
if (-not $mountPath) { Write-Error "games.$Game.mountPath is required." }
if (-not $repoFolder) { Write-Error "games.$Game.repoFolder is required." }

if ($gameConfig.aci) {
    if ($gameConfig.aci.cpu) { $cpu = $gameConfig.aci.cpu }
    if ($gameConfig.aci.memoryInGb) { $memoryInGb = $gameConfig.aci.memoryInGb }
}

# Azure Container Group name constraints (1-63 chars, lowercase letters, numbers, hyphens).
$maxInstanceNameLength = 63

# Build instance name automatically unless explicitly provided.
$isInstanceNameProvided = $PSBoundParameters.ContainsKey("InstanceName")
$cleanUserName = $UserName.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
$cleanUserName = $cleanUserName.Trim('-')
if (-not $cleanUserName) {
    Write-Error "UserName must contain at least one letter or number after sanitization."
}
if (-not $InstanceName) {
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
    $baseInstanceName = "$Game-$cleanUserName-$timestamp"
    $InstanceName = $baseInstanceName
}
if ($InstanceName.Length -gt $maxInstanceNameLength) {
    Write-Error "InstanceName '$InstanceName' is $($InstanceName.Length) characters; Azure limit is $maxInstanceNameLength. Retry with a shorter UserName or provide a shorter -InstanceName."
}

if ($Game -eq "valheim") {
    # Resolve server password for Valheim.
    if ($KeyVaultSecretName) {
        if (-not $keyVaultName) { Write-Error "keyVault.name is empty in config." }
        $ServerPass = (az keyvault secret show --vault-name $keyVaultName --name $KeyVaultSecretName --query value -o tsv)
        if (-not $ServerPass) { Write-Error "Could not read secret from Key Vault." }
    }
    if (-not $WorldName) {
        Write-Error "WorldName is required for valheim."
    }
    if (-not $ServerPass -or $ServerPass.Length -lt 5) {
        Write-Error "SERVER_PASS must be at least 5 characters for valheim. Use -ServerPass or -KeyVaultSecretName."
    }
} elseif ($Game -eq "windrose") {
    if ($KeyVaultSecretName) {
        if (-not $keyVaultName) { Write-Error "keyVault.name is empty in config." }
        $ServerPass = (az keyvault secret show --vault-name $keyVaultName --name $KeyVaultSecretName --query value -o tsv)
        if (-not $ServerPass) { Write-Error "Could not read secret from Key Vault." }
    }
    if (-not $ServerPass) {
        Write-Error "ServerPass is required for Windrose (direct connection password). Use -ServerPass or -KeyVaultSecretName."
    }
    if ($ports.Count -eq 0) {
        Write-Error "games.windrose.ports must include direct connection ports (TCP and UDP 3000) in azure-config.json."
    }
}

Write-Host "Setting subscription to $subscriptionId"
az account set --subscription $subscriptionId

Write-Host "Logging in to ACR: $acrLoginServer"
az acr login --name $acrName

$imageRef = "${acrLoginServer}/${imageRepository}:${ImageTag}"
if (-not $SkipImageBuild) {
    $gamePath = Join-Path $RepoRoot $repoFolder
    if (-not (Test-Path (Join-Path $gamePath "Dockerfile"))) {
        Write-Error "$gameDisplayName Dockerfile not found at $gamePath"
    }
    Write-Host "Building $gameDisplayName image in $gamePath (tag: $ImageTag)"
    docker build -t "${acrLoginServer}/${imageRepository}:${ImageTag}" $gamePath
    if ($ImageTag -ne "latest") {
        docker tag "${acrLoginServer}/${imageRepository}:${ImageTag}" "${acrLoginServer}/${imageRepository}:latest"
    }
    Write-Host "Pushing image to ACR (tag: $ImageTag)"
    docker push "${acrLoginServer}/${imageRepository}:${ImageTag}"
    if ($ImageTag -ne "latest") { docker push "${acrLoginServer}/${imageRepository}:latest" }
} else {
    Write-Host "Skipping image build (-SkipImageBuild). Using image $imageRef"
}

Write-Host "Getting storage account key"
$storageKey = (az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query "[0].value" -o tsv)
if (-not $storageKey) { Write-Error "Could not get storage account key." }

# Ensure auto-generated instance names are unique in storage backup folder by suffixing if needed.
# Do not mutate explicitly provided -InstanceName values because users may be intentionally
# reusing a stable instance path for persistence tests/restores.
if ($fileShareBackups -and -not $isInstanceNameProvided) {
    $candidate = $InstanceName
    $suffix = 1
    while ($true) {
        $exists = (az storage directory exists --share-name $fileShareBackups --name $candidate --account-name $storageAccountName --account-key $storageKey --query exists -o tsv 2>$null)
        if ($exists -ne "true") { break }
        $candidate = "{0}-{1:D2}" -f $InstanceName, $suffix
        $suffix++
    }
    if ($candidate -ne $InstanceName) {
        if ($candidate.Length -gt $maxInstanceNameLength) {
            Write-Error "InstanceName collision suffix produced '$candidate' ($($candidate.Length) chars), exceeding Azure limit $maxInstanceNameLength. Retry with a shorter UserName or provide -InstanceName."
        }
        Write-Host "Instance name already exists; using unique name '$candidate'."
        $InstanceName = $candidate
    }
} elseif ($fileShareBackups -and $isInstanceNameProvided) {
    Write-Host "Using explicit InstanceName '$InstanceName' as provided."
}

# Ensure gameserverbackups share exists and create per-server subdir for backup jobs
if ($fileShareBackups) {
    Write-Host "Ensuring backup share '$fileShareBackups' and subdir '$InstanceName' exist"
    az storage share create --name $fileShareBackups --account-name $storageAccountName --account-key $storageKey --only-show-errors 2>$null
    az storage directory create --share-name $fileShareBackups --name $InstanceName --account-name $storageAccountName --account-key $storageKey --only-show-errors 2>$null
}

$autoUpdate = if ($PinVersion) { "0" } else { "1" }
if ($PinVersion) { Write-Host "PinVersion: AUTO_UPDATE=0 (server will not run Steam updates; stays on image version)" }

$aciName = $InstanceName
Write-Host "Creating ACI container group: $aciName ($gameDisplayName image: $ImageTag, CPU: $cpu, Memory: ${memoryInGb} GB)"

# ACI CLI exposes one port per --ports; use main game port 2456 (UDP). 2457/2458 optional for Steam query.
$registryUser = (az acr credential show --name $acrName --query username -o tsv)
$registryPass = (az acr credential show --name $acrName --query "passwords[0].value" -o tsv)

$envVars = @(
    "SERVER_NAME=$ServerName",
    "AUTO_UPDATE=$autoUpdate",
    "SERVER_DATA_SUBDIR=$InstanceName"
)

$secureEnvVars = @()

if ($Game -eq "valheim") {
    $envVars += "WORLD_NAME=$WorldName"
    $envVars += "PORT=2456"
    $envVars += "PUBLIC=1"
    $secureEnvVars += "SERVER_PASS=$ServerPass"

    if ($CombatModifier)       { $envVars += "COMBAT_MODIFIER=$CombatModifier" }
    if ($DeathPenaltyModifier) { $envVars += "DEATHPENALTY_MODIFIER=$DeathPenaltyModifier" }
    if ($ResourcesModifier)    { $envVars += "RESOURCES_MODIFIER=$ResourcesModifier" }
    if ($RaidsModifier)        { $envVars += "RAIDS_MODIFIER=$RaidsModifier" }
    if ($PortalsModifier)      { $envVars += "PORTALS_MODIFIER=$PortalsModifier" }
    if ($WorldSeed)            { $envVars += "WORLDSEED=$WorldSeed" }
} elseif ($Game -eq "windrose") {
    $envVars += "STEAM_UPDATE_ON_START=$autoUpdate"
    # Force-platform flag often causes "Missing configuration" for 4129620 on Linux SteamCMD.
    $envVars += "STEAMCMD_FORCE_PLATFORM_WINDOWS=0"
    $envVars += "XVFB_DISPLAY=:99"
    $envVars += "WINDROSE_DIRECT_PORT=$WindroseDirectPort"
    $envVars += "WINDROSE_ENSURE_DIRECT_CONFIG=0"
    $secureEnvVars += "WINDROSE_SERVER_PASSWORD=$ServerPass"
}

# Validate required game options listed in config
$requiredOptions = @($gameConfig.serverOptions.required)
foreach ($requiredOption in $requiredOptions) {
    switch ($requiredOption) {
        "ServerName" { if (-not $ServerName) { Write-Error "ServerName is required for $Game." } }
        "WorldName" { if (-not $WorldName) { Write-Error "WorldName is required for $Game." } }
        "ServerPass" { if (-not $ServerPass -or $ServerPass.Length -lt 5) { Write-Error "ServerPass is required for $Game and must be at least 5 characters." } }
        default { Write-Warning "Required option '$requiredOption' is listed for $Game but is not validated by this script yet." }
    }
}

$containerCreateArgs = @(
    "container", "create",
    "--resource-group", $resourceGroup,
    "--name", $aciName,
    "--os-type", "Linux",
    "--image", $imageRef,
    "--registry-login-server", $acrLoginServer,
    "--registry-username", $registryUser,
    "--registry-password", $registryPass,
    "--cpu", "$cpu",
    "--memory", "$memoryInGb",
    "--ip-address", "public",
    "--restart-policy", "Always",
    "--azure-file-volume-account-name", $storageAccountName,
    "--azure-file-volume-account-key", $storageKey,
    "--azure-file-volume-share-name", $fileShareName,
    "--azure-file-volume-mount-path", $mountPath,
    "--environment-variables"
)

$containerCreateArgs += $envVars

if ($secureEnvVars.Count -gt 0) {
    $containerCreateArgs += @("--secure-environment-variables")
    $containerCreateArgs += $secureEnvVars
}

if ($ports.Count -gt 0) {
    $portValues = @()
    foreach ($port in $ports) {
        $portValues += "$($port.port)"
    }
    $containerCreateArgs += @("--ports")
    $containerCreateArgs += $portValues

    $firstProtocol = "$($ports[0].protocol)"
    if (-not $firstProtocol) { $firstProtocol = "UDP" }
    $containerCreateArgs += @("--protocol", $firstProtocol)
}

$containerCreateArgs += @("--location", $region)

if ($Game -eq "windrose") {
    $aciTemplate = Join-Path $env:TEMP "aci-$aciName-$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
    $portProtocols = ($ports | ForEach-Object { $_.protocol }) -join ","
    Write-Host "Creating Windrose ACI via container group YAML (port $WindroseDirectPort, protocol(s): $portProtocols)"
    if (($ports | Measure-Object).Count -gt 1) {
        $dupPorts = $ports | Group-Object port | Where-Object { $_.Count -gt 1 }
        if ($dupPorts) {
            Write-Error "ACI does not allow duplicate port numbers (e.g. TCP 3000 and UDP 3000). Use one protocol in games.windrose.ports or deploy Windrose on a VM."
        }
    }
    New-AciContainerGroupDeployFile `
        -OutputPath $aciTemplate `
        -ContainerGroupName $aciName `
        -Location $region `
        -Image $imageRef `
        -Cpu $cpu `
        -MemoryInGb $memoryInGb `
        -StorageAccountName $storageAccountName `
        -StorageAccountKey $storageKey `
        -FileShareName $fileShareName `
        -MountPath $mountPath `
        -RegistryServer $acrLoginServer `
        -RegistryUsername $registryUser `
        -RegistryPassword $registryPass `
        -Ports $ports `
        -EnvironmentVariables $envVars `
        -SecureEnvironmentVariables $secureEnvVars
    az container create --resource-group $resourceGroup --file $aciTemplate
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ACI template written to: $aciTemplate" -ForegroundColor Yellow
        Write-Error "Windrose ACI create failed (see Azure CLI output above)."
    }
    Remove-Item -Path $aciTemplate -Force -ErrorAction SilentlyContinue
} else {
    az @containerCreateArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "ACI create failed (see Azure CLI output above)."
    }
}

$ip = (az container show --resource-group $resourceGroup --name $aciName --query ipAddress.ip -o tsv 2>$null)
if (-not $ip) {
    Write-Error "Container group '$aciName' was not created or has no public IP."
}
$directPort = if ($Game -eq "windrose") { $WindroseDirectPort } else { if ($ports.Count -gt 0) { $ports[0].port } else { "" } }
Write-Host ""
Write-Host "=== $gameDisplayName server deployed ===" -ForegroundColor Green
Write-Host "Public IP: $ip"
if ($Game -eq "windrose") {
    Write-Host "Connect: Direct IP -> $ip port $directPort, password from -ServerPass / Key Vault"
    Write-Host "First start may take 15-30+ minutes (SteamCMD download + Wine prefix). Check: az container logs -g $resourceGroup -n $aciName --follow"
} elseif ($ports.Count -gt 0) {
    Write-Host "Connect in-game: Join by IP -> $ip (port $directPort)"
    Write-Host "Password: (the one you provided)"
}
Write-Host ""
