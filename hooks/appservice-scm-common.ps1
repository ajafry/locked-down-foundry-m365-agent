<#
  Shared helpers for the predeploy / postdeploy hooks that open and re-lock the SCM (Kudu) sites
  of the two code-deployed App Services (the private MCP app + the public YARP Teams edge) so azd
  can zip-deploy them from the host, then close the window again.

  Both web apps declare (in Bicep) a deny-by-default SCM site:
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
  so at rest NOTHING may reach Kudu over the public path. The MCP app is additionally fully
  private (publicNetworkAccess: 'Disabled') + private-endpointed.

  Open  (predeploy):  MCP -> enable public access; BOTH -> add an SCM Allow rule for the deployer IP.
  Close (postdeploy): BOTH -> remove that SCM rule; MCP -> re-disable public access.

  Env (azd surfaces Bicep outputs as env vars verbatim; AZURE_* are azd built-ins):
      AZURE_RESOURCE_GROUP   - the resource group (Bicep output).
      MCP_WEBAPP_NAME        - the private MCP web app name (Bicep output).
      TEAMS_YARP_WEBAPP_NAME - the public YARP web app name (Bicep output).
      DEPLOYER_PUBLIC_IP     - optional; the deployer's IP/CIDR (recorded by the preprovision hook).
#>

# Prefix for the temporary SCM allow rules. Multiple rules may be needed when the azd host uses
# a rotating outbound proxy pool.
$script:ScmDeployRulePrefix = 'azd-scm-deploy'

function Get-RequiredEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Required environment variable '$Name' is not set (it is a Bicep output azd surfaces as an env var; run 'azd env refresh' if it is missing)."
  }
  return $value.Trim().Trim('"')
}

function Get-OptionalEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return $value.Trim().Trim('"')
}

# Resolve a public IP as a CIDR the App Service access-restriction API accepts.
# This is only a fallback for SCM: App Service can observe a different egress address than
# public IP-discovery services when the host uses a proxy or split network path.
function Get-DeployerIpCidr {
  $ip = Get-OptionalEnv 'DEPLOYER_PUBLIC_IP'
  if ([string]::IsNullOrWhiteSpace($ip)) {
    try {
      $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).ToString().Trim()
    }
    catch {
      throw "Could not determine the deployer's public IP (DEPLOYER_PUBLIC_IP not set and api.ipify.org unreachable). Set it with 'azd env set DEPLOYER_PUBLIC_IP <ip/cidr>' and retry."
    }
  }
  if ($ip -match '/') { return $ip }
  if ($ip -match ':') { return "$ip/128" }
  return "$ip/32"
}

function ConvertTo-HostCidr {
  param([string]$IpAddress)

  if ([string]::IsNullOrWhiteSpace($IpAddress)) { return $null }
  $value = $IpAddress.Trim()
  $parsed = $null
  if (-not [System.Net.IPAddress]::TryParse($value, [ref]$parsed)) { return $null }
  if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
    return "$value/128"
  }
  return "$value/32"
}

# When SCM denies a request, App Service returns the evaluated client address in
# x-ms-forbidden-ip. Prefer that address over generic public-IP discovery because it is the
# exact network path azd's zip-deploy uses.
function Get-ScmObservedIpCidr {
  param([string]$Name)

  $uri = "https://$Name.scm.azurewebsites.net/"
  try {
    $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 15 -SkipHttpErrorCheck
    if ([int]$response.StatusCode -ne 403) { return $null }
    $observedIp = $response.Headers['x-ms-forbidden-ip'] | Select-Object -First 1
    return ConvertTo-HostCidr -IpAddress $observedIp
  }
  catch {
    return $null
  }
}

function Remove-ScmDeployRules {
  param(
    [string]$ResourceGroup,
    [string]$Name
  )

  $json = az webapp config access-restriction show -g $ResourceGroup -n $Name --output json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    throw "Failed to read SCM access restrictions for '$Name'."
  }
  $rules = ($json | ConvertFrom-Json).scmIpSecurityRestrictions
  foreach ($rule in $rules) {
    if ($rule.name -and $rule.name.StartsWith($script:ScmDeployRulePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      az webapp config access-restriction remove -g $ResourceGroup -n $Name `
        --rule-name $rule.name --scm-site true --output none
      if ($LASTEXITCODE -ne 0) { throw "Failed to remove SCM deploy rule '$($rule.name)' from '$Name'." }
    }
  }
}

function Add-ScmDeployRule {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [string]$IpCidr,
    [int]$Index
  )

  $ruleName = "$($script:ScmDeployRulePrefix)-$Index"
  az webapp config access-restriction add -g $ResourceGroup -n $Name `
    --rule-name $ruleName --action Allow --priority (100 + $Index) `
    --ip-address $IpCidr --scm-site true --output none
  if ($LASTEXITCODE -ne 0) { throw "Failed to add SCM deploy rule '$ruleName' for '$IpCidr' to '$Name'." }
  Write-Host "[$Name] Added temporary SCM rule '$ruleName' for $IpCidr."
}

# Toggle a web app's site-level publicNetworkAccess ('Enabled' / 'Disabled') via a merge update.
function Set-WebAppPublicNetworkAccess {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [ValidateSet('Enabled', 'Disabled')] [string]$State
  )
  $id = az webapp show -g $ResourceGroup -n $Name --query id -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
    throw "Failed to resolve web app '$Name' in resource group '$ResourceGroup'."
  }
  az resource update --ids $id --set properties.publicNetworkAccess=$State --output none
  if ($LASTEXITCODE -ne 0) { throw "Failed to set publicNetworkAccess=$State on '$Name'." }
  Write-Host "[$Name] publicNetworkAccess = $State"
}

# Add the temporary deployer-IP Allow rule to the SCM site. Idempotent: an existing rule of the
# same name is removed first so re-runs don't error on a duplicate.
function Open-ScmForDeployer {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [string]$IpCidr
  )
  $observedIpCidr = Get-ScmObservedIpCidr -Name $Name
  $effectiveIpCidr = if ($observedIpCidr) { $observedIpCidr } else { $IpCidr }
  if ($observedIpCidr -and $observedIpCidr -ne $IpCidr) {
    Write-Host "[$Name] SCM observes deployer as $observedIpCidr; public-IP discovery returned $IpCidr."
  }

  Remove-ScmDeployRules -ResourceGroup $ResourceGroup -Name $Name
  Add-ScmDeployRule -ResourceGroup $ResourceGroup -Name $Name -IpCidr $effectiveIpCidr -Index 0

  # App Service access-restriction changes are NOT immediate - they take ~30-90s to reach the Kudu
  # worker. If azd POSTs the zip before the new Allow rule is live, Kudu answers 403 Ip Forbidden
  # and the deploy fails. The host can also use a rotating proxy pool, so learn any additional
  # denied source IPs and require repeated successful probes before handing off to azd.
  Wait-ScmDeployerAllowed -ResourceGroup $ResourceGroup -Name $Name -InitialIpCidr $effectiveIpCidr
}

# Poll SCM from the azd host, learning rotating proxy addresses from x-ms-forbidden-ip. Require
# consecutive non-403 responses so a single lucky request through an already-allowed proxy does
# not start zip-deploy while other addresses in the pool are still blocked.
function Wait-ScmDeployerAllowed {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [string]$InitialIpCidr,
    [int]$TimeoutSeconds = 240,
    [int]$RequiredSuccesses = 30,
    [int]$MaximumRules = 20
  )
  $uri      = "https://$Name.scm.azurewebsites.net/"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastObservedIp = $null
  $successes = 0
  $allowedCidrs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  [void]$allowedCidrs.Add($InitialIpCidr)
  Write-Host "[$Name] Learning the SCM egress pool and waiting for $RequiredSuccesses consecutive allowed probes ($uri)..."
  while ((Get-Date) -lt $deadline) {
    $code = 0
    $resp = $null
    try {
      $resp = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 10 -SkipHttpErrorCheck
      $code = [int]$resp.StatusCode
    }
    catch {
      # Network-level failure (DNS/TLS/timeout): treat as not-yet-ready and keep polling. If the
      # server responded (rare, e.g. an unfollowed redirect), pull the status out of the exception.
      if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    }
    if ($code -eq 403 -and $resp) {
      $lastObservedIp = $resp.Headers['x-ms-forbidden-ip'] | Select-Object -First 1
      $observedCidr = ConvertTo-HostCidr -IpAddress $lastObservedIp
      if ($observedCidr -and -not $allowedCidrs.Contains($observedCidr)) {
        if ($allowedCidrs.Count -ge $MaximumRules) {
          throw "SCM for '$Name' used more than $MaximumRules distinct egress addresses; refusing to broaden access further."
        }
        [void]$allowedCidrs.Add($observedCidr)
        Add-ScmDeployRule -ResourceGroup $ResourceGroup -Name $Name `
          -IpCidr $observedCidr -Index ($allowedCidrs.Count - 1)
      }
      $successes = 0
    }
    if ($code -ne 0 -and $code -ne 403) {
      $successes++
      if ($successes -ge $RequiredSuccesses) {
        Write-Host "[$Name] SCM reachable across repeated probes (HTTP $code); temporary rules are live."
        return
      }
    }
    elseif ($code -eq 0) {
      $successes = 0
    }
    Start-Sleep -Seconds 2
  }
  $observedDetail = if ($lastObservedIp) { " App Service observed source IP '$lastObservedIp'." } else { '' }
  throw "SCM for '$Name' did not sustain $RequiredSuccesses allowed probes within ${TimeoutSeconds}s.$observedDetail Refusing to start zip-deploy."
}

# Remove the temporary deployer-IP Allow rule, re-locking the SCM site (deny-by-default). Missing
# rule is not an error (already closed).
function Close-ScmForDeployer {
  param(
    [string]$ResourceGroup,
    [string]$Name
  )
  Remove-ScmDeployRules -ResourceGroup $ResourceGroup -Name $Name
  Write-Host "[$Name] SCM deploy allow-rules removed (SCM re-locked to deny-by-default)."
}
