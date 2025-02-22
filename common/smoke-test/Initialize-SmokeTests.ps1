#!/usr/bin/env pwsh

# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

#Requires -Version 6.0
#Requires -PSEdition Core

[CmdletBinding(DefaultParameterSetName="Provisioner")]

param (
  [Parameter(ParameterSetName = 'Provisioner', Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')]
  [string] $TestApplicationId,

  [Parameter()]
  [string] $TestApplicationSecret,

  [Parameter()]
  [string] $TestApplicationOid,

  [Parameter(ParameterSetName = 'Provisioner', Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $TenantId,

  [Parameter(ParameterSetName = 'Provisioner')]
  [ValidatePattern('^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')]
  [string] $SubscriptionId,

  [Parameter()]
  [string] $Location = '',

  [Parameter()]
  [string] $Environment = 'AzureCloud',

  [Parameter()]
  [hashtable] $AdditionalParameters,

  [Parameter()]
  [string] $ServiceDirectory = '*',

  [Parameter()]
  [switch] $CI = ($null -ne $env:SYSTEM_TEAMPROJECTID),

  [Parameter()]
  [switch] $Daily,

  [Parameter()]
  [string] $TagOverride,

  [Parameter()]
  [array] $TagOverridePackages,

  # DryRun will generate the smoke test run manifest, but will skip deploying any resources.
  # This can be useful for testing what projects will be configured to run for a given command.
  [Parameter(ParameterSetName = 'DryRun')]
  [switch] $DryRun,

  # Captures any arguments not declared here (prevents no parameter errors)
  [Parameter(ValueFromRemainingArguments = $true)]
  $RemainingArguments
)

$repoRoot = Resolve-Path -Path "$PSScriptRoot../../../"
. "$repoRoot/eng/common/scripts/logging.ps1"

function Set-EnvironmentVariable {
  param([string] $Name, [string] $Value)

  if ($CI) {
    Write-Host "##vso[task.setvariable variable=_$Name;issecret=true;]$($Value)"
    Write-Host "##vso[task.setvariable variable=$Name;]$($Value)"
  }
  else {
    Write-Verbose "Setting local environment variable: $Name = ***"
    Set-Item -Path "env:$Name" -Value $Value
  }
}

function Set-EnvironmentVariables {
  Write-Verbose "Setting AAD environment variables for Test Application..."
  Set-EnvironmentVariable -Name AZURE_CLIENT_ID -Value $TestApplicationId
  Set-EnvironmentVariable -Name AZURE_CLIENT_SECRET -Value $TestApplicationSecret
  Set-EnvironmentVariable -Name AZURE_TENANT_ID -Value $TenantId

  Write-Verbose "Setting cloud-specific environment variables"
  $cloudEnvironment = Get-AzEnvironment -Name $Environment
  Set-EnvironmentVariable -Name AZURE_AUTHORITY_HOST -Value $cloudEnvironment.ActiveDirectoryAuthority
}

function New-DeployManifest {
  Write-Verbose "Detecting samples..."
  $packageDir = Get-ChildItem -Directory -Path "$repoRoot/sdk/$ServiceDirectory/*"

  $javascriptSamples = @()
  $packageDir.ForEach{
    $versions = (Get-Item "$_/samples/*").Name
    $newestVer = $versions | Sort-Object {[int]($_ -replace '[^0-9]' -replace '(\d+).*', '$1')} -Descending | Select-Object -First 1
    if($versions -contains $newestVer+"-beta") {
      $newestVer += "-beta"
    }
    $javascriptSamples += Get-ChildItem -Path "$_/samples/$newestVer/javascript/" -Recurse -Include package.json
  }

  $manifest = $javascriptSamples | ForEach-Object {
    # Example: azure-sdk-for-js/sdk/appconfiguration/app-configuration/samples/v1/javascript
    $PackagePath = (Join-Path $_ ../../../../) | Get-Item
    @{
      # Package name for example "app-configuration"
      Name               = $PackagePath.Name;

      # Path to "app-configuration" part from example
      PackageDirectory   = $PackagePath.FullName;

      # Service Directory for example "appconfiguration"
      ResourcesDirectory = $PackagePath.Parent.Name;

      # Path to "javascript"
      SamplesDirectory   = $_.Directoryname;
    }
  }

  return $manifest
}

function Update-SamplesForService {
  Param([Parameter(Mandatory = $true)] $entry)

  $sampleFiles = Get-ChildItem "$($entry.SamplesDirectory)/*.js"
  foreach ($sampleFile in $sampleFiles) {
    $fileContent = Get-Content -Raw $sampleFile
    $fileContent = $fileContent -replace "(?s)main\(\)\.catch.*", "module.exports = { main };`n"
    Set-Content -Path $sampleFile -Value $fileContent
  }
}

function Update-SampleDependencies {
  Param(
    [Parameter(Mandatory = $true)] $sample,
    [Parameter(Mandatory = $true)] $dependencies
  )

  # Set sample's dependencies in all-up dependencies for smoke tests
  Write-Verbose "Updating local package.json with dependencies from smoke test for $($sample.Name)"
  $packageSpec = (Get-Content -Path "$($sample.SamplesDirectory)/package.json"
    | ConvertFrom-Json -AsHashtable)

  foreach ($dep in $packageSpec.dependencies.Keys) {
    if ($dep.StartsWith('@azure/')) {
      if ($Daily) {
        $dependencies[$dep] = "dev"
      } elseif ($dep -in $TagOverridePackages) {
        # For non-daily smoke tests (i.e. release smoke tests), specifically
        # override the package.json tag for the newly released package under test.
        # Tag will be either 'latest' or 'next'
        $dependencies[$dep] = $TagOverride
      } else {
        # For non-daily smoke tests and/or non-azure dependencies,
        # use whatever is in the source package.json
        $dependencies[$dep] = $packageSpec.dependencies[$dep]
      }
    }
    else {
      $dependencies[$dep] = $packageSpec.dependencies[$dep]
    }
  }
}

function Start-NewTestResourcesJob {
  Param(
    [Parameter(Mandatory = $true)] [System.Collections.Hashtable]$entry,
    [Parameter(Mandatory = $true)] [string]$baseName,
    [Parameter(Mandatory = $true)] [string]$resourceGroupName
  )

  Start-Job -Name $entry.Name -ScriptBlock {
    &"$using:repoRoot/eng/common/TestResources/New-TestResources.ps1" `
       -BaseName  $using:baseName `
       -ResourceGroupName $using:resourceGroupName `
       -ServiceDirectory $using:entry.ResourcesDirectory `
       -TestApplicationId $using:TestApplicationId `
       -TestApplicationSecret $using:TestApplicationSecret `
       -ProvisionerApplicationId $using:TestApplicationId `
       -ProvisionerApplicationSecret $using:TestApplicationSecret `
       -TestApplicationOid $using:TestApplicationOid `
       -TenantId $using:TenantId `
       -SubscriptionId $using:SubscriptionId `
       -Location $using:Location `
       -Environment $using:Environment `
       -AdditionalParameters $using:AdditionalParameters `
       -DeleteAfterHours 24 `
       -Force `
       -Verbose `
       -CI:$using:CI
  }
}

function Deploy-TestResources {
  Param([Parameter(Mandatory = $true)] $deployManifest)

  $deployedServiceDirectories = @{ }
  $baseName = 't' + (New-Guid).ToString('n').Substring(0, 16)
  $resourceGroupName = "rg-smoke-$baseName"
  $dependencies = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  $runManifest = @()

  # Use the same resource group name that New-TestResources.ps1 generates
  Set-EnvironmentVariable -Name 'AZURE_RESOURCEGROUP_NAME' -Value $resourceGroupName

  $entryDeployJobs = @()

  try {
    foreach ($entry in $deployManifest) {
      if (!(Get-ChildItem -Path "$repoRoot/sdk/$($entry.ResourcesDirectory)" -Filter test-resources.json -Recurse)) {
        Write-Verbose "Skipping $($entry.ResourcesDirectory): could not find test-resources.json"
        continue
      }

      if ($deployedServiceDirectories.ContainsKey($entry.ResourcesDirectory) -ne $true) {
        if (-not $DryRun) {
          Write-Verbose "Starting deploy job for $($entry.ResourcesDirectory)"
          $job = Start-NewTestResourcesJob $entry $baseName $resourceGroupName
          $entryDeployJobs += $job
        }
        $deployedServiceDirectories[$entry.ResourcesDirectory] = $true;
      }
      else {
        Write-Verbose "Skipping resource directory deployment (already deployed) for $($entry.ResourcesDirectory)"
      }

      Update-SamplesForService $entry
      Update-SampleDependencies $entry $dependencies
      $runManifest += $entry
    }

    if (-not $DryRun) {
      Write-Verbose "Waiting for all deploy jobs to finish (will timeout after 15 minutes)..."
      $entryDeployJobs | Wait-Job -TimeoutSec (15*60)
      if ($entryDeployJobs | Where-Object {$_.State -eq "Running"}) {
        $entryDeployJobs
        throw "Timed out waiting for deploy jobs to finish:"
      }

      foreach ($job in $entryDeployJobs) {
        if ($job.State -eq [System.Management.Automation.JobState]::Failed) {
          $errorMsg = $job.ChildJobs[0].JobStateInfo.Reason.Message
          LogWarning "Failed to deploy $($job.Name): $($errorMsg)"
          Write-Host $errorMsg
          continue
        }

        Write-Verbose "setting env"
        $deployOutput = Receive-Job -Id $job.Id
        foreach ($key in $deployOutput.Keys) {
          Set-EnvironmentVariable -Name $key -Value $deployOutput[$key]
        }
      }
    }
  } finally {
    $entryDeployJobs | Remove-Job -Force
  }

  @{ Dependencies = $dependencies; RunManifest = $runManifest }
}

function Export-Configs {
  Param(
    [Parameter(Mandatory = $true)] [System.Collections.Generic.Dictionary[string,string]]$dependencies,
    [Parameter(Mandatory = $true)] $runManifest
  )

  Write-Verbose "Writing run-manifest.json"
  ($runManifest | ConvertTo-Json -AsArray | Set-Content -Path "$repoRoot/common/smoke-test/run-manifest.json" -Force)

  Write-Verbose "Writing dependencies into Smoke Test package.json"
  $runnerPackageSpec = Get-Content "$repoRoot/common/smoke-test/package.json" | ConvertFrom-Json -AsHashtable
  $runnerPackageSpec.dependencies = $dependencies
  ($runnerPackageSpec | ConvertTo-Json | Set-Content "$repoRoot/common/smoke-test/package.json")
}

function Initialize-SmokeTests {
  Set-EnvironmentVariables
  $deployManifest = New-DeployManifest
  if (!$deployManifest) {
      Write-Warning "No javascript samples found for $ServiceDirectory"
      return
  }
  $configs = Deploy-TestResources $deployManifest
  Export-Configs $configs.Dependencies $configs.RunManifest

  Set-EnvironmentVariable -Name "NODE_PATH" -Value "$PSScriptRoot/node_modules"

  if ($CI) {
    # If in CI mark the task as successful even if there are warnings so the
    # pipeline execution status shows up as red or green
    Write-Host "##vso[task.complete result=Succeeded; ]DONE"
  }
}

Initialize-SmokeTests

<#
.SYNOPSIS
Deploys resources, discovers and generates samples, configures local dependencies, and creates run manifest for Smoke Tests

.DESCRIPTION


#>
