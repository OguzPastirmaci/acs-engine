<#
    .SYNOPSIS
        Provisions VM as a Kubernetes agent.

    .DESCRIPTION
        Provisions VM as a Kubernetes agent.
#>
[CmdletBinding(DefaultParameterSetName="Standard")]
param(
    [string]
    [ValidateNotNullOrEmpty()]
    $MasterIP,

    [parameter()]
    [ValidateNotNullOrEmpty()]
    $KubeDnsServiceIp,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $MasterFQDNPrefix,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $Location,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $AgentKey,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $AzureHostname
)

$global:CACertificate = "<<<caCertificate>>>"
$global:AgentCertificate = "<<<clientCertificate>>>"
$global:DockerServiceName = "Docker"
$global:RRASServiceName = "RemoteAccess"
$global:KubeDir = "c:\k"
$global:KubeBinariesSASURL = "https://acsengine.blob.core.windows.net/v1-5-1/k.zip"
$global:KubeletStartFile = $global:KubeDir + "\kubeletstart.ps1"
$global:KubeProxyStartFile = $global:KubeDir + "\kubeproxystart.ps1"

filter Timestamp {"$(Get-Date -Format o): $_"}

function
Write-Log($message)
{
    $msg = $message | Timestamp
    Write-Output $msg
}

function
Expand-ZIPFile($file, $destination)
{
    $shell = new-object -com shell.application
    $zip = $shell.NameSpace($file)
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}

function
Get-KubeBinaries()
{
    $zipfile = "c:\k.zip"
    Invoke-WebRequest -Uri $global:KubeBinariesSASURL -OutFile $zipfile
    Expand-ZIPFile -File $zipfile -Destination C:\
}

function
Write-KubeConfig()
{
    $kubeConfigFile = $global:KubeDir + "\config"

    $kubeConfig = @"
---
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: "$global:CACertificate"
    server: https://$MasterFQDNPrefix.$Location.cloudapp.azure.com
  name: "$MasterFQDNPrefix"
contexts:
- context:
    cluster: "$MasterFQDNPrefix"
    user: "$MasterFQDNPrefix-admin"
  name: "$MasterFQDNPrefix"
current-context: "$MasterFQDNPrefix"
kind: Config
users:
- name: "$MasterFQDNPrefix-admin"
  user:
    client-certificate-data: "$global:AgentCertificate"
    client-key-data: "$AgentKey"
"@

    $kubeConfig | Out-File -encoding ASCII -filepath "$kubeConfigFile"    
}

function
New-InfraContainer()
{
    cd $global:KubeDir
    docker build -t kubletwin/pause . 
}

function
Get-PodCIDR
{
    $argList = @("--hostname-override=$AzureHostname","--pod-infra-container-image=kubletwin/pause","--resolv-conf=""""","--api-servers=https://${MasterIP}:443","--kubeconfig=c:\k\config")
    $process = Start-Process -FilePath c:\k\kubelet.exe -PassThru -ArgumentList $argList

    $podCidrDiscovered=$false
    $podCIDR=""
    # run kubelet until podCidr is discovered
    Write-Host "waiting to discover pod CIDR"
    while (-not $podCidrDiscovered)
    {
        $podCIDR=c:\k\kubectl.exe --kubeconfig=c:\k\config get nodes/$AzureHostname -o custom-columns=podCidr:.spec.podCIDR --no-headers

        if ($podCIDR.length -gt 0)
        {
            $podCidrDiscovered=$true
        }
        else
        {
            Write-Host "Sleeping for 10s, and then waiting to discover pod CIDR"
            Start-Sleep -sec 10    
        }
    }
    
    # stop the kubelet process now that we have our CIDR, discard the process output
    $process | Stop-Process | Out-Null
    
    return $podCIDR
}

function
Write-KubeletStartFile($podCIDR)
{
    $kubeConfig = @"
`$env:CONTAINER_NETWORK="transparentNet"
c:\k\kubelet.exe --hostname-override=$AzureHostname --pod-infra-container-image=kubletwin/pause --resolv-conf="" --allow-privileged=true --enable-debugging-handlers --api-servers=https://${MasterIP}:443 --cluster-dns=$KubeDnsServiceIp --cluster-domain=cluster.local  --kubeconfig=c:\k\config --hairpin-mode=promiscuous-bridge --v=2
"@
    $kubeConfig | Out-File -encoding ASCII -filepath $global:KubeletStartFile

    $kubeProxyStartStr = @"
`$nodeIP=""
`$aliasName="vEthernet (HNS Internal NIC)"
while (`$true)
{
    try
    {
        `$nodeNic=Get-NetIPaddress -InterfaceAlias `$aliasName -AddressFamily IPv4
        #bind to the docker IP address
        `$nodeIP=`$nodeNic.IPAddress | Where-Object {`$_.StartsWith("172.")} | Select-Object -First 1
        break
    }
    catch
    {
        Write-Output "sleeping for 10s since `$aliasName is not defined"
        Start-Sleep -sec 10
    }
}

`$env:INTERFACE_TO_ADD_SERVICE_IP=`$aliasName
c:\k\kube-proxy.exe --v=3 --proxy-mode=userspace --hostname-override=$AzureHostname --master=${MasterIP}:8080 --bind-address=`$nodeIP --kubeconfig=c:\k\config
"@

    $kubeProxyStartStr | Out-File -encoding ASCII -filepath $global:KubeProxyStartFile
}

function
Set-DockerNetwork($podCIDR)
{
    $podGW=$podCIDR.substring(0,$podCIDR.lastIndexOf('.')) + ".1"

    # Turn off Firewall to enable pods to talk to service endpoints. (Kubelet should eventually do this)
    netsh advfirewall set allprofiles state off

    # configure docker network
    net stop docker
    Get-ContainerNetwork | Remove-ContainerNetwork -Force
    
    # set the docker service to start without a network
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Docker"
    $registryProperty = "ImagePath"
    $registryValue = "C:\Program Files\Docker\dockerd.exe --run-service -b none"
    New-ItemProperty -Path $registryPath -Name $registryProperty -Value $registryValue -PropertyType ExpandString -Force
    net start docker 

    # create new transparent network
    docker network create --driver=transparent --subnet=$podCIDR --gateway=$podGW transparentNet

    # create host vnic for gateway ip to forward the traffic and kubeproxy to listen over VIP
    Add-VMNetworkAdapter -ManagementOS -Name forwarder -SwitchName "Layered Ethernet 3"

    # Assign gateway IP to new adapter and enable forwarding on host adapters:
    netsh interface ipv4 add address "vEthernet (forwarder)" $podGW 255.255.255.0
    netsh interface ipv4 set interface "vEthernet (forwarder)" for=en
    netsh interface ipv4 set interface "vEthernet (HNSTransparent)" for=en
    netsh advfirewall set allprofiles state off
}

function
New-NSSMService
{
    # setup kubelet
    c:\k\nssm install Kubelet C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    c:\k\nssm set Kubelet AppDirectory $global:KubeDir
    c:\k\nssm set Kubelet AppParameters $global:KubeletStartFile
    c:\k\nssm set Kubelet DisplayName Kubelet
    c:\k\nssm set Kubelet Description Kubelet
    c:\k\nssm set Kubelet Start SERVICE_AUTO_START
    c:\k\nssm set Kubelet ObjectName LocalSystem
    c:\k\nssm set Kubelet Type SERVICE_WIN32_OWN_PROCESS
    c:\k\nssm set Kubelet AppThrottle 1500
    c:\k\nssm set Kubelet AppStdout C:\k\kubelet.log
    c:\k\nssm set Kubelet AppStderr C:\k\kubelet.err.log
    c:\k\nssm set Kubelet AppStdoutCreationDisposition 4
    c:\k\nssm set Kubelet AppStderrCreationDisposition 4
    c:\k\nssm set Kubelet AppRotateFiles 1
    c:\k\nssm set Kubelet AppRotateOnline 1
    c:\k\nssm set Kubelet AppRotateSeconds 86400
    c:\k\nssm set Kubelet AppRotateBytes 1048576
    net start Kubelet
    
    # setup kubeproxy
    # disabled by default since kube-proxy is still experimental, adding
    # service logic and describing dependency on kubelet
    if ($false) {
        c:\k\nssm install Kubeproxy C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
        c:\k\nssm set Kubeproxy AppDirectory $global:KubeDir
        c:\k\nssm set Kubeproxy AppParameters $global:KubeProxyStartFile
        c:\k\nssm set Kubeproxy DisplayName Kubeproxy
        c:\k\nssm set Kubeproxy DependOnService Kubelet
        c:\k\nssm set Kubeproxy Description Kubeproxy
        c:\k\nssm set Kubeproxy Start SERVICE_AUTO_START
        c:\k\nssm set Kubeproxy ObjectName LocalSystem
        c:\k\nssm set Kubeproxy Type SERVICE_WIN32_OWN_PROCESS
        c:\k\nssm set Kubeproxy AppThrottle 1500
        c:\k\nssm set Kubeproxy AppStdout C:\k\kubeproxy.log
        c:\k\nssm set Kubeproxy AppStderr C:\k\kubeproxy.err.log
        c:\k\nssm set Kubeproxy AppRotateFiles 1
        c:\k\nssm set Kubeproxy AppRotateOnline 1
        c:\k\nssm set Kubeproxy AppRotateSeconds 86400
        c:\k\nssm set Kubeproxy AppRotateBytes 1048576
        net start Kubeproxy
    }
}

try
{
    # Set to false for debugging.  This will output the start script to
    # c:\AzureData\CustomDataSetupScript.log, and then you can RDP 
    # to the windows machine, and run the script manually to watch
    # the output.
    if ($true) {
        Write-Log "Provisioning $global:DockerServiceName... with IP $MasterIP"

        Write-Log "download kubelet binaries and unzip"
        Get-KubeBinaries

        Write-Log "Write kube config"
        Write-KubeConfig

        Write-Log "Create the Pause Container kubletwin/pause"
        New-InfraContainer

        Write-Log "Get the POD CIDR"
        $podCIDR = Get-PodCIDR

        Write-Log "write kubelet startfile with pod CIDR of $podCIDR"
        Write-KubeletStartFile $podCIDR

        Write-Log "setup docker network with pod CIDR of $podCIDR"
        Set-DockerNetwork $podCIDR

        Write-Log "install the NSSM service"
        New-NSSMService
        
        Write-Log "Setup Complete"
    }
    else 
    {
        # keep for debugging purposes
        Write-Log ".\CustomDataSetupScript.ps1 -MasterIP $MasterIP -KubeDnsServiceIp $KubeDnsServiceIp -MasterFQDNPrefix $MasterFQDNPrefix -Location $Location -AgentKey $AgentKey -AzureHostname $AzureHostname"
    }
}
catch
{
    Write-Error $_
}