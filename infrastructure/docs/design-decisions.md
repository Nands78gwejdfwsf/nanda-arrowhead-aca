# POC Design Decisions

These are the current POC recommendations. They can be revisited during production design signoff.

## ACA environment type

Use an internal VNet-integrated Container Apps environment. The POC uses the default consumption-style ACA environment because the reference workloads are small and intermittent. A workload-profile environment should be reconsidered if sustained dedicated compute or specialized profiles are required.

## Database

Use Azure Database for PostgreSQL Flexible Server as the standard relational service. The POC uses a small Burstable tier and 32 GB storage only as a lab baseline. Production sizing must follow DATA-1 workload information.

For the first reference applications, use one PostgreSQL server with a separate database per application if the workload is small. Do not grant one application identity access to another application's database. Move to dedicated servers when isolation, performance or noisy-neighbor requirements justify the cost.

## File storage

Use Azure Files SMB for the PureOTA persistent share because the current reference pattern is a mounted filesystem. The POC uses a 100 GB Standard TransactionOptimized share as a baseline. Large/read-mostly scientific datasets should be evaluated for direct object storage access before production sizing.

## Key Vault topology

Use one platform Key Vault per environment for the POC, with secret-level RBAC grants to each application identity. This keeps operational overhead low while limiting cross-application access. A production split by environment or trust boundary can be introduced if blast-radius requirements increase.

## CI/CD approval

Use a GitHub `production` Environment approval gate between revision health validation and traffic promotion. This gives Arrowhead an explicit control point while keeping build and validation automated.

## Database migrations

For the real application, use a dedicated ACA Job for schema migrations when migrations are compatible with the rolling deployment pattern. The migration job must run before promotion when the new application requires the new schema. The exact migration ordering will be finalized with the real application's schema.

## Hostname

Prefer a host-independent corporate application domain instead of `<app>.azdkr01.thearcnet.com`. The POC uses ACA's generated internal-environment FQDN until Arrowhead IT provides the final DNS design.

## Authorization

Use ACA built-in authentication with Microsoft Entra ID, `user assignment required` at the enterprise application, and exactly one dedicated security group per application. The POC uses this pattern for PureOTA and HelixBridge.

## Caddy

Caddy is unnecessary for the ACA applications because ACA internal ingress terminates TLS and provides per-application FQDNs. Caddy remains relevant only to workloads that stay on AZDKR01.
