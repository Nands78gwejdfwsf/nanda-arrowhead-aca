# Backup Baseline

## PostgreSQL

PostgreSQL Flexible Server is configured with 7 days of point-in-time recovery retention for the POC.

A restore and data verification demonstration remains an acceptance activity once the real application schema/data is available.

## Azure Files

A Recovery Services vault and daily Azure Files policy with 30-day retention are deployed by Bicep. The deployment script then enables protection for the `pureota-data` share.

The script uses the Azure CLI Azure Files protection command because the protection association is an operational configuration over the already-provisioned vault, policy and file share.

A file-share restore demonstration remains an acceptance activity.
