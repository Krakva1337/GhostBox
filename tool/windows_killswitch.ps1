[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Enable', 'Disable', 'Status')]
  [string]$Action,
  [string]$EndpointIp,
  [ValidateRange(1, 65535)]
  [int]$Port,
  [ValidatePattern('^[A-Za-z0-9 _.-]{1,64}$')]
  [string]$TunAlias = 'ghostbox0'
)

$ErrorActionPreference = 'Stop'
$Group = 'GhostBox Kill Switch'
$RegistryPath = 'HKLM:\SOFTWARE\GhostBox\KillSwitch'
$Profiles = @('Domain', 'Private', 'Public')
$CreatedStateThisRun = $false

function Write-Json($Value) {
  $Value | ConvertTo-Json -Compress -Depth 5 | Write-Output
}

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Windows Kill Switch requires administrator rights. Run GhostBox elevated and accept the UAC prompt.'
  }
}

function Get-SavedState {
  if (-not (Test-Path $RegistryPath)) { return $null }
  $item = Get-ItemProperty -Path $RegistryPath -ErrorAction Stop
  if (-not $item.SavedOutboundDefaults) { return $null }
  return ($item.SavedOutboundDefaults | ConvertFrom-Json)
}

function Get-SavedConfiguration {
  if (-not (Test-Path $RegistryPath)) { return $null }
  $item = Get-ItemProperty -Path $RegistryPath -ErrorAction Stop
  if (-not $item.Configuration) { return $null }
  return ($item.Configuration | ConvertFrom-Json)
}

function Get-SavedAllowRuleNames {
  if (-not (Test-Path $RegistryPath)) { return @() }
  $item = Get-ItemProperty -Path $RegistryPath -ErrorAction Stop
  if (-not $item.SavedOutboundAllowRules) { return @() }
  return @($item.SavedOutboundAllowRules | ConvertFrom-Json)
}

function Get-ActiveProfiles {
  return @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
}

function Get-KillSwitchStatus {
  $saved = Get-SavedState
  $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Group $Group -ErrorAction SilentlyContinue)
  $profiles = Get-ActiveProfiles
  $configuration = Get-SavedConfiguration
  $bypassRules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound `
    -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.Group -ne $Group })
  $allBlocked = $profiles.Count -eq 3 -and @($profiles | Where-Object {
    $_.DefaultOutboundAction.ToString() -ne 'Block' -or $_.Enabled.ToString() -ne 'True'
  }).Count -eq 0
  $tunRule = Test-TunnelRule $configuration
  $endpointRule = (Test-EndpointRule $configuration 'TCP') -and (Test-EndpointRule $configuration 'UDP')
  $expectedRuleNames = @(
    [string]$configuration.TunnelRuleName,
    [string]$configuration.EndpointTcpRuleName,
    [string]$configuration.EndpointUdpRuleName
  ) | Where-Object { $_ }
  $groupRuleNames = @($rules | ForEach-Object { $_.Name })
  $exactRules = $expectedRuleNames.Count -eq 3 -and $groupRuleNames.Count -eq 3 -and
    @($groupRuleNames | Where-Object { $expectedRuleNames -notcontains $_ }).Count -eq 0
  # An explicit Windows Firewall Allow rule takes precedence over the profile's
  # default Block action. Refuse to report a strict active state while one is
  # present; silently claiming protection here would be unsafe.
  $active = ($null -ne $saved) -and $allBlocked -and $tunRule -and $endpointRule -and $exactRules -and ($bypassRules.Count -eq 0)
  $caveat = 'No explicit outbound Allow rules were found in the effective firewall policy.'
  if ($bypassRules.Count -gt 0) {
    $caveat = 'Explicit outbound Allow rules are present and can bypass the profile default. Kill Switch is not considered active.'
  }
  $interfaceAlias = if ($configuration) { $configuration.TunAlias } else { $null }
  $endpointIp = if ($configuration) { $configuration.EndpointIp } else { $null }
  $endpointPort = if ($configuration) { $configuration.Port } else { $null }
  return @{
    active = $active
    configured = ($null -ne $saved)
    outboundBlocked = $allBlocked
    allProfilesEnabled = ($profiles.Count -eq 3 -and @($profiles | Where-Object { $_.Enabled.ToString() -ne 'True' }).Count -eq 0)
    tunnelRulePresent = $tunRule
    endpointRulesPresent = $endpointRule
    exactKillSwitchRules = $exactRules
    unmanagedOutboundAllowRuleCount = $bypassRules.Count
    interfaceAlias = $interfaceAlias
    endpointIp = $endpointIp
    port = $endpointPort
    enforcement = 'Windows Firewall outbound defaults'
    caveat = $caveat
  }
}

function Save-OriginalDefaults {
  $existing = Get-SavedState
  if ($null -ne $existing) { return $existing }
  $profiles = @(Get-NetFirewallProfile -PolicyStore PersistentStore -ErrorAction Stop)
  $snapshot = @{}
  foreach ($profile in $Profiles) {
    $match = $profiles | Where-Object { $_.Name -eq $profile } | Select-Object -First 1
    if ($null -eq $match) { throw "Could not read the saved outbound firewall policy for the $profile profile." }
    $snapshot[$profile] = $match.DefaultOutboundAction.ToString()
  }
  New-Item -Path $RegistryPath -Force | Out-Null
  New-ItemProperty -Path $RegistryPath -Name 'SavedOutboundDefaults' -Value ($snapshot | ConvertTo-Json -Compress) -PropertyType String -Force | Out-Null
  $allowRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound `
    -Action Allow -Enabled True -ErrorAction Stop | Where-Object { $_.Group -ne $Group })
  $ruleNames = @($allowRules | ForEach-Object { $_.Name })
  New-ItemProperty -Path $RegistryPath -Name 'SavedOutboundAllowRules' `
    -Value ($ruleNames | ConvertTo-Json -Compress) -PropertyType String -Force | Out-Null
  return $snapshot
}

function Disable-ExistingOutboundAllows {
  $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound `
    -Action Allow -Enabled True -ErrorAction Stop | Where-Object { $_.Group -ne $Group })
  foreach ($rule in $rules) {
    Set-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -Enabled False -ErrorAction Stop
  }
}

function Restore-ExistingOutboundAllows {
  foreach ($name in (Get-SavedAllowRuleNames)) {
    Set-NetFirewallRule -PolicyStore PersistentStore -Name ([string]$name) -Enabled True -ErrorAction Stop
  }
}

function Test-TunnelRule($Configuration) {
  if (-not $Configuration -or -not $Configuration.TunnelRuleName) { return $false }
  $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name ([string]$Configuration.TunnelRuleName) -ErrorAction SilentlyContinue
  if (-not $rule -or $rule.Enabled.ToString() -ne 'True' -or $rule.Direction.ToString() -ne 'Outbound' -or
      $rule.Action.ToString() -ne 'Allow' -or $rule.Group -ne $Group) { return $false }
  $interfaceFilter = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
  $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
  $interfaceAliases = @($interfaceFilter.InterfaceAlias)
  return ($interfaceFilter -and $interfaceAliases.Count -eq 1 -and
    [string]$interfaceAliases[0] -eq [string]$Configuration.TunAlias -and
    $portFilter -and $portFilter.Protocol.ToString() -eq 'Any' -and
    @($portFilter.LocalPort | Where-Object { $_ -ne 'Any' }).Count -eq 0 -and
    @($portFilter.RemotePort | Where-Object { $_ -ne 'Any' }).Count -eq 0)
}

function Test-EndpointRule($Configuration, [string]$Protocol) {
  if (-not $Configuration) { return $false }
  $nameProperty = if ($Protocol -eq 'TCP') { 'EndpointTcpRuleName' } else { 'EndpointUdpRuleName' }
  $ruleName = [string]$Configuration.$nameProperty
  if (-not $ruleName) { return $false }
  $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name $ruleName -ErrorAction SilentlyContinue
  if (-not $rule -or $rule.Enabled.ToString() -ne 'True' -or $rule.Direction.ToString() -ne 'Outbound' -or
      $rule.Action.ToString() -ne 'Allow' -or $rule.Group -ne $Group) { return $false }
  $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
  $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
  if (-not $addressFilter -or -not $portFilter -or $portFilter.Protocol.ToString() -ne $Protocol) { return $false }
  $expectedAddress = ([System.Net.IPAddress]::Parse([string]$Configuration.EndpointIp)).ToString()
  $remoteAddresses = @($addressFilter.RemoteAddress)
  $matchesAddress = $remoteAddresses.Count -eq 1 -and @($remoteAddresses | Where-Object {
    $candidate = $null
    [System.Net.IPAddress]::TryParse([string]$_, [ref]$candidate) -and $candidate.ToString() -eq $expectedAddress
  }).Count -eq 1
  $remotePorts = @($portFilter.RemotePort)
  return ($matchesAddress -and
    $remotePorts.Count -eq 1 -and [string]$remotePorts[0] -eq [string]$Configuration.Port -and
    @($portFilter.LocalPort | Where-Object { [string]$_ -ne 'Any' }).Count -eq 0)
}

function Add-KillSwitchRules([string]$Address, [int]$EndpointPort, [string]$InterfaceAlias) {
  $created = @()
  try {
    $created += New-NetFirewallRule -PolicyStore PersistentStore -DisplayName 'GhostBox Kill Switch - Tunnel' `
      -Group $Group -Direction Outbound -Action Allow -Profile Any -Enabled True `
      -InterfaceAlias $InterfaceAlias -Protocol Any
    foreach ($protocol in @('TCP', 'UDP')) {
      $created += New-NetFirewallRule -PolicyStore PersistentStore -DisplayName "GhostBox Kill Switch - Endpoint $protocol" `
        -Group $Group -Direction Outbound -Action Allow -Profile Any -Enabled True `
        -RemoteAddress $Address -RemotePort $EndpointPort -Protocol $protocol
    }
  } catch {
    foreach ($rule in $created) {
      Remove-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -ErrorAction SilentlyContinue
    }
    throw
  }
  return @($created | ForEach-Object { $_.Name })
}

function Remove-OldKillSwitchRules([string[]]$KeepNames) {
  $oldRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Group $Group -ErrorAction SilentlyContinue |
    Where-Object { $KeepNames -notcontains $_.Name })
  foreach ($rule in $oldRules) {
    Remove-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -ErrorAction Stop
  }
}

try {
  if ($Action -eq 'Status') {
    Write-Json (Get-KillSwitchStatus)
    exit 0
  }

  Assert-Administrator
  $service = Get-Service -Name 'mpssvc' -ErrorAction Stop
  if ($service.Status -ne 'Running') { throw 'Windows Defender Firewall service (mpssvc) is not running.' }

  if ($Action -eq 'Enable') {
    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($EndpointIp, [ref]$parsedAddress)) {
      throw 'The VPN endpoint must be resolved to a literal IPv4 or IPv6 address before enabling the Kill Switch.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'The VPN endpoint port is invalid.' }

    $hadSavedState = $null -ne (Get-SavedState)
    $previousConfiguration = Get-SavedConfiguration
    $createdRuleNames = @()
    $replacementVerified = $false
    if (-not $hadSavedState) { $CreatedStateThisRun = $true }
    $null = Save-OriginalDefaults
    try {
      Disable-ExistingOutboundAllows
      # Keep the prior exception rules installed until the replacement set is
      # created and verified. A failed server switch therefore cannot delete
      # the only rules that keep the already-armed Kill Switch usable.
      $createdRuleNames = Add-KillSwitchRules $parsedAddress.ToString() $Port $TunAlias
      $configuration = @{
        EndpointIp = $parsedAddress.ToString()
        Port = $Port
        TunAlias = $TunAlias
        TunnelRuleName = $createdRuleNames[0]
        EndpointTcpRuleName = $createdRuleNames[1]
        EndpointUdpRuleName = $createdRuleNames[2]
      } | ConvertTo-Json -Compress
      New-ItemProperty -Path $RegistryPath -Name 'Configuration' -Value $configuration -PropertyType String -Force | Out-Null
      Set-NetFirewallProfile -PolicyStore PersistentStore -Profile $Profiles -DefaultOutboundAction Block -ErrorAction Stop
      $status = Get-KillSwitchStatus
      $replacementReady = $status.outboundBlocked -and $status.allProfilesEnabled -and
        $status.tunnelRulePresent -and $status.endpointRulesPresent -and
        ($status.unmanagedOutboundAllowRuleCount -eq 0)
      if (-not $replacementReady) {
        if ($status.unmanagedOutboundAllowRuleCount -gt 0) {
          throw "Found $($status.unmanagedOutboundAllowRuleCount) enabled outbound Allow firewall rule(s). Those rules can bypass Kill Switch; disable or remove them, then try again. The original firewall policy was restored."
        }
        if (-not $status.allProfilesEnabled) {
          throw 'Windows Firewall must be enabled for Domain, Private, and Public profiles before Kill Switch can be active.'
        }
        throw 'Windows Firewall did not apply the requested Kill Switch rules or profile policy. Check Group Policy and the firewall service.'
      }
      $replacementVerified = $true
      # Only discard old exceptions after the replacement set has passed the
      # effective-policy and exact-filter checks above.
      Remove-OldKillSwitchRules $createdRuleNames
      $status = Get-KillSwitchStatus
      if (-not $status.active) { throw 'The replacement Kill Switch rules were not the only effective GhostBox exceptions.' }
      $status | Add-Member -NotePropertyName 'message' -NotePropertyValue 'Kill Switch firewall policy is active.'
      Write-Json $status
      exit 0
    } catch {
      if ($hadSavedState -and -not $replacementVerified) {
        foreach ($name in $createdRuleNames) {
          Remove-NetFirewallRule -PolicyStore PersistentStore -Name ([string]$name) -ErrorAction SilentlyContinue
        }
        if ($previousConfiguration) {
          $previousJson = $previousConfiguration | ConvertTo-Json -Compress
          New-ItemProperty -Path $RegistryPath -Name 'Configuration' -Value $previousJson -PropertyType String -Force | Out-Null
        } else {
          Remove-ItemProperty -Path $RegistryPath -Name 'Configuration' -ErrorAction SilentlyContinue
        }
      }
      throw
    }
  }

  if ($Action -eq 'Disable') {
    $saved = Get-SavedState
    if ($null -eq $saved) {
      Remove-NetFirewallRule -PolicyStore PersistentStore -Group $Group -ErrorAction SilentlyContinue
      Write-Json @{ active = $false; configured = $false; message = 'Kill Switch was already disabled.' }
      exit 0
    }
    Restore-ExistingOutboundAllows
    foreach ($profile in $Profiles) {
      Set-NetFirewallProfile -PolicyStore PersistentStore -Profile $profile `
        -DefaultOutboundAction $saved.$profile -ErrorAction Stop
    }
    Remove-NetFirewallRule -PolicyStore PersistentStore -Group $Group -ErrorAction Stop
    $effective = Get-ActiveProfiles
    foreach ($profile in $Profiles) {
      $expected = [string]$saved.$profile
      $current = [string](($effective | Where-Object { $_.Name -eq $profile } | Select-Object -First 1).DefaultOutboundAction)
      if ($current -ne $expected) {
        throw "Could not restore the $profile outbound firewall policy (expected $expected, got $current). Saved state is preserved for retry."
      }
    }
    Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
    Write-Json @{ active = $false; configured = $false; message = 'Original Windows Firewall outbound defaults restored.' }
    exit 0
  }
} catch {
  if ($CreatedStateThisRun) {
    try {
      $original = Get-SavedState
      if ($original) {
        Restore-ExistingOutboundAllows
        foreach ($profile in $Profiles) {
          Set-NetFirewallProfile -PolicyStore PersistentStore -Profile $profile `
            -DefaultOutboundAction $original.$profile -ErrorAction Stop
        }
      }
      Remove-NetFirewallRule -PolicyStore PersistentStore -Group $Group -ErrorAction SilentlyContinue
      Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      [Console]::Error.WriteLine("Rollback failed; the saved Kill Switch state was left in place: $($_.Exception.Message)")
    }
  }
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
