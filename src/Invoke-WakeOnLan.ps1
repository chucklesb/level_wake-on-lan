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
        # Split IP address into octets and validate
        $Octets = $IpAddressString.Split('.')
        if ($Octets.Count -ne 4) {
            throw "Invalid IPv4 address format: $IpAddressString"
        }

        [int]$parsed = 0
        [int[]]$OctetsInt = @()

        foreach ($Octet in $Octets) {
            if (-not [int]::TryParse($Octet, [ref]$parsed) -or
                $parsed -lt 0 -or $parsed -gt 255) {
                throw "Invalid IP address octet `'$($Octet)`' in `'$($IpAddressString)`'."
            }
            $OctetsInt += $parsed
        }

        # Convert IP to integer representation
        $IpUInt32 = ([uint32]$OctetsInt[0] -shl 24) -bor
                    ([uint32]$OctetsInt[1] -shl 16) -bor
                    ([uint32]$OctetsInt[2] -shl 8)  -bor
                    ([uint32]$OctetsInt[3])
        return $IpUInt32
    }
    catch {
        Resolve-Error "Convert-IpToUInt32: $($_.Exception.Message)"
    }
}

function Get-BroadcastAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CidrString
    )

    try {
        # Validate and split CIDR string
        $CidrParts = $CidrString.Split('/')
        if ($CidrParts.Count -ne 2) {
            throw "Invalid CIDR format for `'$($CidrString)`' (valid format A.B.C.D/M)"
        }

        $Network = $CidrParts[0]
        $Mask = [int]$CidrParts[1]

        # Convert IP to integer
        $NetworkUInt32 = Convert-IpToUInt32 -IpAddressString $Network
        if ($null -eq $NetworkUInt32) {
            throw "Network address conversion failed"
        }

        # Validate and calculate netmask
        if ($Mask -lt 0 -or $Mask -gt 32) {
            throw "Invalid CIDR mask `'$($Mask)`' (valid range 0..32)."
        }
        $MaskUInt32 = if ($Mask -eq 0) {
            [uint32]0
        } else {
            ([uint32]::MaxValue) -shl (32 - $Mask)
        }

        # Calculate broadcast address
        $BroadcastUInt32 = $NetworkUInt32 -bor (-bnot $MaskUInt32)

        # Convert back to dotted-decimal
        $BroadcastIp = [IPAddress]($BroadcastUInt32).ToString()
        return $BroadcastIp
    }
    catch {
        Resolve-Error "Get-BroadcastAddress: $($_.Exception.Message)"
    }
}

function Get-NormalizedMac {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputMac
    )

    try {
        # Remove delimiters and convert to uppercase
        $CleanMac = ($InputMac -replace '[^a-zA-Z0-9]').ToUpper()

        # Validate input MAC
        if ($CleanMac -notmatch '^[0-9A-F]{12}$') {
            throw "Invalid MAC address: $InputMac"
        }

        # Convert to byte array
        $ByteArray = @()
        for ($i = 0; $i -lt 12; $i += 2) {
            $ByteArray += [Convert]::ToByte($CleanMac.Substring($i, 2), 16)
        }
    } catch {
        Resolve-Error "Get-NormalizedMac: $($_.Exception.Message)"
    }

    return $ByteArray
}

function Invoke-WakeOnLan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$MacAddress,

        [Parameter(Mandatory = $true)]
        [string]$TargetCidr
    )

    # Convert MAC address to byte array and normalized string
    $MacBytes = Get-NormalizedMac -InputMac $MacAddress
    $MacString = ($MacBytes | ForEach-Object { $_.ToString("x2") }) -join ':'
    Write-LogMessage "Target MAC: $MacString"

    # Calculate subnet broadcast address
    $BroadcastAddress = (Get-BroadcastAddress -CidrString $TargetCidr).IPAddressToString
    Write-LogMessage "Broadcast address: $BroadcastAddress"

    # Construct Wake-On-LAN magic packet
    $Packet = [byte[]](0xFF) * 6
    $Packet += ($MacBytes * 16)

    # Open UDP socket and send Wake-On-LAN magic packet
    try {
        $UdpClient = New-Object System.Net.Sockets.UdpClient
        $UdpClient.EnableBroadcast = $true
        $UdpClient.Connect($BroadcastAddress, 9)
        $BytesSent = $UdpClient.Send($Packet, $Packet.Length)

        if ($BytesSent -eq 102) {
            # Simulate socat -v output
            Write-Output "> $(Get-Date -Format "yyyy/MM/dd HH:mm:ss.fffffff")  length=$($BytesSent) from=0 to=$($BytesSent - 1)"
            [System.BitConverter]::ToString($Packet).Replace('-',' ').ToLower()
            Write-LogMessage "Wake-On-LAN packet sent to $($MacString)." -Type Success
        } else {
            throw "Invalid packet size ($BytesSent bytes)."
        }
    } catch {
        Resolve-Error "Invoke-WakeOnLan: Failed to send Wake-On-Lan packet: $_"
    } finally {
        $UdpClient.Close()
    }
}

## Entry point
Write-Host "Logging to file: $LogPath"
Invoke-WakeOnLan -MacAddress $level_MacAddress -TargetCidr $level_TargetCidr