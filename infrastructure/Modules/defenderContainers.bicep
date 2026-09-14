targetScope = 'subscription'
param enabled bool = true

resource pricing 'Microsoft.Security/pricings@2025-10-01-preview' = {
  name: 'Containers'
  properties: {
    pricingTier: enabled ? 'Standard' : 'Free'
    extensions: enabled ? [
      { name: 'ContainerRegistriesVulnerabilityAssessments'
isEnabled: 'True' }
    ] : []
  }
}
