using 'main.bicep'

param location = readEnvironmentVariable('LAB_REGION')
param vmSize = readEnvironmentVariable('LAB_VM_SIZE', 'Standard_B2ls_v2')
param trustedLaunch = bool(readEnvironmentVariable('LAB_TRUSTED_LAUNCH', 'true'))
param adminPassword = readEnvironmentVariable('LAB_ADMIN_PASSWORD')
param expiresOn = readEnvironmentVariable('LAB_EXPIRES_ON', '')
