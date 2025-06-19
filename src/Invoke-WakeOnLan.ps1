### Invoke-WakeOnLan.ps1 - Send a WOL magic packet to a given MAC address and target subnet
# Intended for Level RMM automation.

## Level RMM variables
$level_MacAddress = "{{MacAddress}}"
$level_TargetCidr = "{{TargetCidr}}"

## Logging and error handling
$LogName = "Invoke-WakeOnLan-$(Get-Date -UFormat %s).log"
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
        Write-Host $LogEntry
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
        Resolve-Error "Failed to convert IP string '$IpAddressString' to UInt32: $($_.Exception.Message)"
    }
}

function Get-BroadcastAddress {
    param(
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

        $NetworkUInt32 = Convert-IpToUInt32 -IpAddressString $NetworkAddressString
        if ($null -eq $NetworkUInt32) {
            throw "Network address conversion failed"
        }

        # Create subnet mask
        $MaskUInt32 = if ($PrefixLength -eq 0) {
            [uint32]0
        } else {
            ([uint32]::MaxValue) -shl (32 - $PrefixLength)
        }

        # Calculate broadcast: network address OR inverted subnet mask
        $BroadcastUInt32 = $NetworkUInt32 -bor (-bnot $MaskUInt32)

        # Convert to dotted-decimal notation
        $BroadcastIp = [IPAddress]($BroadcastUInt32).ToString()
        return $BroadcastIp
    }
    catch {
        Resolve-Error "Failed to calculate broadcast address for '$CidrString': $($_.Exception.Message)"
    }
}

function Invoke-WakeOnLan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$MacAddress,

        [Parameter(Mandatory = $true)]
        [string]$TargetCidr
    )

    # Validate MAC address and convert to bytes
    $MacPattern = "^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$"
    if ($MacAddress -notmatch $MacPattern) {
        Resolve-Error "Invalid MAC address format. Acceptable formats are 00:11:22:AA:BB:CC or 00-11-22-AA-BB-CC."
    }
    $MacBytes = $MacAddress -split '[-:]' | ForEach-Object { [Convert]::ToByte($_, 16) }

    # Validate target subnet CIDR and get broadcast address
    $CidrPattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/(3[0-2]|[1-2][0-9]|[0-9])$"
    if ($TargetCidr -notmatch $CidrPattern) {
        Resolve-Error "Invalid target subnet."
    }
    $BroadcastAddress = (Get-BroadcastAddress -CidrString $TargetCidr).IPAddressToString

    # Construct header and packet
    $Header = [byte[]](255, 255, 255, 255, 255, 255)
    $Packet = $Header + ($MacBytes * 16)

    # Open UDP socket and send Wake-On-LAN magic packet
    try {
        $UdpClient = New-Object System.Net.Sockets.UdpClient
        $UdpClient.EnableBroadcast = $true
        $UdpClient.Connect($BroadcastAddress, 9)
        $BytesSent = $UdpClient.Send($Packet, $Packet.Length)
        Write-LogMessage "Wake-On-LAN packet sent to $MacAddress ($BytesSent bytes)." -Type Success
    } catch {
        Resolve-Error "Failed to send Wake-On-Lan packet: $_"
    } finally {
        $UdpClient.Close()
    }
}

## Entry point
Invoke-WakeOnLan -MacAddress $level_MacAddress -TargetCidr $level_TargetCidr
