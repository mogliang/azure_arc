Start-Transcript -Path C:\Temp\DeployPostgreSQL.log

# Deployment environment variables
$Env:TempDir = "C:\Temp"
$controllerName = "jumpstart-dc"

# Deploying Azure Arc-enabled PostgreSQL
Write-Host "`n"
Write-Host "Deploying Azure Arc-enabled PostgreSQL"
Write-Host "`n"

$customLocationId = $(az customlocation show --name "jumpstart-cl" --resource-group $env:resourceGroup --query id -o tsv)
$dataControllerId = $(az resource show --resource-group $env:resourceGroup --name $controllerName --resource-type "Microsoft.AzureArcData/dataControllers" --query id -o tsv)

################################################
# Localize ARM template
################################################
$ServiceType = "LoadBalancer"

# Resource Requests
$coordinatorCoresRequest = "2"
$coordinatorMemoryRequest = "4Gi"
$coordinatorCoresLimit = "4"
$coordinatorMemoryLimit = "8Gi"

# Storage
$StorageClassName = "managed-premium"
$dataStorageSize = "5Gi"
$logsStorageSize = "5Gi"

# Citus Scale out
$numWorkers = 1
################################################

$PSQLParams = "$Env:TempDir\postgreSQL.parameters.json"

(Get-Content -Path $PSQLParams) -replace 'resourceGroup-stage',$env:resourceGroup | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'dataControllerId-stage',$dataControllerId | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'customLocation-stage',$customLocationId | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'subscriptionId-stage',$env:subscriptionId | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'azdataPassword-stage',$env:AZDATA_PASSWORD | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'serviceType-stage',$ServiceType | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'coordinatorCoresRequest-stage',$coordinatorCoresRequest | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'coordinatorMemoryRequest-stage',$coordinatorMemoryRequest | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'coordinatorCoresLimit-stage',$coordinatorCoresLimit | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'coordinatorMemoryLimit-stage',$coordinatorMemoryLimit | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'dataStorageClassName-stage',$StorageClassName | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'logsStorageClassName-stage',$StorageClassName | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'dataSize-stage',$dataStorageSize | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'logsSize-stage',$logsStorageSize | Set-Content -Path $PSQLParams
(Get-Content -Path $PSQLParams) -replace 'numWorkersStage',$numWorkers | Set-Content -Path $PSQLParams

az deployment group create --resource-group $env:resourceGroup `
                           --template-file "$Env:TempDir\postgreSQL.json" `
                           --parameters "$Env:TempDir\postgreSQL.parameters.json"

Write-Host "`n"
# Ensures postgres container is initiated and ready to accept restores
$pgWorkerPodName = "jumpstartps-0"

Write-Host "`n"
    Do {
        Write-Host "Waiting for PostgreSQL. Hold tight, this might take a few minutes...(45s sleeping loop)"
        Start-Sleep -Seconds 45
        $buildService = $(if((kubectl get pods -n arc | Select-String $pgWorkerPodName| Select-String "Running" -Quiet)){"Ready!"}Else{"Nope"})
    } while ($buildService -eq "Nope")

Write-Host "`n"
Write-Host "Azure Arc-enabled PostgreSQL is ready!"
Write-Host "`n"

Start-Sleep -Seconds 60

# Downloading demo database and restoring onto Postgres
Write-Host "`n"
Write-Host "Downloading AdventureWorks.sql template for PostgreSQL (1/3)"
kubectl exec $pgWorkerPodName -n arc -c postgres -- /bin/bash -c "curl -o /tmp/AdventureWorks2019.sql 'https://jsvhds.blob.core.windows.net/sampledb/AdventureWorks2019.sql?sp=r&st=2023-08-10T18:30:33Z&se=2033-08-11T02:30:33Z&spr=https&sv=2022-11-02&sr=b&sig=5kD1PR4gwaCWlefSknggq%2BYsx1FgBrp5Kv1pH42d1nE%3D'" 2>&1 | Out-Null
Write-Host "Creating AdventureWorks database on PostgreSQL (2/3)"
kubectl exec $pgWorkerPodName -n arc -c postgres -- psql -U postgres -c 'CREATE DATABASE "adventureworks2019";' postgres 2>&1 | Out-Null
Write-Host "Restoring AdventureWorks database on PostgreSQL (3/3)"
kubectl exec $pgWorkerPodName -n arc -c postgres -- psql -U postgres -d adventureworks2019 -f /tmp/AdventureWorks2019.sql 2>&1 | Out-Null

# Creating Azure Data Studio settings for PostgreSQL connection
Write-Host "`n"
Write-Host "Creating Azure Data Studio settings for PostgreSQL connection"
$settingsTemplate = "$Env:TempDir\settingsTemplate.json"

# Retrieving PostgreSQL connection endpoint
$pgsqlstring = kubectl get postgresql jumpstartps -n arc -o=jsonpath='{.status.primaryEndpoint}'

# Replace placeholder values in settingsTemplate.json
(Get-Content -Path $settingsTemplate) -replace 'arc_postgres_host',$pgsqlstring.split(":")[0] | Set-Content -Path $settingsTemplate
(Get-Content -Path $settingsTemplate) -replace 'arc_postgres_port',$pgsqlstring.split(":")[1] | Set-Content -Path $settingsTemplate
(Get-Content -Path $settingsTemplate) -replace 'ps_password',$env:AZDATA_PASSWORD | Set-Content -Path $settingsTemplate


# If SQL MI isn't being deployed, clean up settings file
if ( $env:deploySQLMI -eq $false )
{
     $string = Get-Content -Path $settingsTemplate | Select-Object -First 9 -Last 24
     $string | Set-Content -Path $settingsTemplate
}
