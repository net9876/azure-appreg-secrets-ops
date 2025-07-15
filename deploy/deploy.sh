#!/bin/bash

#!/bin/bash
set -e

SUBSCRIPTION_ID=${1:-""}
PROJECT_PREFIX=${2:-appregops}
LOCATION=${3:-eastus}

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  echo "ℹ️  Using current subscription: $SUBSCRIPTION_ID"
fi
az account set --subscription "$SUBSCRIPTION_ID"

RESOURCE_GROUP="$PROJECT_PREFIX-rg"
STORAGE_ACCOUNT="$(echo $PROJECT_PREFIX | tr -d '-')sa"
CONTAINER="appregsecreports"
KV_NAME="$PROJECT_PREFIX-kv"
LAW_NAME="$PROJECT_PREFIX-law"
AUTO_NAME="$PROJECT_PREFIX-auto"
ALERT_NAME="AppRegistrationSecretExpiring"
ACTION_GROUP_NAME="AppRegistrations_Admins"

az group create --name $RESOURCE_GROUP --location $LOCATION

az storage account create --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION --sku Standard_LRS --kind StorageV2

STORAGE_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT --query "[0].value" -o tsv)
az storage container create --name $CONTAINER --account-name $STORAGE_ACCOUNT --account-key $STORAGE_KEY

az keyvault create --name $KV_NAME --resource-group $RESOURCE_GROUP --location $LOCATION
az keyvault secret set --vault-name $KV_NAME --name automation-01-secret --value "placeholder"
az keyvault secret set --vault-name $KV_NAME --name workspace-secret --value "placeholder"
az keyvault secret set --vault-name $KV_NAME --name workspace-id --value "placeholder"

az monitor log-analytics workspace create --resource-group $RESOURCE_GROUP --workspace-name $LAW_NAME --location $LOCATION

az automation account create --name $AUTO_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --sku Basic

az automation account identity assign --name $AUTO_NAME --resource-group $RESOURCE_GROUP
IDENTITY_ID=$(az automation account show --name $AUTO_NAME --resource-group $RESOURCE_GROUP --query identity.principalId -o tsv)

az role assignment create --assignee $IDENTITY_ID --role "Reader"
az role assignment create --assignee $IDENTITY_ID --role "Key Vault Secrets User" --scope $(az keyvault show --name $KV_NAME --query id -o tsv)

# Create Action Group
AG_ID=$(az monitor action-group create --resource-group $RESOURCE_GROUP --name $ACTION_GROUP_NAME \
  --short-name "AppRegAdmin" \
  --action email admin1 admin@example.com --action email admin2 admin2@example.com \
  --query id -o tsv)

# Create Alert Rule
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group $RESOURCE_GROUP --workspace-name $LAW_NAME --query id -o tsv)
QUERY="AppSecretExpiry_CL
| where TimeGenerated between (startofday(now()) .. startofday(now() + 1d))
| where Status_s == \"ExpiringSoon\"
| where DaysRemaining_d <= 15
| summarize LatestTime = arg_max(TimeGenerated, *) by AppName_s
| summarize Count = count()
| where Count > 0"

az monitor scheduled-query create \
  --name $ALERT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --scopes $WORKSPACE_ID \
  --description "Alert when App Registration secret expires within 15 days" \
  --condition "count > 0" \
  --condition-query "$QUERY" \
  --severity 2 \
  --enabled true \
  --action $AG_ID \
  --frequency 1440 \
  --time-window 1440

echo "✅ All resources deployed, including alert rule."
