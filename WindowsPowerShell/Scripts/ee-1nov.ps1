#Load WebAdmin Snap-in if needed.
$iisVersion = Get-ItemProperty "HKLM:\software\microsoft\InetStp";


    Import-Module WebAdministration;

$WebAppPoolNames = @("Pool_site1","Pool_site2","Pool_site3", "Pool_site4")

ForEach ($WebAppPoolName in $WebAppPoolNames ) {
    #$WebAppPool = New-WebAppPool -Name $WebAppPoolName  
    #$WebAppPool.processModel.identityType = "SpecificUser"
    #$WebAppPool.processModel.username = $WebAppPoolName
    #$WebAppPool.processModel.password = $WebAppPoolPassword
    #$WebAppPool.managedPipelineMode = "Integrated"
    #$WebAppPool.managedRuntimeVersion = "v2.0"
    #$WebAppPool | set-item
}

$WebSiteNames = @("site1.com","site2.com","site3.com", "site4.com")
$ipAddress = "10.10.X.XXX"
$WebAppPoolPassword = "passwordhidden"

ForEach ($WebSiteName in $WebSiteNames ) {
    # This line shows the values from the $WebAppPoolNames correctly, in the order which they need ot be applied
	$WebAppPoolNames | % {$i=0} {$_; $i++}
    New-Website –Name $WebSiteName –Port 80 -IPAddress $ipAddress –HostHeader $WebSiteName –PhysicalPath ("D:\inetpub\wwwroot\cms\" + $WebSiteName)
    New-WebBinding -Name $WebSiteName -Port 80 -IPAddress $ipAddress -HostHeader ("www1." + $WebSiteName)
    New-WebBinding -Name $WebSiteName -Port 80 -IPAddress $ipAddress -HostHeader ("www." + $WebSiteName)
    # Type mismatch starts here
	Set-ItemProperty ("IIS:\Sites\" + $WebSiteName) -name applicationPool -value $WebAppPoolNames | % {$i=0} {$_; $i++}
    Set-ItemProperty ("IIS:\Sites\" + $WebSiteName) -name ApplicationDefaults.applicationPool -value $WebAppPoolNames | % {$i=0} {$_; $i++}
    # This may error out too
	Set-ItemProperty ("IIS:\Sites\" + $WebSiteName) -name ..username -value $WebAppPoolName
    Set-ItemProperty ("IIS:\Sites\" + $WebSiteName) -name ..password -value $WebAppPoolPassword
}

