<#
.Synopsis
   Get a list of the installed applications on a (remote) computer.
.DESCRIPTION
Using WMI (Win32_Product), this script will query a (remote) computer for all installed applications and output the results.
   If required, these results can be exported or printed on screen.
   Please keep in mind that you need to have access to the (remote) computer’s WMI classes.
.EXAMPLE
   To simply list the installed applications, use the script as follows:
   
   Get-InstalledApplications -computer <computername>

.EXAMPLE
   If required, the output of the script can be modified. For instance, viewing the results on screen:
   
   Get-InstalledApplications -computer <computername> | Out-GridView
#>
function Get-InstalledApplications3
{
   [CmdletBinding()]
   [OutputType([int])]
   Param
   (
      # defines what computer you want to see the inventory for
      [Parameter(Mandatory=$true,
      ValueFromPipelineByPropertyName=$true,
      Position=0)]
      $computer
   )

   Begin
   {
   }

   Process
   {
      $win32_product = @(get-wmiobject -class ‘Win32_Product’ -computer $computer)

      foreach ($app in $win32_product){
         $applications = New-Object PSObject -Property @{
         Name = $app.Name
         Version = $app.Version
         }

         Write-Output $applications | Select-Object Name,Version
         # | Export-Csv c:\temp\approved.csv
		  
      }
   }

   End
   {
   }
}
# c:\temp\approved.csv