param (
    [string]$SubscriptionId,
    [string]$ProjectPrefix = "appregops",
    [string]$Location = "eastus",
    [string]$NotificationEmail = "admin@example.com"
)

$ErrorActionPreference = "Stop"

if (-not (Get-AzContext)) { Connect-AzAccount }

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}
else {
    $SubscriptionId = (Get-AzContext).Subscription.Id
    Write-Host "Using current subscription: $SubscriptionId"
}

$resourceGroup = "$ProjectPrefix-rg"
$storageAccount = "$($ProjectPrefix.Replace('-', '').ToLower())sa"
if ($storageAccount.Length -gt 24) { $storageAccount = $storageAccount.Substring(0, 24) }

$container = "appregsecreports"
$keyVaultName = "$ProjectPrefix-kv"
$workspaceName = "$ProjectPrefix-law"
$automationName = "$ProjectPrefix-auto"
$alertRuleName = "AppRegistrationSecretExpiring"
$actionGroupName = "AppRegistrations-Admins"

New-AzResourceGroup -Name $resourceGroup -Location $Location -Force | Out-Null

$storage = New-AzStorageAccount -Name $storageAccount -ResourceGroupName $resourceGroup -Location $Location -SkuName Standard_LRS -Kind StorageV2 -AllowBlobPublicAccess $false -MinimumTlsVersion TLS1_2
$storageCtx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
New-AzStorageContainer -Name $container -Context $storageCtx -Permission Off -ErrorAction SilentlyContinue | Out-Null

$keyVault = New-AzKeyVault -Name $keyVaultName -ResourceGroupName $resourceGroup -Location $Location -Sku Standard -EnablePurgeProtection

$workspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroup -Name $workspaceName -Location $Location -Sku PerGB2018
$workspaceKeys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $resourceGroup -Name $workspaceName

New-AzAutomationAccount -Name $automationName -Location $Location -ResourceGroupName $resourceGroup -Plan Basic | Out-Null
Set-AzAutomationAccount -Name $automationName -ResourceGroupName $resourceGroup -AssignSystemIdentity $true | Out-Null
$automationIdentity = (Get-AzAutomationAccount -ResourceGroupName $resourceGroup -Name $automationName).Identity.PrincipalId

New-AzRoleAssignment -ObjectId $automationIdentity -RoleDefinitionName "Reader" -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue | Out-Null
New-AzRoleAssignment -ObjectId $automationIdentity -RoleDefinitionName "Key Vault Secrets Officer" -Scope $keyVault.ResourceId -ErrorAction SilentlyContinue | Out-Null
New-AzRoleAssignment -ObjectId $automationIdentity -RoleDefinitionName "Storage Blob Data Contributor" -Scope $storage.Id -ErrorAction SilentlyContinue | Out-Null

$variables = @{
    APPREGOPS_KEYVAULT_NAME = $keyVaultName
    APPREGOPS_STORAGE_ACCOUNT_NAME = $storageAccount
    APPREGOPS_STORAGE_CONTAINER_NAME = $container
    APPREGOPS_WORKSPACE_ID = $workspace.CustomerId
    APPREGOPS_WORKSPACE_KEY = $workspaceKeys.PrimarySharedKey
    APPREGOPS_SECRET_NAME_PREFIX = "appreg"
}

foreach ($item in $variables.GetEnumerator()) {
    New-AzAutomationVariable -AutomationAccountName $automationName -ResourceGroupName $resourceGroup -Name $item.Key -Value $item.Value -Encrypted ($item.Key -eq "APPREGOPS_WORKSPACE_KEY") -ErrorAction SilentlyContinue | Out-Null
}

$emailReceiver = New-AzActionGroupReceiver -Name "admin" -EmailAddress $NotificationEmail
$actionGroup = Get-AzActionGroup -ResourceGroupName $resourceGroup -Name $actionGroupName -ErrorAction SilentlyContinue
if (-not $actionGroup) {
    $actionGroup = New-AzActionGroup -ResourceGroupName $resourceGroup -Name $actionGroupName -ShortName "AppRegOps" -Receiver $emailReceiver
}

$query = @"
AppSecretExpiry_CL
| where Status_s in ("Expired", "ExpiringSoon")
| summarize LatestTime = arg_max(TimeGenerated, *) by AppId_s, SecretId_g
| summarize Count = count()
| where Count > 0
"@

try {
    Add-AzLogAlertRuleV2 -Name $alertRuleName -ResourceGroupName $resourceGroup -Location $Location -TargetResourceId $workspace.ResourceId -WindowSize 1.00:00:00 -Frequency 1.00:00:00 -Severity 2 -Condition @(New-AzScheduledQueryRuleSource -Query $query -DataSourceId $workspace.ResourceId -QueryType "ResultCount") -ActionGroup $actionGroup.Id | Out-Null
}
catch {
    Write-Warning "Alert rule creation failed. Azure Monitor command syntax may differ by Az module version. Review and create alert manually if needed."
    Write-Warning $_.Exception.Message
}

Write-Host "Deployment complete."
Write-Host "Resource group: $resourceGroup"
Write-Host "Automation Account: $automationName"
Write-Host "Key Vault: $keyVaultName"
Write-Host "Storage Account: $storageAccount"
Write-Host "Container: $container"
Write-Host "Log Analytics Workspace: $workspaceName"
Write-Host "Next steps: import scripts as Automation runbooks, verify Graph permissions, test monitor runbook, then test rotation with -WhatIfOnly."
