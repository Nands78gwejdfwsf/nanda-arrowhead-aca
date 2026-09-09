# What Was Fixed From the Previous POC

1. Resource group names were inconsistent between Bicep, deploy-lab.ps1 and GitHub workflows. The new platform uses one value: `NANDA-rg-arrowhead-aca-test`.
2. The old validation script was intentionally removed because validation is not part of this phase.
3. `main.json` was removed. Bicep is the IaC source of truth.
4. The unused `githubActionsContainerAppsResourceGroupRole.bicep` module was removed.
5. Hard-coded GitHub owner/repository IDs in the federated credential were removed. OIDC now uses the standard `repo:OWNER/REPOSITORY:ref:refs/heads/main` and `repo:OWNER/REPOSITORY:environment:production` subjects.
6. The old `onboardingtest` configuration pointed to files that did not exist. It was removed until a real third-application onboarding test is intentionally added.
7. The old deployment script mixed stale resource names and had bootstrap/validation assumptions tied to old resources. It was replaced with a clean foundation → Entra/secret bootstrap → runtime deployment flow.
8. The old ACA application ingress used `external: false`. For an internal ACA environment, that blocks normal VNet clients. The new apps use `external: true` while the environment itself remains internal-only.
9. The ACA storage and authentication modules now use the current namespaced Bicep deployment function `az.environment()`.
10. The old GitHub Actions workflow hard-coded the resource group and ACR names. The new workflow reads shared platform configuration from `platform.json`.
11. The old Job workflow hard-coded the PureOTA managed identity resource ID. The new workflow uses the Job's existing identity configuration and only updates the immutable image.
12. CI/CD failure notification was missing. The new pipeline creates a GitHub Issue on build, deployment, Job or promotion failure. This implements CI-7 using GitHub as the selected CI/CD notification channel.
13. Azure runtime alerts and CI/CD notifications are kept separate. Azure Monitor handles runtime/platform alerts; GitHub handles pipeline failures.
14. Required Azure Monitor alert coverage was expanded to include ACA revision provisioning failures, health/readiness failures, restart loops, Key Vault denied access, PostgreSQL connection/storage saturation and Azure Files capacity/bandwidth saturation.
15. PostgreSQL, Azure Files, backup policy, Key Vault audit logging and budget configuration are now part of the modular platform deployment.
16. The two dummy applications remain deliberately simple. They are a platform bootstrap, not a claim that the real PureOTA application acceptance tests are complete.


## Final deployment fixes
- Budget now supplies the required monthly timePeriod.startDate (first day of the current month).
- GitHub OIDC federated credentials are serialized under the same user-assigned identity to avoid concurrent-write conflicts.
