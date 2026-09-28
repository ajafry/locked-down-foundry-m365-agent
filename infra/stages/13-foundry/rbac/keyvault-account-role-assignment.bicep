// Assigns the Key Vault Crypto User role to the dedicated Foundry CMK identity.

@description('Name of the Key Vault')
param keyVaultName string

@description('Principal ID of the user-assigned identity used for Foundry CMK access')
param cmkPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Crypto User: 12338af0-0e69-4776-bea7-57ae8d297424
// Includes sign/verify in addition to wrap/unwrap - required by AI Services
resource kvCryptoUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '12338af0-0e69-4776-bea7-57ae8d297424'
  scope: resourceGroup()
}

resource aiServicesRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(cmkPrincipalId, kvCryptoUserRole.id, keyVault.id)
  properties: {
    principalId: cmkPrincipalId
    roleDefinitionId: kvCryptoUserRole.id
    principalType: 'ServicePrincipal'
  }
}
