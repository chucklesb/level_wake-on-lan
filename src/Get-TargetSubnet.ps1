$TargetCidr="{{cf_wake-on-lan_subnet}}"
if (($TargetCidr -like "{{*}}") -or 
    [string]::IsNullOrWhiteSpace($TargetCidr)) {
    Write-Error "Wake-On-LAN Subnet custom field is undefined."
    exit 1
} else {
    {{TargetCidr=$TargetCidr}}
}
