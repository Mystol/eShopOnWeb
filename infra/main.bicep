// ============================================================
// SecureFintech — Infrastructure as Code (Bicep)
// Convention de nommage : CAF Microsoft (Cloud Adoption Framework)
// Format : <préfixe>-<projet>-<env>-<suffixe>
//
// Déploiement :
//   az deployment sub create \
//     --location westeurope \
//     --template-file infra/main.bicep \
//     --parameters infra/main.parameters.json
//
// Note d'adaptation : Ce template décrit l'architecture Azure
// cible du brief. Dans la réalisation concrète, Azure a été
// remplacé par un VPS Ubuntu 24.04 (Hostinger) faute de compte
// Azure disponible. Les docker-compose.*.yml jouent le rôle de
// ce Bicep dans l'environnement VPS. Voir README.md section 1.
// ============================================================

targetScope = 'subscription'

// ── Paramètres ──────────────────────────────────────────────

@description('Nom du projet (utilisé dans toutes les ressources)')
param projectName string = 'securefintech'

@description('Environnement : dev | staging | prod')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Région Azure cible')
param location string = 'westeurope'

@description('Suffixe court unique mondial pour Key Vault (3-6 caractères)')
@minLength(3)
@maxLength(6)
param uniqueSuffix string

@description('Mot de passe administrateur SQL Server (minimum 12 caractères, majuscule + chiffre + spécial)')
@secure()
param sqlAdminPassword string

@description('ID Azure AD du principal autorisé à lire les secrets Key Vault (votre compte ou service principal CI)')
param principalId string = ''

// ── Convention de nommage CAF ─────────────────────────────────
// Région : weu = West Europe
var region = 'weu'
var rgName            = 'rg-${projectName}-${environment}-${region}'
var planName          = 'plan-${projectName}-${environment}'
var appStagingName    = 'app-${projectName}-${environment}-stg'
var appProductionName = 'app-${projectName}-${environment}-prd'
var sqlServerName     = 'sql-${projectName}-${environment}'
var catalogDbName     = 'sqldb-${projectName}-catalog-${environment}'
var identityDbName    = 'sqldb-${projectName}-identity-${environment}'
// Key Vault : nom unique mondial, suffixe aléatoire requis
var kvName            = 'kv-${projectName}-${environment}-${uniqueSuffix}'

var tags = {
  project: projectName
  environment: environment
  managedBy: 'bicep'
}

// ── Resource Group ───────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: tags
}

// ── App Service Plan (F1 gratuit) ────────────────────────────
module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'deploy-plan'
  scope: rg
  params: {
    name: planName
    location: location
    tags: tags
    sku: {
      name: 'F1'   // Gratuit — passer à B1 pour la production réelle
      tier: 'Free'
    }
  }
}

// ── App Service Staging ──────────────────────────────────────
module appStaging './core/host/appservice.bicep' = {
  name: 'deploy-app-staging'
  scope: rg
  params: {
    name: appStagingName
    location: location
    tags: union(tags, { slot: 'staging' })
    appServicePlanId: appServicePlan.outputs.id
    keyVaultName: kvName
    runtimeName: 'dotnetcore'
    runtimeVersion: '10.0'
    appSettings: {
      ASPNETCORE_ENVIRONMENT: 'Staging'
      AZURE_SQL_CATALOG_CONNECTION_STRING_KEY: 'CatalogConnection'
      AZURE_SQL_IDENTITY_CONNECTION_STRING_KEY: 'IdentityConnection'
    }
  }
}

// ── App Service Production ───────────────────────────────────
module appProduction './core/host/appservice.bicep' = {
  name: 'deploy-app-production'
  scope: rg
  params: {
    name: appProductionName
    location: location
    tags: union(tags, { slot: 'production' })
    appServicePlanId: appServicePlan.outputs.id
    keyVaultName: kvName
    runtimeName: 'dotnetcore'
    runtimeVersion: '10.0'
    appSettings: {
      ASPNETCORE_ENVIRONMENT: 'Production'
      AZURE_SQL_CATALOG_CONNECTION_STRING_KEY: 'CatalogConnection'
      AZURE_SQL_IDENTITY_CONNECTION_STRING_KEY: 'IdentityConnection'
    }
  }
}

// ── Azure SQL Server + Bases de données ──────────────────────
// CatalogDb (catalogue produits)
module catalogDb './core/database/sqlserver/sqlserver.bicep' = {
  name: 'deploy-sql-catalog'
  scope: rg
  params: {
    name: sqlServerName
    databaseName: catalogDbName
    location: location
    tags: tags
    sqlAdminPassword: sqlAdminPassword
    appUserPassword: sqlAdminPassword
    keyVaultName: kvName
    connectionStringKey: 'CatalogConnection'
  }
}

// IdentityDb (authentification ASP.NET Core Identity)
module identityDb './core/database/sqlserver/sqlserver.bicep' = {
  name: 'deploy-sql-identity'
  scope: rg
  dependsOn: [catalogDb]
  params: {
    name: sqlServerName
    databaseName: identityDbName
    location: location
    tags: tags
    sqlAdminPassword: sqlAdminPassword
    appUserPassword: sqlAdminPassword
    keyVaultName: kvName
    connectionStringKey: 'IdentityConnection'
  }
}

// ── Azure Key Vault ───────────────────────────────────────────
// Les secrets CatalogConnection et IdentityConnection sont stockés ici
// et injectés dans les App Services via des références Key Vault :
//   @Microsoft.KeyVault(SecretUri=https://kv-...vault.azure.net/secrets/CatalogConnection/)
module keyVault './core/security/keyvault.bicep' = {
  name: 'deploy-keyvault'
  scope: rg
  params: {
    name: kvName
    location: location
    tags: tags
    principalId: principalId
  }
}

// Accès Key Vault pour l'identité managée de l'App Service Staging
module kvAccessStaging './core/security/keyvault-access.bicep' = {
  name: 'kv-access-staging'
  scope: rg
  params: {
    keyVaultName: kvName
    principalId: appStaging.outputs.identityPrincipalId
  }
}

// Accès Key Vault pour l'identité managée de l'App Service Production
module kvAccessProduction './core/security/keyvault-access.bicep' = {
  name: 'kv-access-production'
  scope: rg
  params: {
    keyVaultName: kvName
    principalId: appProduction.outputs.identityPrincipalId
  }
}

// ── Outputs ──────────────────────────────────────────────────
output resourceGroupName string = rg.name
output appStagingUrl string = 'https://${appStagingName}.azurewebsites.net'
output appProductionUrl string = 'https://${appProductionName}.azurewebsites.net'
output keyVaultUri string = 'https://${kvName}.vault.azure.net/'
output sqlServerFqdn string = '${sqlServerName}.database.windows.net'
output AZURE_KEY_VAULT_NAME string = kvName
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
