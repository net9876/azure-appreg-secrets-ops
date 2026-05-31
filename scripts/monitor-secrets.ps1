param (
    [int]$ExpiringInDays = 15,
    [int]$TooLongThreshold = 180,
    [string]$ReportContainerName = $env:APPREGOPS_STORAGE_CONTAINER_NAME,
    [string]$StorageAccountName = $env:APPREGOPS_STORAGE_ACCOUNT_NAME,
    [string]$WorkspaceId = $env:APPREGOPS_WORKSPACE_ID,
    [string]$WorkspaceKey = $env:APPREGOPS_WORKSPACE_KEY
)

$ErrorActionPreference = "Stop"
$currentDate = Get-Date

Import-Module Az.Accounts, Az.Resources, Az.Storage -ErrorAction Stop

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

function Get-SecretStatus {
    param([Nullable[DateTime]]$EndDateTime, [int]$ExpiringInDays, [int]$TooLongThreshold)
    if (-not $EndDateTime) { return "Unknown" }
    $daysRemaining = ($EndDateTime - (Get-Date)).Days
    if ($daysRemaining -lt 0) { return "Expired" }
    if ($daysRemaining -le $ExpiringInDays) { return "ExpiringSoon" }
    if ($daysRemaining -gt $TooLongThreshold) { return "TooLongExpiration" }
    return "Good"
}

if (-not (Get-AzContext)) {
    try { Connect-AzAccount -Identity -ErrorAction Stop }
    catch { throw "No Azure context found and managed identity login failed. Run Connect-AzAccount locally or execute from Azure Automation with managed identity." }
}

$StorageAccountName = Get-AutomationOrEnvValue -Name "APPREGOPS_STORAGE_ACCOUNT_NAME" -Fallback $StorageAccountName
$ReportContainerName = Get-AutomationOrEnvValue -Name "APPREGOPS_STORAGE_CONTAINER_NAME" -Fallback $ReportContainerName
$WorkspaceId = Get-AutomationOrEnvValue -Name "APPREGOPS_WORKSPACE_ID" -Fallback $WorkspaceId
$WorkspaceKey = Get-AutomationOrEnvValue -Name "APPREGOPS_WORKSPACE_KEY" -Fallback $WorkspaceKey

$StorageAccountName = Get-RequiredValue -Name "APPREGOPS_STORAGE_ACCOUNT_NAME" -Value $StorageAccountName
$ReportContainerName = Get-RequiredValue -Name "APPREGOPS_STORAGE_CONTAINER_NAME" -Value $ReportContainerName
$WorkspaceId = Get-RequiredValue -Name "APPREGOPS_WORKSPACE_ID" -Value $WorkspaceId
$WorkspaceKey = Get-RequiredValue -Name "APPREGOPS_WORKSPACE_KEY" -Value $WorkspaceKey

$reportRows = New-Object System.Collections.Generic.List[object]
$apps = Get-AzADApplication

foreach ($app in $apps) {
    $credentials = Get-AzADAppCredential -ApplicationId $app.AppId
    foreach ($credential in $credentials) {
        $daysRemaining = if ($credential.EndDateTime) { ($credential.EndDateTime - $currentDate).Days } else { $null }
        $status = Get-SecretStatus -EndDateTime $credential.EndDateTime -ExpiringInDays $ExpiringInDays -TooLongThreshold $TooLongThreshold

        $record = [PSCustomObject]@{
            TimeGenerated  = $currentDate.ToUniversalTime().ToString("o")
            AppName        = $app.DisplayName
            AppId          = $app.AppId
            SecretId       = $credential.KeyId
            ExpirationDate = if ($credential.EndDateTime) { $credential.EndDateTime.ToUniversalTime().ToString("o") } else { $null }
            DaysRemaining  = $daysRemaining
            Status         = $status
        }

        $reportRows.Add($record)
        if ($status -in @("Expired", "ExpiringSoon", "TooLongExpiration")) {
            Send-CustomLogToLogAnalytics -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType "AppSecretExpiry" -LogData $record
        }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempReportPath = Join-Path $env:TEMP "AppSecretsReport_$timestamp.csv"
$reportRows | Sort-Object Status, DaysRemaining, AppName | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $tempReportPath

$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
Set-AzStorageBlobContent -File $tempReportPath -Container $ReportContainerName -Blob "reports/AppSecretsReport_$timestamp.csv" -Context $storageContext -Force | Out-Null

Write-Output "Completed App Registration secret monitoring."
Write-Output "Applications scanned: $($apps.Count)"
Write-Output "Secret records found: $($reportRows.Count)"
Write-Output "Report uploaded: reports/AppSecretsReport_$timestamp.csv"
