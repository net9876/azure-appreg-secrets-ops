param (
    [int]$ExpiringInDays = 30,
    [int]$ExpirationDays = 180,
    [switch]$WhatIfOnly,
    [string]$KeyVaultName = $env:APPREGOPS_KEYVAULT_NAME,
    [string]$WorkspaceId = $env:APPREGOPS_WORKSPACE_ID,
    [string]$WorkspaceKey = $env:APPREGOPS_WORKSPACE_KEY,
    [string]$SecretNamePrefix = $env:APPREGOPS_SECRET_NAME_PREFIX
)

$ErrorActionPreference = "Stop"
$currentDate = Get-Date

Import-Module Az.Accounts, Az.Resources, Az.KeyVault -ErrorAction Stop

function Get-RequiredValue {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required value: $Name. Set it as a parameter, environment variable, or Automation variable."
    }
    return $Value
}

function Get-AutomationOrEnvValue {
    param([string]$Name, [string]$Fallback)
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback }
    try { return Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { return $null }
}

function ConvertTo-SafeKeyVaultSecretName {
    param([string]$Name)
    $safe = $Name.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $safe = $safe -replace '-+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "app-registration" }
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80).Trim('-') }
    return $safe
}

function Send-CustomLogToLogAnalytics {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$WorkspaceKey,
        [Parameter(Mandatory = $true)][string]$LogType,
        [Parameter(Mandatory = $true)][PSObject]$LogData
    )

    $json = $LogData | ConvertTo-Json -Depth 10 -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $date = Get-Date -Format "r"
    $stringToHash = "POST`n$($body.Length)`napplication/json`nx-ms-date:$date`n/api/logs"
    $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $hmacsha256 = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha256.Key = $keyBytes
    $hashedBytes = $hmacsha256.ComputeHash($bytesToHash)
    $signature = [Convert]::ToBase64String($hashedBytes)
    $authHeader = "SharedKey ${WorkspaceId}:${signature}"

    $uri = "https://${WorkspaceId}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    $headers = @{
        "Authorization"        = $authHeader
        "Log-Type"             = $LogType
        "x-ms-date"            = $date
        "time-generated-field" = "TimeGenerated"
    }

    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
}

if (-not (Get-AzContext)) {
    try { Connect-AzAccount -Identity -ErrorAction Stop }
    catch { throw "No Azure context found and managed identity login failed. Run Connect-AzAccount locally or execute from Azure Automation with managed identity." }
}

$KeyVaultName = Get-AutomationOrEnvValue -Name "APPREGOPS_KEYVAULT_NAME" -Fallback $KeyVaultName
$WorkspaceId = Get-AutomationOrEnvValue -Name "APPREGOPS_WORKSPACE_ID" -Fallback $WorkspaceId
$WorkspaceKey = Get-AutomationOrEnvValue -Name "APPREGOPS_WORKSPACE_KEY" -Fallback $WorkspaceKey
$SecretNamePrefix = Get-AutomationOrEnvValue -Name "APPREGOPS_SECRET_NAME_PREFIX" -Fallback $SecretNamePrefix

$KeyVaultName = Get-RequiredValue -Name "APPREGOPS_KEYVAULT_NAME" -Value $KeyVaultName
$WorkspaceId = Get-RequiredValue -Name "APPREGOPS_WORKSPACE_ID" -Value $WorkspaceId
$WorkspaceKey = Get-RequiredValue -Name "APPREGOPS_WORKSPACE_KEY" -Value $WorkspaceKey
if ([string]::IsNullOrWhiteSpace($SecretNamePrefix)) { $SecretNamePrefix = "appreg" }

$rotationDateLabel = $currentDate.ToString("yyyyMMdd")
$newCredentialDisplayName = "secret-$rotationDateLabel"
$startDate = $currentDate
$endDate = $startDate.AddDays($ExpirationDays)
$rotationResults = New-Object System.Collections.Generic.List[object]
$apps = Get-AzADApplication

foreach ($app in $apps) {
    $credentials = Get-AzADAppCredential -ApplicationId $app.AppId
    if ($credentials | Where-Object { $_.DisplayName -eq $newCredentialDisplayName }) { continue }

    $expiringCredentials = $credentials | Where-Object {
        $_.EndDateTime -and
        (($_.EndDateTime - $currentDate).Days -le $ExpiringInDays) -and
        (($_.EndDateTime - $currentDate).Days -ge 0)
    }

    if (-not $expiringCredentials) { continue }

    $oldestExpiringCredential = $expiringCredentials | Sort-Object EndDateTime | Select-Object -First 1
    $daysRemaining = ($oldestExpiringCredential.EndDateTime - $currentDate).Days
    $safeAppName = ConvertTo-SafeKeyVaultSecretName -Name $app.DisplayName
    $keyVaultSecretName = "$SecretNamePrefix-$safeAppName"

    $result = [PSCustomObject]@{
        TimeGenerated        = $currentDate.ToUniversalTime().ToString("o")
        AppName              = $app.DisplayName
        AppId                = $app.AppId
        OldSecretId          = $oldestExpiringCredential.KeyId
        OldExpiration        = $oldestExpiringCredential.EndDateTime.ToUniversalTime().ToString("o")
        DaysRemaining        = $daysRemaining
        NewSecretDisplayName = $newCredentialDisplayName
        NewExpiration        = $endDate.ToUniversalTime().ToString("o")
        KeyVaultName         = $KeyVaultName
        KeyVaultSecretName   = $keyVaultSecretName
        Status               = if ($WhatIfOnly) { "WhatIfOnly" } else { "RotationCompleted" }
        Note                 = "New secret created and stored in Key Vault. Old secret was not deleted. Consuming application must be updated separately."
    }

    if (-not $WhatIfOnly) {
        $passwordCredential = @{
            DisplayName   = $newCredentialDisplayName
            StartDateTime = $startDate
            EndDateTime   = $endDate
        }

        $newCredential = New-AzADAppCredential -ApplicationId $app.AppId -PasswordCredential $passwordCredential
        $newSecretValue = $newCredential.SecretText

        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $keyVaultSecretName -SecretValue (ConvertTo-SecureString $newSecretValue -AsPlainText -Force) -ContentType "AppRegistrationClientSecret" -Tag @{
            AppId = $app.AppId
            AppName = $app.DisplayName
            CreatedBy = "azure-appreg-secrets-ops"
            RotationDate = $rotationDateLabel
        } | Out-Null

        $result | Add-Member -MemberType NoteProperty -Name "NewSecretId" -Value $newCredential.KeyId -Force
        Send-CustomLogToLogAnalytics -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType "AppSecretRotation" -LogData $result
    }

    $rotationResults.Add($result)
}

$rotationResults | ConvertTo-Json -Depth 10
Write-Output "Rotation candidates processed: $($rotationResults.Count)"
Write-Output "Old secrets were not deleted."
Write-Output "Update consuming applications before removing old credentials."
