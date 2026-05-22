# Deploy game servers (Valheim/Windrose) to Azure Container Instances (ACI).
# Prerequisites: Azure CLI (az), Docker, logged in to Azure (az login).
# Usage: .\deploy-valheim-aci.ps1 -Game "valheim" -UserName "kk" -ServerName "My Server" -WorldName "Dedicated" -ServerPass "YourPassword"
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
    [switch]$PinVersion
)

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
    if ($WorldName) {
        $envVars += "WORLD_NAME=$WorldName"
    }
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

az @containerCreateArgs

$ip = (az container show --resource-group $resourceGroup --name $aciName --query ipAddress.ip -o tsv)
Write-Host ""
Write-Host "=== $gameDisplayName server deployed ===" -ForegroundColor Green
Write-Host "Public IP: $ip"
if ($ports.Count -gt 0) {
    Write-Host "Connect in-game: Join by IP -> $ip (port $($ports[0].port))"
}
if ($Game -eq "valheim") {
    Write-Host "Password: (the one you provided)"
}
Write-Host ""
