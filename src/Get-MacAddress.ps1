### Get-MacAddress.ps1 - Get the primary Ethernet adapter's MAC address
# This script retrieves the MAC address of the system's preferred physical 
# Ethernet adapter. It selects the adapter by first checking for a match in a 
# specified IPv4 CIDR subnet. If multiple matches are found, it prefers the one 
# with the lowest IPv4 interface metric. If no matches are found, it falls back 
# to the adapter with the lowest default route metric. This script is designed 
# specifically for IPv4 and physical Ethernet adapters. It intentionally 
# ignores Wi-Fi and virtual adapters, as its primary use case is to identify a 
# MAC address suitable for Wake-On-LAN, which typically only works with wired 
# network interfaces.
# Intended for Level RMM automation.

## Level RMM variables
$level_TargetCidr = "{{TargetCidr}}"

## Logging and error handling
$LogName = "Get-MacAddress-$(Get-Date -UFormat %s).log"
$LogPath = Join-Path -Path $env:TEMP -ChildPath $LogName

function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Error", "Warning", "Debug", "Info", "Success")]
        [string]$Type = "Info",

        [Parameter(Mandatory = $false)]
        [bool]$IncludeTimestamp = $true,

        [Parameter(Mandatory = $false)]
        [bool]$IncludeType = $true,

        [Parameter(Mandatory = $false)]
        [bool]$LogToFile = $true,

        [Parameter(Mandatory = $false)]
        [bool]$LogToConsole = $true
    )

    if ($IncludeTimestamp) {
        $Timestamp = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] "   
    }
    if ($IncludeType) {
        $strType = "$($Type.ToUpper()): "
    }

    $LogEntry = "$($Timestamp)$($strType)$($Message)"
    
    if ($LogToFile) {
        Add-Content -Path $LogPath -Value $LogEntry
    }
    if ($LogToConsole) {
        Write-Output $LogEntry
    }
}

function Resolve-Error {
    param([string]$ErrorMessage)
    
    Write-LogMessage $ErrorMessage -Type "Error"
    exit 1
}

## Main functions
function Convert-IpToUInt32 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddressString
    )

    try {
        $Octets = $IpAddressString.Split('.') | ForEach-Object { [System.Convert]::ToByte($_) }
        if ($Octets.Count -ne 4) {
            throw "Invalid IPv4 address format: $IpAddressString"
        }
        # Big-endian: (octet1 << 24) + (octet2 << 16) + (octet3 << 8) + octet4
        $IpUInt32 = ([uint32]$Octets[0] -shl 24) + `
                    ([uint32]$Octets[1] -shl 16) + `
                    ([uint32]$Octets[2] -shl 8) + `
                    ([uint32]$Octets[3])
        return $IpUInt32
    }
    catch {
        Write-LogMessage "Failed to convert IP string '$IpAddressString' to UInt32: $($_.Exception.Message)" -Type Warning
        return $null
    }
}

function Test-IpInCidr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddressString,

        [Parameter(Mandatory = $true)]
        [string]$CidrString
    )

    try {
        $CidrParts = $CidrString.Split('/')
        if ($CidrParts.Count -ne 2) {
            throw "Invalid CIDR format: $CidrString"
        }

        $NetworkAddressString = $CidrParts[0]
        $PrefixLength = [int]$CidrParts[1]

        if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
            throw "Invalid CIDR prefix length (must be 0-32): $PrefixLength"
        }

        $IpUInt32 = Convert-IpToUInt32 -IpAddressString $IpAddressString
        $NetworkBaseUInt32 = Convert-IpToUInt32 -IpAddressString $NetworkAddressString

        if ($null -eq $IpUInt32 -or $null -eq $NetworkBaseUInt32) {
            throw "CIDR conversion failed"
        }

        # Create the subnet mask as a UInt32
        $MaskUInt32 = if ($PrefixLength -eq 0) {
            [uint32]0
        } else {
            ([uint32]::MaxValue) -shl (32 - $PrefixLength)
        }

        # An IP is in the subnet if (IP_Address AND Subnet_Mask) == (Network_Address AND Subnet_Mask)
        # The (Network_Address AND Subnet_Mask) part effectively gives the true start of the network.
        $IpNetworkPart = $IpUInt32 -band $MaskUInt32
        $TargetNetworkPart = $NetworkBaseUInt32 -band $MaskUInt32 # Cleans the provided network address

        return $IpNetworkPart -eq $TargetNetworkPart
    }
    catch {
        Write-LogMessage "Error in Test-IpInCidr for IP '$IpAddressString' and CIDR '$CidrString': $($_.Exception.Message)" -Type Warning
        return $false
    }
}

function Get-MacAddress {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$TargetCidr
    )

    $OldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    try {
        # Get physical, 'Up', Ethernet adapters
        $NetAdapters = @(Get-NetAdapter -Physical | Where-Object {
            $_.InterfaceType -eq 6 -and $_.Status -eq 'Up'
        })

        Write-LogMessage "Found $($NetAdapters.Count) physical, 'Up', Ethernet adapter(s): $($NetAdapters.Name -join ', ')"

        if ($NetAdapters.Count -ge 1) {
            if ($NetAdapters.Count -eq 1) {
                # One suitable network adapter, no further tests needed
                $MacAddress = "$($NetAdapters[0].MacAddress)"
                Write-LogMessage "Selecting the only suitable adapter: $($NetAdapters[0].Name). MAC: $($MacAddress)." -Type Success
                {{MacAddress=$MacAddress}}
                exit 0
            }

            if (($TargetCidr -like "{{*}}") -or [string]::IsNullOrWhiteSpace($TargetCidr)) {
                Write-LogMessage "Target CIDR not specified. Skipping subnet matching." -Type Warning
            } else {
                # Match adapters with an IPv4 address in the target subnet
                Write-LogMessage "Target CIDR '$($TargetCidr)' specified. Attempting to match adapters."
                $MatchingAdapters = @(foreach ($NetAdapter in $NetAdapters) {
                    $NetIPConfigurations = Get-NetIPConfiguration -InterfaceIndex $NetAdapter.IfIndex -ErrorAction SilentlyContinue
                    $FoundMatch = $false
                    foreach ($NetIPConfiguration in $NetIPConfigurations) {
                        foreach ($IPv4Address in $NetIPConfiguration.IPv4Address.IPAddress) {
                            if (Test-IpInCidr -IpAddressString $IPv4Address -CidrString $TargetCidr) {
                                Write-LogMessage "Adapter '$($NetAdapter.Name)' (IP: $($IPv4Address)) matches CIDR '$($TargetCidr)'."
                                $FoundMatch = $true
                                break
                            }
                        }
                        if ($FoundMatch) { break }
                    }
                    if ($FoundMatch) { $NetAdapter }
                })

                if (!$MatchingAdapters) {
                    Write-LogMessage "No adapters matching target CIDR found." -Type Warning
                }

                if ($MatchingAdapters.Count -eq 1) {
                    # One adapter matching target subnet found, no further tests needed
                    $MacAddress = "$($MatchingAdapters[0].MacAddress)"
                    Write-LogMessage "Single adapter matching CIDR identified: $($MatchingAdapters[0].Name). MAC: $($MacAddress)." -Type Success
                    {{MacAddress=$MacAddress}}
                    exit 0
                }

                if ($MatchingAdapters.Count -gt 1) {
                    # Multiple adapters matching target subnet found, select preferred adapter based on lowest InterfaceMetric
                    Write-LogMessage "Multiple CIDR-matching adapters found ($($MatchingAdapters.Name -join ', ')). Selecting by lowest InterfaceMetric."

                    $MatchingAdaptersWithMetrics = foreach ($MatchingAdapter in $MatchingAdapters) {
                        $NetIPInterface = Get-NetIPInterface -InterfaceIndex $MatchingAdapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object InterfaceMetric | Select-Object -First 1
                        $Metric = if ($NetIPInterface -and ($null -ne $NetIPInterface.InterfaceMetric)) {
                            $NetIPInterface.InterfaceMetric
                        } else {
                            [int]::MaxValue  # Assign a high value to deprioritize this adapter
                        }
                        $MatchingAdapter | Add-Member -NotePropertyName InterfaceMetric -NotePropertyValue $Metric -PassThru
                    }
                    $SelectedAdapter = $MatchingAdaptersWithMetrics | Sort-Object InterfaceMetric | Select-Object -First 1

                    $MacAddress = "$($SelectedAdapter.MacAddress)"
                    Write-LogMessage "Selected adapter $($SelectedAdapter.Name) with InterfaceMetric $($SelectedAdapter.InterfaceMetric). MAC: $($MacAddress)." -Type Success
                    {{MacAddress=$MacAddress}}
                    exit 0
                }
            }

            # Fallback: choose adapter with lowest route metric to 0.0.0.0/0
            Write-LogMessage "Selecting adapter with lowest default route metric."
            $DefaultRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -in $NetAdapters.IfIndex }

            if ($DefaultRoutes) {
                $BestRoute = $DefaultRoutes | Sort-Object RouteMetric | Select-Object -First 1
                $BestAdapter = $NetAdapters | Where-Object { $_.IfIndex -eq $BestRoute.InterfaceIndex }
                $MacAddress = "$($BestAdapter.MacAddress)"
                Write-LogMessage "Selected adapter $($BestAdapter.Name) via lowest default route metric ($($BestRoute.RouteMetric)). MAC: $($MacAddress)." -Type Success
                {{MacAddress=$MacAddress}}
                exit 0
            }
        }

        throw "No suitable network adapters found."
    } catch {
        Resolve-Error "$($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $OldErrorActionPreference
    }
}

## Entry point
Get-MacAddress -TargetCidr $level_TargetCidr
