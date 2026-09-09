# Cost View

The POC creates a resource-group monthly budget with 80% and 100% actual-spend notifications.

For the customer cost view, use Azure Cost Management > Cost analysis and filter to:

- Resource group: `NANDA-rg-arrowhead-aca-test`

Review these resource families separately:

- Container Apps environment and apps
- Azure Container Registry
- Key Vault
- PostgreSQL Flexible Server
- Storage Account / Azure Files
- Recovery Services Vault
- Log Analytics

This keeps the platform spend distinguishable from unrelated subscription resources.
