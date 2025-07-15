# 🔐 Azure App Registration Secret Ops

This project provides a fully automated solution to monitor, rotate, store, and report on Azure App Registration secrets. It uses PowerShell and Azure services like Automation Accounts, Key Vault, Log Analytics, and Storage Accounts to enforce secure practices around application secrets.

---

## 🚀 Features

- Detect secrets expiring in less than 15 days and notify admins
- Automatically rotate secrets 30 days before expiration
- Store rotated secrets securely in Azure Key Vault
- Send logs to Log Analytics for alerting and analysis
- Upload daily secret health reports (CSV) to Blob Storage
- Deploy everything with one command (PowerShell or Bash)

---

## 📦 Folder Structure

```
azure-appreg-secrets-ops/
│
├── deploy/                 # Scripts to deploy all required Azure resources
│   ├── deploy.ps1          # PowerShell deployment script
│   └── deploy.sh           # Bash deployment script
│
├── scripts/                # Main logic for monitoring and rotating secrets
│   ├── monitor-secrets.ps1
│   └── rotate-secrets.ps1
│
├── docs/                   # Diagrams, architecture images, etc.
│
├── LICENSE
└── README.md
```

---

## 🔧 Prerequisites

Before deploying, ensure the following:

- You have **Owner or Contributor + User Access Administrator** on the subscription
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) or [Az PowerShell](https://learn.microsoft.com/en-us/powershell/azure/install-az-ps) installed
- You are logged in (`az login` or `Connect-AzAccount`)
- You have a preferred project prefix (used to name resources)

---

## 🚀 Deployment

You can deploy the solution with one of the following scripts.

### 🟦 PowerShell

```powershell
.\deploy\deploy.ps1 -SubscriptionId "<your-subscription-id>" -ProjectPrefix "myproj"
```

### 🐧 Bash (Linux/macOS/Cloud Shell)

```bash
./deploy/deploy.sh <your-subscription-id> myproj
```

> You can omit `<your-subscription-id>` to use the currently logged-in subscription.

---

## 📊 Log Data

This solution generates logs and reports from both monitoring and rotation operations.

| **Table Name**           | **Source Script**       | **Description**                                                    |
|--------------------------|-------------------------|--------------------------------------------------------------------|
| `AppSecretRotation_CL`   | `rotate-secrets.ps1`     | Logs new secret creation 30 days before expiration                 |
| `AppSecretExpiry_CL`     | `monitor-secrets.ps1`    | Logs secrets expiring within 15 days                               |
| CSV Blob Reports         | Both scripts             | Full daily secret status report uploaded to blob storage           |

---

## 📄 CSV Report Format

Reports are generated daily and stored in Azure Storage as CSV files.

**Path format:**

```
https://<storage-account>.blob.core.windows.net/<container>/AppSecretsReport_YYYYMMDD_HHMMSS.csv
```

**Example row:**

```csv
AppName,AppId,SecretId,ExpirationDate,DaysRemaining,Status
my-api,12345,abcdefg,2025-08-01,30,ExpiringIn30Days
```

---

## 🚨 Alerts

This solution defines two log-based alerts in Azure Monitor:

### 🔁 AppRegistrationSecretRotationNotice

- **Query**: `AppSecretRotation_CL | where DaysRemaining_d == 30 | where Status_s == "ExpiringIn30Days"`
- **Purpose**: Detects secrets that were automatically rotated 30 days before expiration
- **Action**: Send email (or integration) to trigger ticket creation or notify the DevOps team

### ⏰ AppRegistrationSecretExpiryNotice

- **Query**: `AppSecretExpiry_CL | where DaysRemaining_d <= 15 | where Status_s == "ExpiringSoon"`
- **Purpose**: Detects secrets expiring soon that were not rotated automatically
- **Action**: Notify admins for manual intervention

---

## 📂 Daily Secret Status Report

The `monitor-secrets.ps1` script uploads a full report daily, showing the status of each App Registration secret.

Statuses:

- `Expired`: Already expired
- `ExpiringSoon`: Less than or equal to 15 days remaining
- `Good`: Valid between 16 and 180 days
- `TooLongExpiration`: Valid for more than 180 days

---

## 🛠️ Implementation Details

### Required Azure Resources:

- Azure Automation Account (System-Assigned Managed Identity)
- Azure Key Vault (secrets: automation SP, workspace secret, workspace ID)
- Azure Log Analytics Workspace
- Azure Storage Account with container for CSV reports

### Key Vault Secrets Required:

| Secret Name            | Description                                |
|------------------------|--------------------------------------------|
| `automation-01-secret` | Secret value for Automation Service Principal |
| `workspace-secret`     | Shared key for Log Analytics                |
| `workspace-id`         | Workspace ID                                |

---

## 🧪 How It Works

1. `monitor-secrets.ps1` scans secrets, logs expiring ones to Log Analytics, uploads full CSV to blob
2. `rotate-secrets.ps1` checks secrets, rotates if 30 days remaining, logs event, stores secret in Key Vault
3. Azure Monitor alerts trigger notifications when logs are written
4. Alerts can connect to Action Groups to integrate with email or ticketing systems

---

## 📃 License

MIT License. See [LICENSE](./LICENSE) for details.

---

## 🤝 Contributions

Pull requests are welcome. Please open an issue first to discuss what you’d like to change.

---

## 👤 Author

Created by Andrey Krasikov (https://github.com/net9876)
