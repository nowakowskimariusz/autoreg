# This file runs once when the PowerShell worker starts (cold start).
# It signs in with the Function App's system-assigned managed identity so
# every function invocation already has an authenticated Az context.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
}

# Reduce noisy change/upgrade warnings in the logs.
$env:SuppressAzurePowerShellBreakingChangeWarnings = 'true'
Set-Item Env:\AZURE_HTTP_USER_AGENT 'az-fx-dns-registrar'
