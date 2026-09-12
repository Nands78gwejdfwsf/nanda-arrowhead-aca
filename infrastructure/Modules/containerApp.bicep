param name string
param location string
param environmentId string
param image string
param containerPort int = 8080
param minReplicas int = 1
param maxReplicas int = 1
param identityId string
param githubActionsPrincipalId string = ''
param acrLoginServer string
param keyVaultName string = ''
param keyVaultSecretName string = ''
param enableKeyVaultSecret bool = false
param enableAzureFile bool = false
param azureFileStorageName string = ''
param azureFileMountPath string = '/mnt/data'
param healthPath string = '/healthz'
param postgresHost string = ''
param postgresDatabase string = ''
param postgresUser string = ''
param postgresClientId string = ''

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Multiple'
      registries: [
        {
          server: acrLoginServer
          identity: identityId
        }
      ]
      secrets: enableKeyVaultSecret ? [
        {
          name: keyVaultSecretName
          identity: identityId
          keyVaultUrl: 'https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/secrets/${keyVaultSecretName}'
        }
      ] : []
      ingress: {
        external: true
        targetPort: containerPort
        transport: 'Auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: name
          image: image
          env: !empty(postgresHost) ? [
            { name: 'PGHOST', value: postgresHost }
            { name: 'PGPORT', value: '5432' }
            { name: 'PGDATABASE', value: postgresDatabase }
            { name: 'PGUSER', value: postgresUser }
            { name: 'PGSSLMODE', value: 'require' }
            { name: 'IDENTITY_CLIENT_ID', value: postgresClientId }
          ] : []
          resources: { cpu: json('0.25')
memory: '0.5Gi' }
          volumeMounts: enableAzureFile ? [
            { volumeName: 'persistent-data'
mountPath: azureFileMountPath }
          ] : []
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: healthPath
port: containerPort }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: healthPath
port: containerPort }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: { minReplicas: minReplicas
maxReplicas: maxReplicas }
      volumes: enableAzureFile ? [
        { name: 'persistent-data'
storageType: 'AzureFile'
storageName: azureFileStorageName }
      ] : []
    }
  }
}


resource githubAppContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(githubActionsPrincipalId)) {
  name: guid(app.id, githubActionsPrincipalId, '358470bc-b998-42bd-ab17-a7e34c199c0f')
  scope: app
  properties: {
    principalId: githubActionsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '358470bc-b998-42bd-ab17-a7e34c199c0f')
  }
}

output id string = app.id
output name string = app.name
