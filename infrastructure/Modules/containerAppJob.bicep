param name string
param location string
param environmentId string
param image string
param identityId string
param githubActionsPrincipalId string = ''
param acrLoginServer string
param storageName string
param command string

resource job 'Microsoft.App/jobs@2025-10-02-preview' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Manual'
      registries: [
        { server: acrLoginServer
identity: identityId }
      ]
      manualTriggerConfig: { parallelism: 1
replicaCompletionCount: 1 }
      replicaRetryLimit: 1
      replicaTimeout: 300
    }
    template: {
      containers: [
        {
          name: name
          image: image
          command: ['/bin/sh', '-c']
          args: [command]
          resources: { cpu: json('0.25')
memory: '0.5Gi' }
          volumeMounts: [
            { volumeName: 'persistent-data'
mountPath: '/mnt/tier-data' }
          ]
        }
      ]
      volumes: [
        { name: 'persistent-data'
storageType: 'AzureFile'
storageName: storageName }
      ]
    }
  }
}

resource githubJobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(githubActionsPrincipalId)) {
  name: guid(job.id, githubActionsPrincipalId, '4e3d2b60-56ae-4dc6-a233-09c8e5a82e68')
  scope: job
  properties: {
    principalId: githubActionsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4e3d2b60-56ae-4dc6-a233-09c8e5a82e68')
  }
}
