$computername = Read-Host "Computer Name"
$computer = Get-WmiObject -ComputerName $computername Win32_SystemEnclosure
$chassis = $computer.ChassisTypes
switch ($chassis) {
	1 { $type = "Other"
		break 	}
	2 { $type= "Unknown"
		break }
	3 { $type="Desktop"
		break; 	}
	4 { $type="Low Profile Desktop"
		break; }
	5 {		$type="Pizza Box"
		break;		}
	6 {
		$type="Mini Tower"
		break;
		}
	7 {
		$type="Tower"
		break;
		}
	8 {
		$type="Portable"
		break;
		}
	9 {
		$type="Laptop"
		break;
		}
	10 {
		$type="Notebook"
		break;
		}
	11 {
		$type="Handheld"
		break;
		}
	12 {
		$type="Docking Station"
		break;
		}
	13 {
		$type="All-in-One"
		break;
		}
	14 {
		$type="Sub-Notebook"
		break;
		}
	15 {
		$type="Space Saving"
		break;
		}
	16 {
		$type="Lunch Box"
		break;
		}
	17 {
		$type="Main System Chassis"
		break;
		}
	18 {
		$type="Expansion Chassis"
		break;
		}
	19 {
		$type="Sub-Chassis"
		break;
		}
	20 { $type="Bus Expansion Chassis"
		break;
		}
	21	{ $type="Peripheral Chassis"
		break; 
		}
	22 {
		$type="Storage Chassis"
		break; }
	23 { $type="Rack Mount Chassis"
		break; }
	24 {$type="Sealed-Case PC"
		break; }
	default { $type = "Unknown"
		break }
}
Write-host  $computername "is a " $type