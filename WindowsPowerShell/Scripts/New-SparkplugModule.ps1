function New-SparkPlugModule
{
    
	<#
    .Synopsis
        Creates a new SparkPlug module
    .Description
        Creates a new module to write a plugin with SparkPlug
    .Example
        New-SparkPlugModule 'MyPlugin'
    #>
	
    [CmdletBinding(DefaultParameterSetName='Nested')]
    param(
    [Parameter(Mandatory=$true,Position=0)]    
    [ValidateScript({
    if ($_ -like "*\*" -or $_ -like "*/*") { throw "Module name cannot contain slashes" }     
    return $true
    })]
    [string]
    $ModuleName,
    
    [Parameter(ParameterSetName='Required',Mandatory=$true)]
    [switch]
    $RequireInsteadOfNest,

    [Parameter(ParameterSetName='NotRequired',Mandatory=$true)]    
    [Switch]
    $DoNotRequireAtAll
    )
    
    process {
        $moduleRoot = "$home\Documents\WindowsPowerShell\Modules"
        if (-not (Test-Path $moduleRoot)) {
            New-Item -Path $moduleRoot -ItemType Directory  | 
                Out-Null
        }
        $modulePath = Join-Path $moduleRoot $moduleName 
        if (-not (Test-Path $modulePath)) {
            New-Item -Path $modulePath -ItemType Directory  | 
                Out-Null
        }
        
        $fullModuleManifestPath = Join-Path $modulePath "${moduleName}.psd1"
        $fullModulePath = Join-Path $modulePath "${moduleName}.psm1"

        if ($psCmdlet.ParameterSetName -eq 'Nested') {
@"
@{
    ModuleVersion='1.0'
    ModuleToProcess='${moduleName}.psm1'
    NestedModules='SparkPlug'
}
"@ | 
            Set-Content $fullModuleManifestPath  
            
''  | Set-Content $fullModulePath

        } elseif ($psCmdlet.ParameterSetName -eq 'Required') {
@"
@{
    ModuleVersion='1.0'
    ModuleToProcess='${moduleName}.psm1'
    RequiredModules='SparkPlug'
}
"@ | 
            Set-Content $fullModuleManifestPath  
            
''  | Set-Content $fullModulePath

        }  elseif ($psCmdlet.ParameterSetName -eq 'NotRequired') {
        
@"
@{
    ModuleVersion='1.0'
    ModuleToProcess='${moduleName}.psm1'
}
"@ | 
            Set-Content $fullModuleManifestPath  
            
'
if ((Get-Command Add-Menu -ErrorAction SilentlyContinue)) {
    # Add your menu code here
}
'  | Set-Content $fullModulePath
        
        }
        
        Get-Item -LiteralPath $fullModuleManifestPath -ErrorAction SilentlyContinue
        Get-Item -LiteralPath $fullModulePath -ErrorAction SilentlyContinue
    }
} 
