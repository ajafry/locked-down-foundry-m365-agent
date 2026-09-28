/*
Stage 13 — Foundry account (orchestrator)

The Foundry (AI Services) account is the centrepiece of the whole platform, so it
gets its own stage carrying EVERYTHING that stands the account up and protects it:

  foundry/ai-services-account.bicep            → the CMK-protected account + model deployment
                                                 + SMI/UAMI + VNet injection + diagnostics
  network/ai-account-private-endpoint.bicep    → the account private endpoint + DNS
  rbac/keyvault-account-role-assignment.bicep  → CMK UAMI → Key Vault Crypto User
  rbac/app-insights-account-role-assignment.bicep → account SMI → Log Analytics Reader

Runs AFTER stage 10 (needs Key Vault + the DNS zones + the data substrate). The
project (its data-plane RBAC + capability host) lives in stage 15.
*/

param location string
param uniqueSuffix string

// Account + model.
param accountName string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int

// From stage 00 (observability + networking).
param agentSubnetId string
param logAnalyticsId string
param appInsightsConnectionString string
param appInsightsId string
param appInsightsName string
param foundrySpokeVnetName string
param foundryPeSubnetName string
param aiServicesDnsZoneId string
param openAiDnsZoneId string
param cognitiveServicesDnsZoneId string

// Key Vault (CMK) — from stage 10 data resources.
param keyVaultName string
param keyVaultUri string
param keyName string
param keyUriWithVersion string

// Foundry account egress posture.
var foundryRestrictOutboundNetworkAccess = false
var foundryAllowedFqdnList = []
// Private-endpoint-only: public network access is always disabled.
var foundryPublicNetworkAccess = 'Disabled'

// A dedicated UAMI avoids the system-assigned identity propagation race during CMK setup:
// its principal exists and receives Key Vault access before the Foundry account PUT.
resource cmkIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${accountName}-cmk-id'
  location: location
}

module keyVaultAccountRoleAssignment './rbac/keyvault-account-role-assignment.bicep' = {
  name: 'keyvault-account-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    cmkPrincipalId: cmkIdentity.properties.principalId
  }
}

module aiAccount './foundry/ai-services-account.bicep' = {
  name: 'ai-${accountName}-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: agentSubnetId
    logAnalyticsWorkspaceId: logAnalyticsId
    appInsightsConnectionString: appInsightsConnectionString
    appInsightsResourceId: appInsightsId
    restrictOutboundNetworkAccess: foundryRestrictOutboundNetworkAccess
    allowedFqdnList: foundryAllowedFqdnList
    publicNetworkAccess: foundryPublicNetworkAccess
    cmkIdentityResourceId: cmkIdentity.id
    cmkIdentityClientId: cmkIdentity.properties.clientId
    keyVaultUri: keyVaultUri
    keyName: keyName
    keyVersion: last(split(keyUriWithVersion, '/'))
  }
  dependsOn: [
    keyVaultAccountRoleAssignment
  ]
}


module appInsightsAccountRoleAssignment './rbac/app-insights-account-role-assignment.bicep' = {
  name: 'appi-account-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: appInsightsName
    accountPrincipalId: aiAccount.outputs.accountPrincipalId
  }
}

module aiAccountPrivateEndpoint './network/ai-account-private-endpoint.bicep' = {
  name: 'stage13-account-pe-${uniqueSuffix}'
  params: {
    aiAccountName: aiAccount.outputs.accountName
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName
    aiServicesDnsZoneId: aiServicesDnsZoneId
    openAiDnsZoneId: openAiDnsZoneId
    cognitiveServicesDnsZoneId: cognitiveServicesDnsZoneId
  }
}

output aiAccountName string = aiAccount.outputs.accountName
output accountPrincipalId string = aiAccount.outputs.accountPrincipalId
