param (
    [int]$ExpiringInDays = 15,
    [int]$TooLongThreshold = 180
)

$ErrorActionPreference = "Stop"
$currentDate = Get-Date

Import-Module Az.Accounts, Az.KeyVault, Az.Resources -ErrorAction Stop
Connect-AzAccount -Identity

$keyVaultName = (Get-AzKeyVault | Where-Object { $_.VaultName -like "*-kv" }).VaultName
$clientSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "automation-01-secret").SecretValueText
$workspaceKey = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "workspace-secret").SecretValueText
$workspaceId = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "workspace-id").SecretValueText

$secureSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
$clientId = (Get-AzContext).Account.Id
$tenantId = (Get-AzContext).Tenant.Id
$psCredential = New-Object System.Management.Automation.PSCredential ($clientId, $secureSecret)
Connect-AzAccount -ServicePrincipal -Credential $psCredential -TenantId $tenantId -ErrorAction Stop

function Send-CustomLogToLogAnalytics {
    param (
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$LogType,
        [PSObject]$LogData
    )

    $json = $LogData | ConvertTo-Json -Depth 5 -Compress
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
        "Log-Type"             = "AppSecretExpiry"
        "x-ms-date"            = $date
        "time-generated-field" = "TimeGenerated"
    }

    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
}

$apps = Get-AzADApplication
foreach ($app in $apps) {
    $secrets = Get-AzADAppCredential -ApplicationId $app.AppId
    foreach ($secret in $secrets) {
        $daysRemaining = ($secret.EndDateTime - $currentDate).Days
        if ($daysRemaining -le $ExpiringInDays) {
            $logRecord = [PSCustomObject]@{
                TimeGenerated = $currentDate
                AppName       = $app.DisplayName
                AppId         = $app.AppId
                SecretId      = $secret.KeyId
                Expiration    = $secret.EndDateTime
                DaysRemaining = $daysRemaining
                Status        = "ExpiringSoon"
            }
            Send-CustomLogToLogAnalytics -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AppSecretExpiry" -LogData $logRecord
        }
    }
}
