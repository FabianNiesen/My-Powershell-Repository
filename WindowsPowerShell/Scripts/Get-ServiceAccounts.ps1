
#gwmi win32_service |select name, startname|export-csv file.csv -notype
$services = gwmi  win32_service -ComputerName localhost 
foreach ($service in $services) {
		if ( ($service.startname -ne "LocalSystem") -or ($service.startname -or "NT Authority\LocalService") -or ($service.startname -ne "NT AUTHORITY\NETWORK SERVICE") -or ($service.StartName -ne "NT AUTHORITY\NetworkService")) {
		select $service.name, $service.StartName | ft
		}
}
