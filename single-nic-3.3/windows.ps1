# Run in an elevated PowerShell console inside the isolated Windows VM.
$ErrorActionPreference = 'Stop'
$nic = @(Get-NetAdapter | Where-Object Status -eq 'Up')
if ($nic.Count -ne 1) { throw 'Expected exactly one isolated network adapter' }
$index = $nic[0].ifIndex
Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
$old = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Where-Object IPAddress -notlike '169.254.*')
if ($old | Where-Object IPAddress -ne '10.50.0.20') { throw 'Unexpected existing address; inspect before changing it' }
if (-not ($old | Where-Object IPAddress -eq '10.50.0.20')) {
    New-NetIPAddress -InterfaceIndex $index -IPAddress 10.50.0.20 -PrefixLength 24 | Out-Null
}
if (Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) {
    throw 'Unexpected default gateway; remove it in the adapter IPv4 settings first'
}
Disable-NetAdapterBinding -Name $nic[0].Name -ComponentID ms_tcpip6 | Out-Null
# Keep mirrored virtual traffic in ordinary packets with complete checksums.
Disable-NetAdapterChecksumOffload -Name $nic[0].Name -ErrorAction SilentlyContinue
Disable-NetAdapterLso -Name $nic[0].Name -ErrorAction SilentlyContinue
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-CommonHttpFeatures,IIS-StaticContent,IIS-DefaultDocument -All -NoRestart | Out-Null
Set-Content C:\inetpub\wwwroot\index.html 'SO LAB Windows victim: IIS ready'
if (-not (Get-NetFirewallRule -Name 'SO-LAB-HTTP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'SO-LAB-HTTP' -DisplayName 'SO LAB HTTP' -Direction Inbound -Protocol TCP -LocalPort 80 -RemoteAddress 10.50.0.0/24 -Action Allow | Out-Null
}
if (-not (Get-NetFirewallRule -Name 'SO-LAB-ICMP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'SO-LAB-ICMP' -DisplayName 'SO LAB ICMP' -Direction Inbound -Protocol ICMPv4 -RemoteAddress 10.50.0.0/24 -Action Allow | Out-Null
}
Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4
Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4
Get-Service W3SVC
