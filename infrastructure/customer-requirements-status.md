# Customer Requirement Status - POC Platform Baseline

| Requirement | Current POC implementation |
|---|---|
| REG-1 | Single Premium ACR deployed by Bicep |
| REG-2 | Premium SKU selected; private endpoint deployed; public access retained for GitHub-hosted CI during POC |
| REG-3 | GitHub pipeline tags images with full Git commit SHA; bootstrap images are temporary only |
| REG-4 | ACR admin disabled; managed identities used for ACR pull/push |
| REG-5 | ACR retention policy configured for 30 days |
| REG-6 | Microsoft Defender for Containers vulnerability assessment configured |
| REG-7 | ACR private endpoint/DNS deployed; ACR remains reachable to GitHub-hosted runners |
| CI-1 | GitHub Actions workflow |
| CI-2 | GitHub-hosted runners + Azure OIDC |
| CI-3 | Push to main; production approval implemented |
| CI-4 | Application behavior driven by apps/apps.json |
| CI-5 | New revision health gate before promotion |
| CI-6 | Full-SHA rollback workflow |
| CI-7 | GitHub Issue notification on CI/CD failure; Azure Monitor uses email action group |
| CI-8 | No self-hosted runner required for ACA pipeline |
| CI-9 | PureOTA uses an ACA Job |
| CI-10 | No secret values are written into source or image layers |
| CI-11 | Old revision stays at 100% while new revision is validated |
| CI-12 | Migration pattern remains to be implemented when the real application/database schema is available |
| KV-1..KV-8 | Key Vault RBAC, soft delete, purge protection and Log Analytics audit are configured |
| KV-9 | Private endpoint is optional until Arrowhead approves DNS/network design |
| KV-10 | Break-glass procedure is documentation work for handoff |
| KV-11 | deploy-lab.ps1 demonstrates .env-to-Key-Vault bootstrap pattern for platform secrets |
| DATA-2..DATA-6 | Managed PostgreSQL with Entra auth, private access and backup retention |
| DATA-7..DATA-10 | Private Azure Files share, persistent ACA mount and Azure Backup policy |
| DATA-11 | Dummy applications pinned to one replica in IaC |
| DATA-12 | Dummy applications do not use session state |
| AUTH-1..AUTH-4 | Easy Auth + dedicated group authorization implemented for both dummy apps |
| AUTH-5 | Entra P1+ licensing must be confirmed by Arrowhead IT |
| NET-1 | Internal ACA environment |
| NET-2 | Azure Private DNS zones provisioned; corporate SANDC01 integration remains customer action |
| NET-3 | ACA subnet is /23 and PE subnet is /24 |
| NET-4 | Host-independent ACA default domain is used for POC; final corporate hostname remains to be selected |
| NET-5 | ACA managed ingress provides TLS; custom certificate/domain automation is deferred until final hostname is selected |
| NET-6 | Cato is intentionally deferred per POC instruction |
| NET-7 | Caddy is not used by ACA applications |
| NET-8 | Retained AZDKR01 workloads are outside this POC repository |
| IAC-1..IAC-5 | Azure resources are defined in Bicep modules; secret values are populated separately by deploy-lab.ps1 |
| OBS-1 | ACA and Key Vault logs flow to Log Analytics |
| OBS-2 | Required alert categories are configured in monitoring.bicep |
| OBS-3 | Log Analytics workspace is the operational log source |
| OBS-4 | Monthly RG budget plus cost-view documentation provided |

## Deliberately deferred

The real PureOTA application, managed database schema/migrations, realistic concurrent write testing, PITR restore demonstration, file restore demonstration, secret rotation demonstration, third-application onboarding and final corporate DNS/Cato integration require the actual application and customer network inputs.
