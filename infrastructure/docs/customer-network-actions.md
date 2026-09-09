# Customer Network Actions

These actions are intentionally outside the Azure deployment script.

## SANDC01 / corporate DNS

Arrowhead IT must integrate the ACA private DNS/hostname resolution with SANDC01 so corporate clients can resolve the selected application hostnames.

The final hostname scheme is not hard-coded in this POC. The preferred production direction is a host-independent application domain rather than `<app>.azdkr01.thearcnet.com`.

## Cato SASE

Cato is intentionally deferred for this POC. Before production use, Arrowhead IT should validate or create the required TLS-inspection bypasses for:

- OIDC callback path
- ACR
- Key Vault
- PostgreSQL private endpoint
- ACA ingress
