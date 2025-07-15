param (
    [string]$SubscriptionId,
    [string]$ProjectPrefix = "appregops",
    [string]$Location = "eastus"
)

if (-not $SubscriptionId) {
    $SubscriptionId = (Get-AzContext).Subscription.Id
    Write-Host "ℹ️  Using current subscription: $SubscriptionId"
} else {
    Set-AzContext -SubscriptionId $SubscriptionId
}

$resourceGroup = "$ProjectPrefix-rg"
$storageAccount = "$($ProjectPrefix.Replace('-', ''))sa"
$container = "appregsecreports"
$keyVaultName = "$ProjectPrefix-kv"
$workspaceName = "$ProjectPrefix-law"
$automationName = "$ProjectPrefix-auto"
$alertRuleName = "AppRegistrationSecretExpiring"
$actionGroupName = "AppRegistrations_Admins"

if (-not (Get-AzContext)) {
    Connect-AzAccount
}

New-AzResourceGroup -Name $resourceGroup -Location $Location -Force

New-AzStorageAccount -Name $storageAccount -ResourceGroupName $resourceGroup -Location $Location `
    -SkuName Standard_LRS -Kind StorageV2 -AllowBlobPublicAccess $false

$storageCtx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
New-AzStorageContainer -Name $container -Context $storageCtx -Permission Off

New-AzKeyVault -Name $keyVaultName -ResourceGroupName $resourceGroup -Location $Location -Sku Standard

Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "automation-01-secret" -SecretValue (ConvertTo-SecureString "placeholder" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "workspace-secret" -SecretValue (ConvertTo-SecureString "placeholder" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "workspace-id" -SecretValue (ConvertTo-SecureString "placeholder" -AsPlainText -Force)

$workspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroup -Name $workspaceName -Location $Location -Sku PerGB2018

New-AzAutomationAccount -Name $automationName -Location $Location -ResourceGroupName $resourceGroup -Plan Basic

Set-AzAutomationAccount -Name $automationName -ResourceGroupName $resourceGroup -AssignSystemIdentity $true

$automationIdentity = (Get-AzAutomationAccount -ResourceGroupName $resourceGroup -Name $automationName).Identity.PrincipalId

New-AzRoleAssignment -ObjectId $automationIdentity -RoleDefinitionName "Reader" -Scope "/subscriptions/$((Get-AzContext).Subscription.Id)"
New-AzRoleAssignment -ObjectId $automationIdentity -RoleDefinitionName "Key Vault Secrets User" -Scope (Get-AzKeyVault -VaultName $keyVaultName).ResourceId

# Create Action Group (if not exists)
$existingAG = Get-AzActionGroup -ResourceGroupName $resourceGroup -Name $actionGroupName -ErrorAction SilentlyContinue
if (-not $existingAG) {
    $email1 = New-AzActionGroupReceiver -Name "admin1" -EmailAddress "admin@example.com"
    $email2 = New-AzActionGroupReceiver -Name "admin2" -EmailAddress "admin2@example.com"
    $existingAG = New-AzActionGroup -ResourceGroupName $resourceGroup -Name $actionGroupName -ShortName "AppRegAdmin" -Receiver $email1, $email2
}

# Create Alert Rule
$query = @"
AppSecretExpiry_CL
| where TimeGenerated between (startofday(now()) .. startofday(now() + 1d))
| where Status_s == "ExpiringSoon"
| where DaysRemaining_d <= 15
| summarize LatestTime = arg_max(TimeGenerated, *) by AppName_s
| summarize Count = count()
| where Count > 0
"@

Add-AzLogAlertRuleV2 -Name $alertRuleName -ResourceGroupName $resourceGroup `
    -Location $Location -TargetResourceId $workspace.ResourceId `
    -WindowSize 1.00:00:00 -Frequency 1.00:00:00 -Severity 2 `
    -Condition @(New-AzScheduledQueryRuleSource -Query $query -DataSourceId $workspace.ResourceId -QueryType "ResultCount") `
    -ActionGroup $existingAG.Id

Write-Host "✅ Deployment complete with Log Analytics alert rule."
