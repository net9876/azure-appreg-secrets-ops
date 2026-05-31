#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${1:-}"
PROJECT_PREFIX="${2:-appregops}"
LOCATION="${3:-eastus}"
NOTIFICATION_EMAIL="${4:-admin@example.com}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  echo "Using current subscription: $SUBSCRIPTION_ID"
fi

az account set --subscription "$SUBSCRIPTION_ID"

RESOURCE_GROUP="${PROJECT_PREFIX}-rg"
STORAGE_ACCOUNT="$(echo "${PROJECT_PREFIX}" | tr -d '-' | tr '[:upper:]' '[:lower:]')sa"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"
CONTAINER="appregsecreports"
KV_NAME="${PROJECT_PREFIX}-kv"
LAW_NAME="${PROJECT_PREFIX}-law"
AUTO_NAME="${PROJECT_PREFIX}-auto"
ALERT_NAME="AppRegistrationSecretExpiring"
ACTION_GROUP_NAME="AppRegistrations-Admins"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

az storage account create --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false -o none
STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "[0].value" -o tsv)
az storage container create --name "$CONTAINER" --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" -o none

az keyvault create --name "$KV_NAME" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --enable-purge-protection true -o none
az monitor log-analytics workspace create --resource-group "$RESOURCE_GROUP" --workspace-name "$LAW_NAME" --location "$LOCATION" -o none

WORKSPACE_CUSTOMER_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" --workspace-name "$LAW_NAME" --query customerId -o tsv)
WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" --workspace-name "$LAW_NAME" --query id -o tsv)

az automation account create --name "$AUTO_NAME" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --sku Basic -o none
az automation account identity assign --name "$AUTO_NAME" --resource-group "$RESOURCE_GROUP" -o none
IDENTITY_ID=$(az automation account show --name "$AUTO_NAME" --resource-group "$RESOURCE_GROUP" --query identity.principalId -o tsv)

az role assignment create --assignee "$IDENTITY_ID" --role "Reader" --scope "/subscriptions/${SUBSCRIPTION_ID}" -o none || true
KV_ID=$(az keyvault show --name "$KV_NAME" --query id -o tsv)
STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create --assignee "$IDENTITY_ID" --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none || true
az role assignment create --assignee "$IDENTITY_ID" --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" -o none || true

AG_ID=$(az monitor action-group create --resource-group "$RESOURCE_GROUP" --name "$ACTION_GROUP_NAME" --short-name "AppRegOps" --action email admin "$NOTIFICATION_EMAIL" --query id -o tsv)

QUERY='AppSecretExpiry_CL
| where Status_s in ("Expired", "ExpiringSoon")
| summarize LatestTime = arg_max(TimeGenerated, *) by AppId_s, SecretId_g
| summarize Count = count()
| where Count > 0'

az monitor scheduled-query create --name "$ALERT_NAME" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --scopes "$WORKSPACE_RESOURCE_ID" --description "Alert when App Registration secrets are expired or expiring soon" --condition "count > 0" --condition-query "$QUERY" --severity 2 --enabled true --action "$AG_ID" --frequency 1440 --time-window 1440 || echo "Alert creation failed. Review Azure CLI scheduled-query syntax for your CLI version."

cat <<EOF
Deployment complete.

Resource group: $RESOURCE_GROUP
Automation Account: $AUTO_NAME
Key Vault: $KV_NAME
Storage Account: $STORAGE_ACCOUNT
Container: $CONTAINER
Log Analytics Workspace: $LAW_NAME
Workspace customer ID: $WORKSPACE_CUSTOMER_ID

Next steps:
1. Import scripts/monitor-secrets.ps1 and scripts/rotate-secrets.ps1 as PowerShell runbooks.
2. Verify managed identity permissions for Microsoft Graph / App Registration read and credential write operations.
3. Test monitor-secrets.ps1 before enabling rotation.
4. Use rotate-secrets.ps1 -WhatIfOnly before real rotation.
EOF
