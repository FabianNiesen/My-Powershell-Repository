function ConvertTo-ModuleService
{    
    <#
    .Synopsis
        Export a PowerShell module as a series of ASP.NET Handlers
    .Description
        Exports a Powershell module as a series of ASP.NET handlers        
    .Example
        Import-Module Pipeworks -Force -PassThru | ConvertTo-ModuleService -Force -Allowdownload
    #>
    [OutputType([Nullable])]
    param(
    #|Options Get-Module | Select-Object -ExpandProperty Name
    # The name of the module to export    
    [ValidateScript({
        if (-not (Get-Module "$_")) {
            throw "Module $_ must be loaded"            
        }
    return $true
    })]        
    [Parameter(Mandatory=$true,Position=0,ParameterSetName='LoadedModule',ValueFromPipelineByPropertyName=$true)]
    [string]
    $Name,       
        
    # The order in which to display the commands
    [Parameter(Position=2)]
    [string[]]
    $CommandOrder,   
    
    # The Google Analytics ID used for the module
    [string]
    $AnalyticsId,
    
    # The AdSenseID used to monetize the command
    [string]
    $AdSenseID,
    
    # The AdSlot used to monetize the command
    [string]
    $AdSlot,
    
    # The directory where the generated module will be stored.  
    # If no directory is specified, the module will be put in Inetpub\wwwroot\ModuleName
    [string]
    $OutputDirectory,
    
    # If set, will overwrite files found in the output directory
    [Switch]
    $Force,
            
    # If set, will allow the module to be downloaded
    [Parameter(Position=1)]
    [switch]$AllowDownload,    
    
    # If set, will make changes to the web.config file to work for Intranet sites (anonymous authentication will be disabled, and windows authentication will be enabled).
    [Switch]$AsIntranetSite,
    
    # If provided, will run the site under an app pool with the credential
    [Management.Automation.PSCredential]
    $AppPoolCredential,
    
    # The port an intranet site should run on.
    [Uint32]$Port,
    
    # If a download URL is present, a download link will redirect to that URL.
    [uri]$DownloadUrl,
    
    # If set this is set, will display this command by default
    [string]$StartOnCommand,
    
    # If set, the blog page will become the homepage of the module
    [Switch]$AsBlog,
    
    # If set, will add a URL rewriter rule to accept any URL that is not a real file.
    [Switch]$AcceptAnyUrl,
    
    # If this is set, will use this module URL as the module service URL.
    [Uri]$ModuleUrl,    
        
    
    # If set, will render a CSS style
    [Hashtable]$Style,
    
    # If set, will create appSettings in a web.config file.  This can be used to store common settings, like connection data.
    [Hashtable]$ConfigSetting = @{},
    
    # The margin on either side of the module content.  Defaults to 7.5%.
    [ValidateRange(0,100)]
    [Double]
    $MarginPercent = 16,
    
    # The margin on the left side of the module content. Defaults to 7.5%.
    [ValidateRange(0,100)]
    [Double]
    $MarginPercentLeft = 16,
    
    # The margin on the left side of the module content. Defaults to 7.5%.
    [ValidateRange(0,100)]
    [Double]
    $MarginPercentRight = 16,
    
    # The schematics used to produce the module service.  
    # Schematics let you quickly and easily give a look or feel around data or commands, and let you parameterize your deployment with the pipeworks manifest.
    [Alias('Schematic')]
    [string[]]
    $UseSchematic,    
        
    # If set, will run commands in a runspace for each user.  If not set, users will run in a pool
    [Switch]
    $IsolateRunspace,
    
    # The size of the runspace pool that will handle request.  The more runspaces in the pool, the more concurrent users
    [Uint16]
    $PoolSize = 1,

    [Timespan]
    $pulseInterval = "0:0:0.5"
    )
    
    
    begin {                             
        # All command services have to have a lot packed into each runspace, so a bit has to happen to set things up
        
        # - An InitialSessionState has to be created for the new runspace
        # - Potentially harmful or useless low-rights commands are removed from the runspace
        # - "Common" Functions are embedded into each handler
    
                           

        # Blacklist "bad" functions, and directory traversal
        $functionBlackList = 65..90 | 
            ForEach-Object -Begin {
                "ImportSystemModules", "Disable-PSRemoting", "Restart-Computer", "Clear-Host", "cd..", "cd\\", "more"
            } -Process { 
                [string][char]$_ + ":" 
            }
    

        if (-not $script:FunctionsInEveryRunspace) {
            $script:FunctionsInEveryRunspace = 'ConvertFrom-Markdown', 'Confirm-Person', 'Get-Person', 'Get-Web', 'Get-WebConfigurationSetting', 'Get-FunctionFromScript', 'Get-Walkthru', 
                'Get-WebInput', 'Invoke-WebCommand', 'Request-CommandInput', 'New-Region', 'New-RssItem', 'New-WebPage', 'Out-Html', 'Out-RssFeed', 'Write-Ajax', 'Write-Css', 'Write-Host', 'Write-Link', 'Write-ScriptHTML', 
                'Write-WalkthruHTML', 'Write-PowerShellHashtable', 'Compress-Data', 'Expand-Data', 'Import-PSData', 'Export-PSData', 'ConvertTo-ServiceUrl'

        }
 
        $embedSection = 
            foreach ($func in Get-Command -Module Pipeworks -Name $FunctionsInEveryRunspace -CommandType Function) {

@"
        SessionStateFunctionEntry $($func.Name.Replace('-',''))Command = new SessionStateFunctionEntry(
            "$($func.Name)", @"
            $($func.Definition.ToString().Replace('"','""'))
            "
        );
        iss.Commands.Add($($func.Name.Replace('-',''))Command);
"@

                
            }
                       
        # Web handlers are essentially embedded C#, compiled on their first use.   The webCommandSequence class,
        # defined within this quite large herestring, is a bridge used to invoke PowerShell within a web handler.        
        $webCmdSequence = @"
public class WebCommandSequence {
    public static InitialSessionState InitializeRunspace(string[] module) {
        InitialSessionState iss = InitialSessionState.CreateDefault();
        
        if (module != null) {
            iss.ImportPSModule(module);
        }
        $embedSection
        
        string[] commandsToRemove = new String[] { "$($functionBlacklist -join '","')"};
        foreach (string cmdName in commandsToRemove) {
            iss.Commands.Remove(cmdName, null);
        }
        
        
        return iss;
        
    }
    
    public static void InvokeScript(string script, 
        HttpContext context, 
        object arguments,
        bool throwError,
        bool shareRunspace) {
        
        PowerShell powerShellCommand = PowerShell.Create();
        bool justLoaded = false;
        Runspace runspace;
        RunspacePool runspacePool;
        PSInvocationSettings invokeWithHistory = new PSInvocationSettings();
        invokeWithHistory.AddToHistory = true;
        PSInvocationSettings invokeWithoutHistory = new PSInvocationSettings();
        invokeWithHistory.AddToHistory = false;
        
        if (! shareRunspace) {

            if (context.Session["UserRunspace"] == null) {                        
                justLoaded = true;
                InitialSessionState iss = WebCommandSequence.InitializeRunspace(null);
                Runspace rs = RunspaceFactory.CreateRunspace(iss);
                rs.ApartmentState = System.Threading.ApartmentState.STA;            
                rs.ThreadOptions = PSThreadOptions.ReuseThread;
                rs.Open();                
                powerShellCommand.Runspace = rs;
                context.Session.Add("UserRunspace",powerShellCommand.Runspace);
                powerShellCommand.
                    AddCommand("Set-ExecutionPolicy", false).
                    AddParameter("Scope", "Process").
                    AddParameter("ExecutionPolicy", "Bypass").
                    AddParameter("Force", true).
                    Invoke(null, invokeWithoutHistory);
                powerShellCommand.Commands.Clear();
            }

        

            runspace = context.Session["UserRunspace"] as Runspace;
            if (context.Application["Runspaces"] == null) {
                context.Application["Runspaces"] = new Hashtable();
            }
            if (context.Application["RunspaceAccessTimes"] == null) {
                context.Application["RunspaceAccessTimes"] = new Hashtable();
            }
            if (context.Application["RunspaceAccessCount"] == null) {
                context.Application["RunspaceAccessCount"] = new Hashtable();
            }

            Hashtable runspaceTable = context.Application["Runspaces"] as Hashtable;
            Hashtable runspaceAccesses = context.Application["RunspaceAccessTimes"] as Hashtable;
            Hashtable runspaceAccessCounter = context.Application["RunspaceAccessCount"] as Hashtable;

            if (! runspaceAccessCounter.Contains(runspace.InstanceId.ToString())) {
                runspaceAccessCounter[runspace.InstanceId.ToString()] = (int)0;
            }
            runspaceAccessCounter[runspace.InstanceId.ToString()] = ((int)runspaceAccessCounter[runspace.InstanceId.ToString()]) + 1;

            runspaceAccesses[runspace.InstanceId.ToString()] = DateTime.Now;


                    
            if (! runspaceTable.Contains(runspace.InstanceId.ToString())) {
                runspaceTable[runspace.InstanceId.ToString()] = runspace;
            }


            runspace.SessionStateProxy.SetVariable("Request", context.Request);
            runspace.SessionStateProxy.SetVariable("Response", context.Response);
            runspace.SessionStateProxy.SetVariable("Session", context.Session);
            runspace.SessionStateProxy.SetVariable("Server", context.Server);
            runspace.SessionStateProxy.SetVariable("Cache", context.Cache);
            runspace.SessionStateProxy.SetVariable("Context", context);
            runspace.SessionStateProxy.SetVariable("Application", context.Application);
            runspace.SessionStateProxy.SetVariable("JustLoaded", justLoaded);
            runspace.SessionStateProxy.SetVariable("IsSharedRunspace", false);
            powerShellCommand.Runspace = runspace;
            powerShellCommand.AddScript(@"
`$timeout = (Get-Date).AddMinutes(-20)
`$oneTimeTimeout = (Get-Date).AddMinutes(-1)
foreach (`$key in @(`$application['Runspaces'].Keys)) {
    if ('Closed', 'Broken' -contains `$application['Runspaces'][`$key].RunspaceStateInfo.State) {
        `$application['Runspaces'][`$key].Dispose()
        `$application['Runspaces'].Remove(`$key)
        continue
    }
    
    if (`$application['RunspaceAccessTimes'][`$key] -lt `$Timeout) {
        
        `$application['Runspaces'][`$key].CloseAsync()
        continue
    }    
}
").Invoke();

            powerShellCommand.Commands.Clear();
            powerShellCommand.AddScript(script, false);
            
            if (arguments is IDictionary) {
                powerShellCommand.AddParameters((arguments as IDictionary));
            } else if (arguments is IList) {
                powerShellCommand.AddParameters((arguments as IList));
            }
            Collection<PSObject> results = powerShellCommand.Invoke();        

        } else {
            if (context.Application["RunspacePool"] == null) {                        
                justLoaded = true;
                InitialSessionState iss = WebCommandSequence.InitializeRunspace(null);
                RunspacePool rsPool = RunspaceFactory.CreateRunspacePool(iss);
                rsPool.SetMaxRunspaces($PoolSize);
                rsPool.ApartmentState = System.Threading.ApartmentState.STA;            
                rsPool.ThreadOptions = PSThreadOptions.ReuseThread;
                rsPool.Open();                
                powerShellCommand.RunspacePool = rsPool;
                context.Application.Add("RunspacePool",rsPool);
                
                // Initialize the pool
                Collection<IAsyncResult> resultCollection = new Collection<IAsyncResult>();
                for (int i =0; i < $poolSize; i++) {
                    PowerShell execPolicySet = PowerShell.Create().
                        AddScript(@"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force 
`$pulseTimer = New-Object Timers.Timer -Property @{
    Interval = ([Timespan]'$pulseInterval').TotalMilliseconds
}

`$global:firstPulse = Get-Date

Register-ObjectEvent -InputObject `$pulseTimer -EventName Elapsed -SourceIdentifier PipeworksPulse -Action {
    `$global:LastPulse = Get-Date        
    
}


#INSERTEVERYSECTIONIFNEEDED

`$pulseTimer.Start()


", false);
                    execPolicySet.RunspacePool = rsPool;
                    resultCollection.Add(execPolicySet.BeginInvoke());
                }
                
                foreach (IAsyncResult lastResult in resultCollection) {
                    if (lastResult != null) {
                        lastResult.AsyncWaitHandle.WaitOne();
                    }
                }
                
                
                
                
                
                
                powerShellCommand.Commands.Clear();
            }
            

            powerShellCommand.RunspacePool = context.Application["RunspacePool"] as RunspacePool;
            
            
            string newScript = @"param(`$Request, `$Response, `$Server, `$session, `$Cache, `$Context, `$Application, `$JustLoaded, `$IsSharedRunspace, [Parameter(ValueFromRemainingArguments=`$true)]`$args)
            
            
            " + script;            
            powerShellCommand.AddScript(newScript, false);

            if (arguments is IDictionary) {
                powerShellCommand.AddParameters((arguments as IDictionary));
            } else if (arguments is IList) {
                powerShellCommand.AddParameters((arguments as IList));
            }            
            
            powerShellCommand.AddParameter("Request", context.Request);
            powerShellCommand.AddParameter("Response", context.Response);
            powerShellCommand.AddParameter("Session", context.Session);
            powerShellCommand.AddParameter("Server", context.Server);
            powerShellCommand.AddParameter("Cache", context.Cache);
            powerShellCommand.AddParameter("Context", context);
            powerShellCommand.AddParameter("Application", context.Application);
            powerShellCommand.AddParameter("JustLoaded", justLoaded);
            powerShellCommand.AddParameter("IsSharedRunspace", true);
            
            Collection<PSObject> results;
            try {
                results = powerShellCommand.Invoke();        
            } catch (Exception ex) {               
                if (
                    (String.Compare(ex.GetType().FullName, "System.Management.Automation.ParameterBindingValidationException") == 0) || 
                    (String.Compare(ex.GetType().FullName, "System.Management.Automation.RuntimeException") == 0)
                   ) {
                    // Parameter validation exception: clean it up a little.
                    ErrorRecord errRec = ex.GetType().GetProperty("ErrorRecord").GetValue(ex, null) as ErrorRecord;
                    if (errRec != null) {
                        try {
                            context.Response.StatusCode = (int)System.Net.HttpStatusCode.BadRequest;
                        } catch {
                        
                        }
                        context.Response.Write("<span class='ui-state-error' color='red'>" + errRec.InvocationInfo.PositionMessage + "</span><br/>");
                    }                    
                } else {
                    throw ex;
                }
            }
            
                        
            
            
        }
        
        
      
        foreach (ErrorRecord err in powerShellCommand.Streams.Error) {
            
            
            if (throwError) {
                if (err.Exception != null) {
                    if (err.Exception.GetType().GetProperty("ErrorRecord") != null) {
                        ErrorRecord errRec = err.Exception.GetType().GetProperty("ErrorRecord").GetValue(err.Exception, null) as ErrorRecord;
                        if (errRec != null) {
                            //context.Response.StatusCode = (int)System.Net.HttpStatusCode.PreconditionFailed;
                            //context.Response.StatusDescription = errRec.InvocationInfo.PositionMessage;
                            context.Response.Write("<span class='ui-state-error' color='red'>" + err.Exception.ToString() + errRec.InvocationInfo.PositionMessage + "</span><br/>");
                        }                        
                        //context.Response.Flush();           
                    } else {
                        context.AddError(err.Exception);            
                    }   
                }
            } else {
                context.Response.Write("<span class='ui-state-error' color='red'>" + err.Exception.ToString() + err.InvocationInfo.PositionMessage + "</span><br/>");                
            }            
        }
        
        if (powerShellCommand.InvocationStateInfo.Reason != null) {
            if (throwError) {                
                context.AddError(powerShellCommand.InvocationStateInfo.Reason);
            } else {                
                context.Response.Write("<span class='ui-state-error' color='red'>" + powerShellCommand.InvocationStateInfo.Reason + "</span>");
            }
        }

        powerShellCommand.Dispose();
    
    }

}
"@      

        # Writing the handler for a command actually involves writing several handlers, 
        # so we'll make this it's own little inline tool.  
        $writeSimpleHandler = {param($cSharp, $webCommandSequence = $webCmdSequence, [Switch]$ShareRunspace, [Uint16]$PoolSize) 






if ($pipeworksManifest.Every -and $pipeworksManifest.Every -is [Hashtable]) {
    $everySection = ""


    $n = 1
    foreach ($kv in $pipeworksManifest.Every.GetEnumerator()) {
        $interval = $kv.Key
        $everyAction = $kv.Value
        $everySection += "
`$everyTimer${n} = New-Object Timers.Timer -Property @{
    Interval = ([Timespan]'$interval').TotalMilliseconds
}

`$global:firstPulse = Get-Date

Register-ObjectEvent -InputObject `$everyTimer${n} -EventName Elapsed -SourceIdentifier EveryAction${n} -Action {
    $everyAction
    
}

`$everyTimer${n}.Start()
"    
        $n++
    }

    $webCommandSequence = $webCommandSequence.Replace('#INSERTEVERYSECTIONIFNEEDED', $everySection.Replace('"', '""'))
}






@"
<%@ WebHandler Language="C#" Class="Handler" %>
<%@ Assembly Name="System.Management.Automation, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" %>
using System;
using System.Web;
using System.Web.SessionState;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

$webCommandSequence

public class Handler : IHttpHandler, IRequiresSessionState  {        
    public void ProcessRequest (HttpContext context) {
        $cSharp
    }
    
    public bool IsReusable {
    	get {
    	    return true;
    	}
    }
}    

"@    
}


        $resolveFinalUrl = {
# The tricky part is resolving the real URL of the service.  
# Split out the protocol
$protocol = $request['Server_Protocol'].Split("/", [StringSplitOptions]::RemoveEmptyEntries)[0]  
# And what it thinks it called the server
$serverName= $request['Server_Name']                     
$port = $request.Url.Port

# And the relative path beneath that URL
$shortPath = [IO.Path]::GetDirectoryName($request['PATH_INFO'])            
# Put them all together

if (($protocol -eq 'http' -and $port -eq 80) -or 
    ($protocol -eq 'https' -and $port -eq 443)) {
$remoteCommandUrl = 
    $Protocol + '://' + $ServerName.Replace('\', '/').TrimEnd('/') + '/' + $shortPath.Replace('\','/').TrimStart('/')
} else {
$remoteCommandUrl = 
    $Protocol + '://' + $ServerName.Replace('\', '/').TrimEnd('/') + ':' + $port + '/' + $shortPath.Replace('\','/').TrimStart('/')

}

# Now, if the pages was anything but Default, add the .ashx reference
$finalUrl = 
    if ($request['Url'].EndsWith("Default.ashx", [StringComparison]"InvariantCultureIgnoreCase")) {
        $u = $request['Url'].ToString()
        $remoteCommandUrl.TrimEnd("/") + $u.Substring($u.LastIndexOf("/"))
    } elseif ($request['Url'].EndsWith("Module.ashx", [StringComparison]"InvariantCultureIgnoreCase")) {
        $u = $request['Url'].ToString()
        $remoteCommandUrl.TrimEnd("/") + $u.Substring($u.LastIndexOf("/"))
    } else {
        $remoteCommandUrl.TrimEnd("/") + "/"
    }    
    

$fullUrl = "$($request.Url)"
if ($request -and $request.Params -and $request.Params["HTTP_X_ORIGINAL_URL"]) {
            
    #region Determine the Relative Path, Full URL, and Depth
    $originalUrl = $context.Request.ServerVariables["HTTP_X_ORIGINAL_URL"]
    $urlString = $request.Url.ToString().TrimEnd("/")
    $pathInfoUrl = $urlString.Substring(0, 
        $urlString.LastIndexOf("/"))
                                                            
    $protocol = ($request['Server_Protocol'].Split("/", 
        [StringSplitOptions]"RemoveEmptyEntries"))[0] 
    $serverName= $request['Server_Name']                     
            
    $port=  $request.Url.Port
    $fullOriginalUrl = 
        if (($Protocol -eq 'http' -and $port -eq 80) -or
            ($Protocol -eq 'https' -and $port -eq 443)) {
            $protocol+ "://" + $serverName + $originalUrl 
        } else {
            $protocol+ "://" + $serverName + ':' + $port + $originalUrl 
        }
                                                    
    $rindex = $fullOriginalUrl.IndexOf($pathInfoUrl, [StringComparison]"InvariantCultureIgnoreCase")
    $relativeUrl = $fullOriginalUrl.Substring(($rindex + $pathInfoUrl.Length))
    if ($relativeUrl -like "*/*") {
        $depth = @($relativeUrl -split "/" -ne "").Count - 1                    
        if ($fullOriginalUrl.EndsWith("/")) { 
            $depth++
        }                                        
    } else {
        $depth  = 0
    }
    #endregion Determine the Relative Path, Full URL, and Depth                                                
    $fullUrl = $fullOriginalUrl
}
$serviceUrl = $fullUrl
        }

        #region RefreshLatest
        $refreshLatest = {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            
            
            
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)                                                           

            $latest = 
                Search-AzureTable -TableName $pipeworksManifest.Table.Name -Filter "PartitionKey eq '$PartitionKey'" -Select Timestamp, DatePublished, PartitionKey, RowKey -StorageAccount $storageAccount -StorageKey $storageKey |
                Sort-Object -Descending {
                    if ($_.DatePublished) {
                        [DateTime]$_.DatePublished
                    } else {
                        [DateTime]$_.Timestamp
                    }
                } |
                Select-Object -First 1 |
                Get-AzureTable -TableName $pipeworksManifest.Table.Name            
            
                                                                                                  
        }
        #endregion RefreshLatest
        
    }
    
    process {     
    
        
        if ($psCmdlet.ParameterSetName -eq 'LoadedModule') {
        
        
        $module = Get-Module $name | Select-Object -First 1       
        if (-not $module ) { return } 
        
        # Skip "accidental" modules
        if ($module.Path -like "*.ps1") { return } 
        
        
        
        
        
        
        if (-not $psBoundParameters.outputDirectory) {
            $outputDirectory = "${env:SystemDrive}\inetpub\wwwroot\$($Module.Name)\"            
            $outDirWasSet = $false    
        } else {
            $outDirWasSet = $true
        }

        if ((Test-Path $outputDirectory) -and (-not $force)) {
            Write-Error "$outputDirectory exists, use -Force to overwrite"
            return
        }
        
        Write-Progress "Cleaning Output Directory" "$outputDirectory"
        Remove-Item $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable Issues
        if ($issues) { 
            Write-Verbose "$($issues | Out-String)"
        }
        $null = New-Item -Path $outputDirectory -Force -ItemType Directory        
        Push-Location $outputDirectory
        $null = New-Item -Path "$outputDirectory\bin" -Force -ItemType Directory        
        

#region Embedded Resources
$poweredByPipeworksLogo= @"
iVBORw0KGgoAAAANSUhEUgAAAFsAAAAyCAIAAAC8rzBcAAAACXBIWXMAAC4jAAAuIwF4pT92AAAABGd
BTUEAALGOfPtRkwAAACBjSFJNAAB6JQAAgIMAAPn/AACA6QAAdTAAAOpgAAA6mAAAF2+SX8VGAAAKJE
lEQVR42mKU1AhhoBh8+fI9OcajrzXz4+fPwXGNFy7fZ2dnRch+/RET6jCpM/f377/Jud3b9pzh4mRno
CpgBJP/qWEUQACxUMtN/xn+////Dwixy/4Hy4IQAy0AFU0FCCBGqqSRv3//SUsKqatI//nz78KVe5+/
/GBiYkSWlRAX0FSVBYbK1RuPXr/7xMzExDBYAUAAMQrI+1LDGMY/f/7++vWHkZEBmF+YgB5GTgwwWSA
TKMvMjCpLbqIAmsPOxkr1EAEIIBZXBwOqZOP/pGVqZDW42HCD4YIIWWYW5qfP3ly69pCTg52RkZohAh
BAjF8+f6Z+EUdSgJAFmJmZ33/8XNE4Z/3WY9xcnFQMFIAAYmFkYqRCscYI8iNKSmEkJfiIUPgPNQT//
v8nLMQ/uTOHjZVl/bZjbKxUyz4AAcQYmdxIhaL+P8O3/4z//pOWu0hSwM74n40RkbB+/voVF+EW4G337
PlL16Dy128/sTAzUyVEAAKIBdg6oDyjACOwuTZFQUZMgI/LPrSOSI0OltqNReFAxvzV+w21FPMb5qEpm
NiQdP7afSBjwar9LEz/eZn+/4Olyq/ffthbA0vA/ywsLMBkQsVKHSCAWLhJbCzJyog/fvISQsIFgQ5Vl
Bf3y+wrTPAszAy4cP2hgrTIgnWHHMy1Dpy8piAt+uDpayAbKPjg6RugCIQd4GKSUDkLKAVUEOhpkRjte
uDkdSA3IcgOokxBXvzBy3cgCzjZuZn+c8FCBOz//6wsoETx7y+wjUPNRg5AALHIyIhbWegeO3EZyIEzI
ADChZAebhaz520MD3EBhkXPhKXubhafPn2FK4aEzsZpRQJ83AdPXQd56cnrBZ0ZArxcEMaCdQeB3gaqA
YYCkGzIDQZ6uKB1MVDqw6evExbuUJARBeoFcoHicGWkleVUAgABxAL06o5dJ4AkkANkAP3v4Wb56dMXo
G+Bng8PEQeKw0gXcNBwQ3RCgomfj4ePj7uuaRZQxD+rD+i8DdOKArL6GMCMDXvOAD0JjHY0HwJDoWHyW
lDGiWmGqAQG3IQF2x3MNA005ekeCCgAIIBAbUdIcED8DIxtYHB8/PQVEu1A8iOI+wWiABIEcDYwyIDBs
WPX8f9I1U7/wh0HltQCPQnMO/PXHQKWLPWT1gKTQD8sIdx/8hqiMj7IDqgSiIAq4UUmsjIg+f7TV2Aw4
QuS/2hNRUoRQAAxVrUtmD57HXnBKScrXlESl5XfDWR//sf05z9NYo+RkZGNjYWLiYGDEVZgAKu27z9aa
5OyUwJevHjjEVrx9MV7SLFCOQAIIJbz565ZGGuQrX/Ros3mxhqMFNZVuEtGYP/o2/eft+48/ffvH/YAp
3YkAAQQy7I5VdTseGK2wklt0P9H0QFset249SAkofn7j79M4JYpSAkjbbq9YAAQQCx8PNz06lQS6wFgN
vn1Gwj+AFmsrMAGBzOsxoUaAGT/p5kzAQKIpax+Fi3GJhjJjTxg6wLY4kqJcVdUkPr27ec/ZlB2+U/H6
gYggFhmLdxGlRABOhzY5QdGLzBKGTE6XhBZYJyzMDMxoQ6OYITdf2DqOHP+xvSePEV56b///tF5fAQgg
Fh4eTgpDxFgNPLycgoL8gIZr16//wkaKGFECo7/PDwcIkJ8wMblm7efvn7/yUSor3r6/O3Uwv45E4uBg
YI1RfynWWoBCCDqjGUB60IPJ+M9G7o2LGlQlJf49fsPquxPJxu9nWvbt65sNTFQ/fnjF0EDubk4zp6/s
/fQBWAp8h9paARXEqVisAAEEAu1iiig03m4Of/++cvMzIhZhACzElD292+gLDMxNgJ9CCxT4WxGbBUaj
dIIQABRbbzz/7//f//8+/sX+9gyML8Apf4i9coYiSibGHGrYoSb8J/KVTBAAFEpRGhQGf6n9rATkQAgg
FgYqeV0RuSIo9KI4n/sAf6fVrEAAgABxESDmKVCekILW0Y6Jk+AAKJSyYrWbGekNJn/Z8CX4mhasgIEE
G1mkv7T2xAqBgtAADFROSAIeeM/cUOAEB8yMYKcB5rxwmYPuO3LyMLETN2sAxBAVAoRfA0GlC7cP3A1T
EzYApu1wIbfp8/fgOg/A5Zhoe/ff376/PXDxy/AQKZiGgEIIBZqZhNGAqkD2E5LiHQ7ceb6t2+/2NhY8
Hd/2dnZJ85YP33eZmAI/vr1By2lcHFyTJm9YdbCrcAg/vr1BwuVhouAACCAqLY2AGVCEkeo/fz928PZt
LcpLb9q+vsPn5kJzbB8+PTlP3icCOtczIeP4FEkcLZipN6kHkAAsVAtOIgpFMHzLIG+tpyc7MdOXWNlZ
aZO8qTqABJAAFEvjfzHNygCjENgTDL/BRWsP3/+9nK18PGwZqDhuA/5ACCAWKhsHtaRUEbQEpIfP34Be
3qQ0a+fP38R2YQlacr8PzWqYYAAYqFmAsHhdk4O9kPHLwfE1P36j74OgsiWPiPYfKypEK4SmAOZGakQI
gABxEKHdMjExOjmaBoWYP+XgbG+f5WBlsKEuVvJGHecWJ+Y3zgflywb038++MQwBQAggKhajuCugAX4e
XbuP9s6b8f6aUUTFu5wtNOHiENmhQNcTUATeqiTxEBZyOQxUERBBjRDqiAnpqgkBWTD54+RLWdn+s9Oj
RABCCDq1TWMGL0bVBAeYO/iZLpg3cGCeA8g98L1h0BvNzAwALkHTl3fMK0IKAifJJ5QHbdhzxkIF6TST
BMYjgJ83BumFwHDLsDFBC1EqAgAAoiJEbUrTwYiskuycsNBx5hmYJxDuA2T1wL9bKApDwwXoIeBPkSeJ
Ab6NqF8BlCNAC8XKCmdug4UEeADz6uvO/Th8zdgMoGkI6oDgACiXt+XxEELYKIApn8Dv0r4tC7QqwUJn
g3la4EJoaB18YEltR8+fYVMCUMAMDiAAZcQZEfMbDnZACCAGKm1wjclzrOnOf3Dh88+EdVnL95lZ2dDa
8oCc/iXP9CW+MZ5Ff5JHVT2CZVKVoAAYqGSaxi/fPnGCF4w5+liqq0hD+9oMCK13X79h1SjDJ+/fksMt
yOjI4mnggL6hIWRCmtrAAKIOmkE2L9gZmasLY1KjfMBdjZwtlwJdpqxtjSIbqVRpQQACCDqjLMCWxzA9
mhd2yIgNzbc/c/vP///oyYPBtxLVf8TCiCsIcKIQ4Ri/wAEEHXSCAT8+fOXlYVZV0uRiZkJPmbxH0e9/
J+4kRZIJ4DhP+EAoRYACCBqtlmBZcfff/9Pn79JoVthkc34E7RE4A8TExMnBxta5MNlgX1IYE+akZFqY
QQQQFRuxQOzD7yWoRAAO4cGuspKClIfPn4+fvoakIs8CPL37199HXVlRSlgB/LIics/fvymwlJlMAAII
Hr0a8gqnP4Dk0BEkGNqvM+lK7f8o+vBM6Swabz/wN7zb2BHKSPJ/82bdy6BpV++vWdlos4wGkAADeJdH
eCBSEhFhrU4h8ynUn05BUCAAQBur2Ofzar2QgAAAABJRU5ErkJggg==
"@
[IO.File]::WriteAllBytes("$outputDirectory\PoweredByPipeworks.png", [Convert]::FromBase64String($poweredByPipeworksLogo))

#endregion Embedded Resources


        # Urls to Rewrite stores the result. Each handler will need to rewrite several URLs for the functionality to work as expected
        $urlsToRewrite = @{}
        
        # To create a web command, we actually need to create several handlers and pages, depending on the options specified.        
        
                                    
        $moduleNumber = 0
        $realModule  = $module

        


        foreach ($m in $realModule) { 
            if (-not $m) { continue }       
            $moduleRoot = Split-Path $m.Path                     

            
            $ManifestPath = Join-Path $moduleRoot "$($module.Name).psd1"

            if (-not (Test-Path $ManifestPath)) {
"
# Module Manifest autogenerated by PowerShell Pipeworks.
@{
    ModuleVersion = 0.1
    ModuleToProcess = '$($module.Path | Split-Path -Leaf)'
}" |
    Set-Content $manifestPath
            }

            #region Initialize Pipeworks Manifest
            $pipeworksManifestPath = Join-Path $moduleRoot "$($module.Name).Pipeworks.psd1"
            $pipeworksManifest = if (Test-Path $pipeworksManifestPath) {
                try {                     
                    & ([ScriptBlock]::Create(
                        "data -SupportedCommand Add-Member, New-WebPage, New-Region, Write-CSS, Write-Ajax, Out-Html, Write-Link { $(
                            [ScriptBlock]::Create([IO.File]::ReadAllText($pipeworksManifestPath))                    
                        )}"))            
                } catch {
                    Write-Error "Could not read pipeworks manifest" 
                }                                                
            }
            
            if (-not $pipeworksManifest) { 
                $pipeworksManifest = @{
                    Pages = @{}
                    Posts = @{}
                    WebCommands = @{}                
                }
            }

            # Inherit a style from the pipeworks manifest, if present
            if (-not ($Style -and $PipeworksManifest.Style)) {
                $Style = $PipeworksManifest.Style
            }
            
            
            # If there's no CSS style set, create a default one
            if (-not $Style) {
                $Style = @{
                    Body = @{
                        'Font-Family' = "Gisha, 'Franklin Gothic Book', Garamond"
                    }
                }
            }
            
            #region Set Module Margins
            if (-not $psBoundParameters.MarginPercent -or ($psBoundParameters.MarginPercentLeft -and $psBoundParameters.MarginPercentRight)) {
                $marginPercentLeftString = "16%"
                $marginPercentRightString= "16%"
            } else {
                if ($psBoundParameters.MarginPercent) {
                    $marginPercentLeftString = $MarginPercent + "%"
                    $marginPercentRightString = $MarginPercent + "%"
                } else {
                    $marginPercentLeftString = $MarginPercentLeft+ "%"
                    $marginPercentRightString = $MarginPercentRight+ "%"
                }
            } 
            #endregion Set Module Margins
            
            #region Embedded Configuration Settings
            if ($pipeworksManifest.SecureSetting) {            
                foreach ($configSettingName in $pipeworksManifest.SecureSetting) {
                    if (-not $configSettingName) { continue }                
                    $settingValue = Get-SecureSetting -Name $configSettingName -ValueOnly -Type String
                    if ($settingValue) {
                        $configSetting[$configSettingName] = $settingValue
                    }
                }
            }
            
            if ($pipeworksManifest.SecureSettings) {            
                foreach ($configSettingName in $pipeworksManifest.SecureSettings) {
                    if (-not $configSettingName) { continue }                
                    $settingValue = Get-SecureSetting -Name $configSettingName -ValueOnly -Type String
                    if ($settingValue) {
                        $configSetting[$configSettingName] = $settingValue
                    }
                }
            }

            #endregion
            
            #region Reuse AdsenseId and AdSlot from the Pipeworks Manifest, if present 
            if ((-not $adSenseId) -and $pipeworksManifest.AdSenseId) {
                $adSenseId  = $pipeworksManifest.AdSenseId
            }
            
            if ((-not $adSlot) -and $pipeworksManifest.AdSlot) {
                $adSlot = $pipeworksManifest.AdSlot
            }
            #endregion 
            
            
            # If there's no analyticsId provided, and one exists in the pipeworks manifest, use it
            if (-not $analyticsId -and $pipeworksManifest.AnalyticsId) {
                $analyticsId = $pipeworksManifest.AnalyticsId
            }
            
            if (-not $AsIntranetSite -and $pipeworksManifest.AsIntranetSite) {
                $AsIntranetSite = $true
            }
            
            
            $moduleBlogTitle = 
                if ($pipeworksManifest.Blog.Name) {
                    $pipeworksManifest.Blog.Name
                } else {
                    $module.Name
                }
            
            $moduleBlogDescription = 
                if ($pipeworksManifest.Blog.Description) {
                    $pipeworksManifest.Blog.Description
                } else {
                    $module.Description
                }
            
            $moduleBlogLink = 
                if ($pipeworksManifest.Blog.Link) {
                    $pipeworksManifest.Blog.Link
                } else {
                    "Blog.html"
                }

            if (-not $PipeworksManifest.Pages) {
                $PipeworksManifest.Pages = @{}
            }
            
            if (-not $PipeworksManifest.Javascript) {
                $PipeworksManifest.Javascript= @{}
            }
            
            if (-not $PipeworksManifest.CssFile) {
                $PipeworksManifest.CssFile = @{}
            }
            
            if (-not $PipeworksManifest.AssetFile) {
                $PipeworksManifest.AssetFile = @{}
            }
            #endregion Initialize Pipeworks Manifest
                
            # Run the ezformat file, if present (and EZOut is loaded)
            if ((Test-Path "$moduleRoot\$($m.Name).ezformat.ps1") -and (Get-Module EZOut)) {                
                & "$moduleRoot\$($m.Name).ezformat.ps1"
            }
            $realModulePath = $m.Path
            $moduleNumber++
            
            if ($AllowDownload) {
                # If AllowDownload is set, create a .zip file to hold the module
                Write-Progress "Creating download" "Adding $($m) to zip file"
                $moduleZip = Join-Path $outputdirectory "$($m.Name).$($m.Version).Zip"
                if ($moduleNumber -eq 1 -and (Test-Path $moduleZip)) {                    
                    Remove-Item $moduleZip -Force
                }
                
                $tempModulePath = New-Item "$env:Temp\TempModule$(Get-Random)" -ItemType Directory
                $tempModuleDir = New-Item "$tempModulePath\$($m.Name)" -ItemType Directory
                
                
                
                
                # By looping thru all files with Get-ChildItem, hidden files get skipped.                
                $moduleFiles  = 
                    @(Get-ChildItem -Path $moduleRoot -Recurse |                    
                        Where-Object { -not $_.psIsContainer } | 
                        Copy-Item -Destination {                                                
                            $newPath = $_.FullName.Replace($moduleRoot, $tempModuleDir)
                            
                            $newDir = $newPAth  |Split-Path
                            if (-not (Test-Path $newDir)) {
                                $null = New-Item -ItemType Directory -Path "$newDir" -Force
                            }
                            
                            
                            Write-Progress "Copying $($req.name)" "$newPath"
                            $newPath             
                            
                        }  -passThru)
                # $null = Copy-ToZip -File $tempModuleDir -ZipFile $moduleZip -HideProgress    
                
                
                if ($m.RequiredModules) {
                    foreach ($requiredModuleInfo in $m.RequiredModules) {
                        
                        $requiredRoot = ($requiredModuleInfo | Split-Path)
                        $tempRequiredModuledir = New-Item "$tempModulePath\$($requiredModuleInfo.Name)" -ItemType Directory
                        $moduleFiles += Get-ChildItem $requiredRoot -Recurse | 
                            Where-Object { -not $_.psIsContainer } | 
                            Copy-Item -Destination {
                                $newPAth  = $_.FullName.Replace($requiredRoot, $tempRequiredModuleDir)
                                $newDir = $newPAth  |Split-Path 
                                if (-not (Test-Path $newDir)) {
                                    $null = New-Item -ItemType Directory -Path "$newDir" -Force
                                }
                                
                                
                                Write-Progress "Copying $($req.name)" "$newPath"
                                $newPath             
                            } -passthru
                            
                        #$null = Copy-ToZip -File $tempRequiredModuleDir -ZipFile $moduleZip -HideProgress    
                    }
                }
                $moduleList = @($RealModule.RequiredModules | 
                    Select-Object -ExpandProperty Name) + $realModule.Name
                        

                
                # Add an installer
                $installer = @'
echo "Installing modules from %~dp0"
'@

                foreach ($m in $moduleList) {
                    $installer += @"

xcopy "%~dp0$m" "%userprofile%\Documents\WindowsPowerShell\Modules\$m" /y /s /i /d 

"@
                }

                
                                    
                # Add shortcut items, if found in the pipeworks manifest                                                    
                if ($pipeworksManifest.Shortcut) {
                    $shortcutsFile = 
                        "`$moduleName = '$($realModule.Name)'" + {

$shell = New-Object -ComObject WScript.Shell
$startRoot = "$home\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
$moduleSubFolder = Join-Path $startRoot $moduleName
if (-not (Test-Path $moduleSubFolder)) {
    $null = New-Item -ItemType Directory -Path $moduleSubFolder
}

$modulefolder = Join-Path "$home\Documents\WindowsPowerShell\Modules" $moduleName                            

                        }
                    
                    $installer += @'

powershell -ExecutionPolicy Bypass -File "%~dp0AddShortcuts.ps1"

'@                    
                    foreach ($shortcutInfo in $pipeworksManifest.ShortCut.Getenumerator()) {
                        if ($shortcutInfo.Value -notlike "http*") {                        
                            $shortcutsFile += @"

`$sh = `$shell.CreateShortcut("`$moduleSubFolder\$($shortcutInfo.Key).lnk")                           
`$sh.WorkingDirectory = `$moduleFolder
`$sh.TargetPath = "`$psHome\powershell.exe"
`$sh.Arguments = "-executionpolicy bypass -windowstyle minimized -sta -command Import-Module '$($moduleList -join "','")';$($shortcutInfo.Value)"
`$sh.Save()
"@
                        } else {
                            $shortcutsFile += @"

`$sh = `$shell.CreateShortcut("`$moduleSubFolder\$($shortcutInfo.Key).url")               
`$sh.TargetPath = "$($shortcutInfo.Value)"
`$sh.Save()
"@
                        }
                    }
                    
                    
                    
                    $shortcutsFile |
                        Set-Content "$tempModulePath\AddShortcuts.ps1"              
                }
                
                $installer |
                    Set-Content "$tempModulePath\install.cmd"              
                
                
                
                
                Get-ChildItem $tempModulePath -Recurse |
                    Out-Zip -zipFile $moduleZip -commonRoot $tempModulePath |
                    Out-Null
                
                
                if (Test-Path $moduleZip) {
                
                    # If there's a module.zip, it might have the wrong ACLs to be served up.  So make it allow anonymous access
                    $acl = 
                        Get-Acl -Path $moduleZip
                    $everyone =
                        New-Object Security.Principal.SecurityIdentifier ([Security.Principal.WellKnownSidType]"WorldSid", $null)
                    $allowAnonymous = 
                        New-Object Security.AccessControl.FileSystemAccessrule ($everyone , "ReadAndExecute","allow")                 
                    $acl.AddAccessRule($allowAnonymous )
                    Set-Acl -Path $moduleZip -AclObject $acl
                    
                    Remove-Item $tempModulePath -Recurse -Force
                }                
            }
        }                  

        Write-Progress "Creating Module Service" "Copying $($Module.name)"

        $moduleDir = (Split-Path $Module.Path)

        $moduleFiles=  Get-ChildItem -Path $moduleDir -Recurse -Force |
            Where-Object { -not $_.psIsContainer } 
        
        foreach ($moduleFile in $moduleFiles) {
            $moduleFile | 
                Copy-Item -Destination {                
                    $relativePath = $_.FullName.Replace("$moduleDir\", "")
                    $newPath = "$outputDirectory\bin\$($Module.Name)\$relativePath"                
                    $null = try {
                        New-Item -ItemType File -Path "$outputDirectory\bin\$($Module.Name)\$relativePath" -Force
                    } catch {
                        # Swallowing the error from creating a new file avoids the case where a file could not be removed, 
                        # and thus a terminating error stops the pipeline
                        $_
                    }
                    Write-Progress "Copying $($req.name)" "$newPath"
                    $newPath             
                } -Force #-ErrorAction SilentlyContinue 
        }
         
            



            $modulePath =  if ($module.Path -like "*.psm1") {
                $module.Path.Substring(0, $module.Path.Length - ".psm1".Length) + ".psd1"
            } else {
                
                $module.Path
            }
            
            $moduleFile = [IO.Path]::GetFileName($modulePath)
            $importChunk = @"
`$searchDirectory = if (`$request -and `$request.Params -and `$request.Params['PATH_TRANSLATED']) {
    `$([IO.Path]::GetDirectoryName(`$Request['PATH_TRANSLATED']))
} else {
    `$Request | Out-HTML
    return
    ''
}

`$searchOrder = @()
while (`$searchDirectory) {
    if (-not "`$searchDirectory`") {
        break
    }
    Set-Location `$searchDirectory 
    `$searchOrder += "`$searchDirectory\bin\$($Module.Name)"
    if (Test-Path "`$searchDirectory\bin\$($Module.Name)") {
        #ImportRequiredModulesFirst
        Import-Module "`$searchDirectory\bin\$($Module.Name)\$moduleFile"
        break
    }
    `$searchDirectory = `$searchDirectory | Split-Path   
}
"@

        if ($Module.RequiredModules) {
            $importRequired = foreach ($req in $Module.RequiredModules) {
                # Make this callstack aware later                    

                $moduleDir = (Split-Path $req.Path)

                $moduleFiles = 
                Get-ChildItem -Path $moduleDir -Recurse -Force |                   
                    Where-Object { -not $_.psIsContainer }
                    
                foreach ($moduleFile in $moduleFiles) { 
                    $moduleFile | 
                        Copy-Item -Destination {
                        
                        
                            $relativePath = $_.FullName.Replace("$moduleDir\", "")
                            $newPath = "$outputDirectory\bin\$($req.Name)\$relativePath"                        
                            $null = New-Item -ItemType File -Path "$outputDirectory\bin\$($req.Name)\$relativePath" -Force
                            Write-Progress "Copying $($req.name)" "$newPath"
                            $newPath 
                        
                        } -Force #-ErrorAction SilentlyContinue
                }
                $reqDir = Split-Path $req.Path 
                "$(' ' * 8)Import-Module `"`$searchDirectory\bin\$($req.Name)\$($req.Name)`""
            }               
            $importChunk = $importChunk.Replace("#ImportRequiredModulesFirst", 
                $importRequired -join ([Environment]::NewLine))
        }

        # Create the embed command.
        $embedCommand = $importChunk
        $embedCommand = $embedCommand + @"
`$module = Get-Module `"$($module.Name)`" | Select-Object -First 1
if (-not `$module) { `$response.Write(`$searchOrder -join '<BR/>'); `$response.Flush()  } 
`$moduleRoot = [IO.Path]::GetDirectoryName(`$module.Path)


`$moduleCommands = `$module.ExportedCommands.Values
`$pipeworksManifestPath = `$moduleRoot + '\' + "`$(`$module.Name).Pipeworks.psd1"
`$global:pipeworksManifest = if (([IO.File]::Exists(`$pipeworksManifestPath))) {
try {                     
    & ([ScriptBlock]::Create(
        "data -SupportedCommand Add-Member, New-WebPage, New-Region, Write-CSS, Write-Ajax, Out-Html, Write-Link { `$(
            [ScriptBlock]::Create([IO.File]::ReadAllText(`$pipeworksManifestPath))                    
        )}"))            
} catch {
    Write-Error "Could not read pipeworks manifest" 
}                                                
}
if (-not `$global:PipeworksManifest.Style) {
    `$global:PipeworksManifest.Style = @{
        Body = @{
            'Font-Family' = "'Segoe UI', 'Segoe UI Symbol', Helvetica, Arial, sans-serif"
        }
    }
    
}
"@
          
        $moduleRoot = (Split-Path $module.Path)        

        
        #region Check for the presence of directories, and put items within them into the manifest
        
        
        # Pick out all possible cultures
        $cultureNames = [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::AllCultures) | 
            Select-Object -ExpandProperty Name

        # Pages fall back on culture
        Write-Progress "Importing Pages" " " 
        $pagePaths  = @((Join-Path $moduleRoot "Pages"))


        foreach ($cultureName in $cultureNames) {
            if (-not $cultureName) { continue } 
            $pagePaths+= @((Join-Path $cultureName "Pages"))
        }



        


        foreach ($pagePath in $pagePaths) {
            if (Test-Path $pagePath) {
                Get-ChildItem $pagePath -Recurse |
                    Where-Object {                        
                        (-not $_.PSIsContainer) -and
                        '.htm', '.html', '.ashx','.aspx',
                            '.jpg', '.gif', '.jpeg', '.js', '.css', 
                            '.ico',
                            '.png', '.mpeg','.mp4',  
                            '.mp3', '.wav', '.pspage', 
                            '.pspg', '.ps1' -contains $_.Extension
                    } | 
                    ForEach-Object -Process {
                        if ($_.Extension -ne '.ps1') {
                            # These are simple, just make the page
                            if ($_.Extension -ne '.pspage' -and $_.Extension -ne '.html') {
                                $pipeworksManifest.Pages[$_.Fullname.Replace(($module | Split-Path), "").Replace("Pages\","").TrimStart("\")] = 
                                    [IO.File]::ReadAllBytes($_.Fullname)
                            } else {
                                $pipeworksManifest.Pages[$_.Fullname.Replace(($module | Split-Path), "").Replace("Pages\","").TrimStart("\")] = 
                                    [IO.File]::ReadAllText($_.Fullname)
                            }
                            
                        } else {
                            
                            # Embed the ps1 file contents within a <| |>, but escape the <| |> contained within
                            $fileContents = "$([IO.File]::ReadAllText($_.Fullname))"
                            $fileContents = $fileContents.Replace("<|", "&lt;|").Replace("|>", "|&gt;")
                            $pipeworksManifest.Pages[($_.Fullname.Replace(($module | Split-Path), "").Replace("Pages\","")).Replace(".ps1", ".pspage").TrimStart("\")] = "<| $fileContents
|>"
                            
                        }
                        
                    }
                    
            }
        }
        
        # Posts also fall back on culture
        $pagePaths  = (Join-Path $moduleRoot "Posts"),            
            (Join-Path $moduleRoot "Blog")
                        
        foreach ($cultureName in $cultureNames) {
            if (-not $cultureName) { continue } 
            $pagePaths+= @((Join-Path $cultureName "Blog"))
            $pagePaths+= @((Join-Path $cultureName "Posts"))
        }


        foreach ($pagePath in $pagePaths) {
            if (Test-Path $pagePath) {
                Get-ChildItem $pagePath |
                    Where-Object {                        
                        $_.Name -like "*.post.psd1" -or
                        $_.Name -like "*.pspost" -or
                        $_.Name -like "*.html"
                    } | 
                    ForEach-Object -Begin {
                        if (-not $PipeworksManifest.Posts) {
                            $PipeworksManifest.Posts = @{}
                        }
                    } -Process {
                        $pipeworksManifest.Posts[$_.Name.Replace(".post.psd1","").Replace(".pspost","").Replace(".html","")] = ".\$($_.Directory.Name)\$($_.Name)"
                    }
                    
            }
        }



        
        $jsPaths = (Join-Path $moduleRoot "JS"),            
            (Join-Path $moduleRoot "Javascript")
        
        foreach ($cultureName in $cultureNames) {
            if (-not $cultureName) { continue } 
            $jsPaths += @((Join-Path $cultureName "JS"))
            $jsPaths += @((Join-Path $cultureName "JavaScript"))
        }
        foreach ($jsPath in $jsPaths) {
            if (Test-Path $jsPath) {
                Get-ChildItem $jsPath |
                    Where-Object {                        
                        $_.Name -like "*.js"
                    } | 
                    ForEach-Object -Process {                                            
                        if (-not $_.psiscontainer) {                                        
                            $pipeworksManifest.Javascript[$_.Fullname.Replace(($module | Split-Path), "")] = [IO.File]::ReadAllBytes($_.Fullname)
                        }
                    }
                    
            }
        }
        
        $cssPaths = @(Join-Path $moduleRoot "CSS")

        foreach ($cultureName in $cultureNames) {
            if (-not $cultureName) { continue } 
            $cssPaths += @((Join-Path $cultureName "CSS"))            
        }

        foreach ($cssPath in $cssPaths) {
            if (Test-Path $cssPath) {
                Get-ChildItem $cssPath -Recurse |
                    ForEach-Object -Process {                                            
                        if (-not $_.psiscontainer) {                                        
                            $pipeworksManifest.CssFile[$_.Fullname.Replace(($module | Split-Path), "")] = [IO.File]::ReadAllBytes($_.Fullname)
                        }
                    }
                    
            }
        }
        
        
        $assetPaths = (Join-Path $moduleRoot "Asset"),            
            (Join-Path $moduleRoot "Assets"),
            (Join-Path $moduleRoot "Resource"),
            (Join-Path $moduleRoot "Resources")            
        
        foreach ($cultureName in $cultureNames) {
            if (-not $cultureName) { continue } 
            $assetPaths  += @((Join-Path $cultureName "Asset"))                        
            $assetPaths  += @((Join-Path $cultureName "Assets"))           
            $assetPaths  += @((Join-Path $cultureName "Resource"))            
            $assetPaths  += @((Join-Path $cultureName "Resources"))            
        }


        foreach ($assetPath in $assetPaths) {
            if (Test-Path $assetPath ) {
                Get-ChildItem $assetPath  -Recurse |
                    ForEach-Object -Process {     
                        if (-not $_.psiscontainer) {                                        
                            $pipeworksManifest.AssetFile[$_.Fullname.Replace(($module | Split-Path), "")] = [IO.File]::ReadAllBytes($_.Fullname)
                        }
                    }
                    
            }
        }
        #endregion Check for the presence of directories, and put items within them into the manifest
        
        if ($PipeworksManifest.UseTableSorter -and 
            -not ($pipeworksManifest.'JavaScript'.Keys -like "*tablesorter*")) {
                $tableSorterFile = New-item -ItemType File -Path $moduleRoot\JS\tablesorter.min.js -Force
                Get-Web http://tablesorter.com/__jquery.tablesorter.min.js |
                    Set-Content $moduleRoot\JS\tablesorter.min.js

            $pipeworksManifest.Javascript["JS\tablesorter.min.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\tablesorter.min.js")                
        }

        if (($pipeworksManifest.UseRaphael  -or $pipeworksManifest.UseGRaphael )-and 
            -not ($pipeworksManifest.'JavaScript'.Keys -like "*raphael*")) {
            
            $raphael = New-item -ItemType File -Path $moduleRoot\JS\raphael-min.js -Force
            Get-Web -Url http://raphaeljs.com/raphael.js -UseWebRequest -HideProgress |
                Set-Content $raphael.Fullname -Encoding UTF8                

            $pipeworksManifest.Javascript["JS\raphael-min.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\raphael-min.js")                
        }

        if ($pipeworksManifest.UseGRaphael -and 
            -not ($pipeworksManifest.'JavaScript'.Keys -like "*g.raphael*")) {
            
            $raphael = New-item -ItemType File -Path $moduleRoot\JS\g.raphael.js -Force
            Get-Web -url http://g.raphaeljs.com/g.raphael.js -UseWebRequest -HideProgress |
                Set-Content $raphael.Fullname                


            $raphaelBar = New-item -ItemType File -Path $moduleRoot\JS\g.bar.js -Force
            Get-Web -url http://g.raphaeljs.com/g.bar.js -UseWebRequest |
                Set-Content $raphaelBar.Fullname                

            $raphaelLine = New-item -ItemType File -Path $moduleRoot\JS\g.line.js -Force
            Get-Web -url http://g.raphaeljs.com/g.line.js -UseWebRequest |
                Set-Content $raphaelLine.Fullname                

            $raphaelPie = New-item -ItemType File -Path $moduleRoot\JS\g.pie.js -Force
            Get-Web -url http://g.raphaeljs.com/g.pie.js -UseWebRequest |
                Set-Content $raphaelPie.Fullname                

            $pipeworksManifest.Javascript["JS\g.raphael.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\g.raphael.js")                
            $pipeworksManifest.Javascript["JS\g.line.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\g.line.js")                
            $pipeworksManifest.Javascript["JS\g.pie.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\g.pie.js")                
            $pipeworksManifest.Javascript["JS\g.bar.js"] = [IO.File]::ReadAllBytes("$moduleRoot\JS\g.bar.js")                
        }
        
        #region Embedded Javascript, CSS, and Assets
        
        foreach ($directlyEmbeddedFileTable in 'Javascript', 'CssFile', 'AssetFile') {
            foreach ($fileAndData in $pipeworksManifest.$directlyEmbeddedFileTable.GetEnumerator()) {
                if (-not $fileAndData.Key) { continue } 
                $null = New-Item "$outputDirectory\$($fileAndData.Key)" -ItemType File -Force
                [IO.File]::WriteAllBytes("$outputDirectory\$($fileAndData.Key)", $fileAndData.Value)
            }
        }
        
        
        #endregion
        
        
        #region Object Pages
        if ($pipeworksManifest.ObjectPages) {
            foreach ($objectPageInfo in $pipeworksManifest.ObjectPages.GetEnumerator()) {
                $pagename = $objectPageInfo.Key
                $value = $objectPageInfo.Value                
                $webOBjectPage = @"
`$storageAccount  = Get-WebConfigurationSetting -Setting `$pipeworksManifest.Table.StorageAccountSetting 
`$storageKey= Get-WebConfigurationSetting -Setting `$pipeworksManifest.Table.StorageKeySetting 
`$part, `$row  = '$($objectPageInfo.Value.Id)' -split '\:'
`$lMargin = '$marginPercentLeftString'
`$rMargin = '$marginPercentRightString'
`$pageName = '$($value.Title)'
"@ + {

if (-not $session["ObjectPage$($PageName)"]) {
    $session["ObjectPage$($PageName)"] = 
        Show-WebObject -StorageAccount $storageAccount -StorageKey $storageKey -Table $pipeworksManifest.Table.Name -Part $part -Row $row |
        New-Region -Style @{
            'Margin-Left' = $lMargin
            'Margin-Right' = $rMargin
            'Margin-Top' = '2%'
        } |
        New-WebPage  -Title $pageName
        
}

$session["ObjectPage$($PageName)"] | Out-HTML -WriteResponse

                }                
                $pipeworksManifest.Pages["$pagename.pspage"] = "<|
$webObjectPage
|>"                                        
            }
        }
        
        
        #endregion Object Pages
        
        
        #region HTML Based Blog
        
        # The value of the post field can either be a hashtable containing these items, or a relative path to a .post.psd1 containing 
        # these items.
        $hasPosts = $false
        if ($PipeworksManifest.Posts -and 
            $PipeworksManifest.Posts.GetType() -eq [Hashtable] ) {
            if (-not $hasPosts) {                
                [IO.File]::WriteAllBytes("$outputDirectory\rss.png", 
                    [Convert]::FromBase64String("                    
                    iVBORw0KGgoAAAANSUhEUgAAAA4AAAAOCAYAAAAfSC3RAAAABGdBTUEAAK/
                    INwWK6QAAABl0RVh0U29mdHdhcmUAQWRvYmUgSW1hZ2VSZWFkeXHJZTwAAA
                    JDSURBVHjajJJNSBRhGMd/887MzrQxRSLbFuYhoUhEKsMo8paHUKFLdBDrU
                    Idunvq4RdClOq8Hb0FBSAVCUhFR1CGD/MrIJYqs1kLUXd382N356plZFOrU
                    O/MMz/vO83+e93n+f+1zF+kQBoOQNLBJg0CTj7z/rvWjGbEOIwKp9O7Wkht
                    Qc/wMWrlIkP8Kc1lMS8eyFHpkpo5SgWCCVO7Z5JARhuz1Qg29fh87u6/9VW
                    L1/SPc4Qy6n8c0FehiXin6dcCQaylDMhqGz8ydS2hKkmxNkWxowWnuBLHK6
                    G2C8X6UJkBlxUmNqLYyNbzF74QLDrgFgh9LLE0NsPKxjW1Hz2EdPIubsOFd
                    H2HgbwAlC4S19dT13o+3pS+vcSfvUcq9YnbwA6muW9hNpym/FWBxfh0CZkK
                    GkPBZeJFhcWQAu6EN52QGZ/8prEKW+cdXq0039UiLXhUYzdjebOJQQI30UX
                    p6mZn+Dtam32Afu0iyrgUvN0r+ZQbr8HncSpUVJfwRhBWC0hyGV8CxXBL5S
                    WYf9sYBidYLIG2V87/ifVjTWAX6AlxeK2C0X8e58hOr/Qa2XJ3iLMWxB1h7
                    2tHs7bgryzHAN2o2gJorTrLxRHVazd0o4TXiyV2Yjs90uzauGvvppmqcLjw
                    mbZ3V7BO2HOrBnbgrQRqWUgTZ5+Snx4WeKfzCCrmb3axODKNH+vvUyWjqyK
                    4DiKQ0eXSpFsgVvLJQWpH+xSpr4otg/HI0TR/t97cxTUS+QxIMRTLi/9ZYJ
                    PI/AgwAoc3W7ZrqR2IAAAAASUVORK5CYII="))
            }
            $hasPosts = $true
            
            $getPostFileNames = {
                param($post)
                
                $replacedPostTitle = $post.Title.Replace("|", " ").Replace("/", "-").Replace("\","-").Replace(":","-").Replace("!", "-").Replace(";", "-").Replace(" ", "_").Replace("@","at").Replace(",", " ")
                New-Object PSObject -Property @{
                    safeFileName = $replacedPostTitle + ".simple.html"
                    postFileName = $replacedPostTitle  + ".post.html"
                    postDirectory = $replacedPostTitle 
                    postRssFileName = $replacedPostTitle  + ".xml"
                    datePublishedFileName = try { ([DateTime]($post.DatePublished)).ToString("u").Replace(" ", "_").Replace(":", "-") + ".simple.html"} catch {}
                }
            }
                                                
            
            # Get the command now so we can remove anything else from the pagecontent hashtable later
            $rssItem = Get-Command New-RssItem | Select-Object -First 1 
            $moduleRssName = $moduleBlogTitle.Replace("|", " ").Replace("/", "-").Replace("\","-").Replace(":","-").Replace("!", "-").Replace(";", "-").Replace(" ", "_").Replace("@","at").Replace(",", "_")
            $allPosts = 
                foreach ($postAndContent in $PipeworksManifest.Posts.GetEnumerator()) {
                    
                    $pageName = $postAndContent.Key 
                    $pageContent = $postAndContent.Value
                        
                    $safePageName = $pageName.Replace("|", " ").Replace("/", "-").Replace("\","-").Replace(":","-").Replace("!", "-").Replace(";", "-").Replace(" ", "_").Replace("@","at").Replace(",", "_")
                    if ($pageContent -like ".\*") {
                        # Relative Path, try loading a post file                            
                        $pagePath = Join-Path $moduleRoot $pageContent.Substring(2)
                        if ($pagePath -notlike "*.htm*" -and (Test-Path $pagePath)) {
                            try {
                                $potentialPagecontent = [IO.File]::ReadAllText($pagePath)
                                $potentialPagecontentAsScriptBlock = [ScriptBlock]::Create($potentialPageContent)
                                $potentialPagecontentAsDataScriptBlock = [ScriptBlock]::Create("data { $potentialPagecontentAsScriptBlock }")
                                $pageContent = & $potentialPagecontentAsDataScriptBlock 
                            } catch {
                                $_ | Write-Error
                            }
                        } elseif (Test-Path $pagePath) {
                            # Page is HTML.
                            $pageContent = [IO.File]::ReadAllText($pagePath)
                            
                            # Try quickly to get the microdata from the HTML.
                            $foundMicroData = 
                                Get-Web -Html $pageContent -ItemType http://schema.org/BlogPosting -ErrorAction SilentlyContinue | 
                                Select-Object -First 1 
                            
                            if ($foundMicrodata) {
                                $pageContent = @{
                                    Title = $foundMicrodata.Name
                                    Description = $foundMicrodata.ArticleText
                                    DatePublished = $foundMicrodata.DatePublished
                                    Category = $foundMicrodata.Keyword
                                    Author = $foundMicrodata.author
                                    Link = $foundMicrodata.url
                                }
                            }
                            
                        }
                    } 
                            
                    $feedContent =                         
                        if ($pageContent -is [Hashtable]) {   
                            if (-not $pageContent.Description -and -not $pageContent.html) {                        
                                continue
                            }
                            
                            if ($pageContent.Html) {
                                $pageContent.Description = $pageContent.html
                            }                                                                 
                            
                            if (-not $pageContent.Title) {
                                $pageContent.Title = $pageName
                            }                                                                                    
                            
                            foreach ($key in @($pageContent.Keys)) {
                                if ($rssItem.Parameters.Keys -notcontains $key) {
                                    $pageContent.Remove($key)
                                }
                            }
                            
                            $fileNames = & $getPostFileNames $pageContent
                            $pageContent.Link = $filenames.postFileName
                            New-RssItem @pageContent 
                        } else {
                            Write-Debug "$safePageName could not be processed"
                            continue
                        }                                               
                                    
                    $safePageName = $fileNames.postFileName
                    $xmlDescription = $pageContent.Description 
                    
                    if (-not $pageContent.Description) { continue }
                    
                    $feedContent | 
                        Out-RssFeed -Title $pageName -Description $xmlDescription -Link "${safePageName}.Post.xml"| 
                        Set-Content "$outputDirectory\${safePageName}.Post.xml"                                        

                    $pageWidgetContent = $ExecutionContext.SessionState.InvokeCommand.ExpandString($blogPostTemplate)
                    $feedHtml = New-RssItem @pageContent -AsHtml
                    # Create an article page
                    New-WebPage -UseJQueryUI -Title $pageContent.Title -PageBody (
                        New-Region -Container 'Headerbar' -Border '0px' -Style @{
                            "margin-top"="1%"
                            'margin-left' = $MarginPercentLeftString
                            'margin-right' = $MarginPercentRightString
                        } -Content "        
    <h1 class='blogTitle'><a href='$moduleBlogLink'>$moduleBlogTitle</a></h1>
    <h4 class='blogDescription'>$moduleBlogDescription</h4>"), (
                        New-Region -Style @{
                            'margin-left' = $MarginPercentLeftString
                            'margin-right' = $MarginPercentRightString
                            'margin-top' = '10px'   
                            'border' = '0px' 
                        } -AsWidget -ItemType http://schema.org/BlogPosting -Content $feedHtml  
                        ) | 
    Set-Content "$outputDirectory\${safePageName}" -PassThru |
    Set-Content "$outputDirectory\$($safePageName.Replace('.post.html', '.html'))"
                                        
                    # Emit the page content, so the whole feed can be generated
                    $feedContent
                }
            
            
            if ($allPosts) { 
                $moduleRss = $allPosts  |                         
                    Out-RssFeed -Title $moduleBlogTitle -Description $module.Description -Link "\$($module.Name).xml" |
                    Set-Content "$outputDirectory\$moduleRssName.xml" -PassThru |
                    Set-Content "$outputDirectory\Rss.xml" -PassThru
            } else {
                $moduleRss = @()
            }
                
            $categories = $moduleRss | 
                Select-Xml //item/category | 
                Group-Object { $_.Node.'#text'}                
                
            $postsByYear = $moduleRss | 
                Select-Xml //item/pubDate | 
                Group-Object { ([DateTime]$_.Node.'#text').Year }                
                
            $postsByYearAndMonth = $moduleRss | 
                Select-Xml //item/pubDate |                 
                Group-Object { 
                    ([DateTime]$_.Node.'#text').ToString("y")
                }
                
            $allGroups = @($categories) + $postsByYear + $postsByYearAndMonth
             
            foreach ($groupPage in $allGroups) {
                if (-not $groupPage) { continue } 
                $catLink = $groupPage.Name.Replace("|", " ").Replace("/", "-").Replace("\","-").Replace(":","-").Replace("!", "-").Replace(";", "-").Replace(" ", "_").Replace("@","at").Replace(",", "_") + ".posts.html"
                $groupPage.Group |                     
                    ForEach-Object { 
                        $_.Node.SelectSingleNode("..")
                    } | 
                    Sort-Object -Descending { ([datetime]$_.pubdate).'#text' } | 
                    Select-Object title, creator, pubdate, link, category, @{
                        Name='Description';
                        Expression={
                            $_.Description.InnerXml.Substring("<![CDATA[".Length).TrimEnd("]]>")
                        }
                    } | 
                    New-RssItem -AsHTML |
                    New-Region -ItemType http://schema.org/BlogPosting -AsWidget -Style @{
                        'margin-left' = $MarginPercentLeftString
                        'margin-right' = $MarginPercentRightString
                        'margin-top' = '10px'   
                        'border' = '0px' 
                    }|
                    ForEach-Object -Begin {
                        New-Region -Container 'Headerbar' -Border '0px' -Style @{
                            "margin-top"="1%"
                            'margin-left' = $MarginPercentLeftString
                            'margin-right' = $MarginPercentRightString
                        } -Content "        
    <h1 class='blogTitle'><a href='$moduleBlogLink'>$moduleBlogTitle</a></h1>
    <p class='blogDescription'>$moduleBlogDescription</p>
    <h2 class='blogCategoryHeader' style='text-align:right'>$($groupPage.Name)</h2>
    "                        
                    } -Process {
                        $_
                    } | 
                    New-WebPage -Title "$moduleBlogTitle - $($groupPage.Name)" -Rss @{"Start-Scripting"= "$moduleRssName.xml"} |
                    Set-Content "$outputDirectory/$catLink"
                
                                    
            }
        }        
        
        #endregion HTML Based Blog 
        $unpackItem = {
            $item = $_
            $item.psobject.properties |                         
                Where-Object { 
                    ('Timestamp', 'RowKey', 'TableName', 'PartitionKey' -notcontains $_.Name) -and
                    (-not "$($_.Value)".Contains(' ')) 
                }|                        
                ForEach-Object {
                    try {
                        $expanded = Expand-Data -CompressedData $_.Value
                        $item | Add-Member NoteProperty $_.Name $expanded -Force
                    } catch{
                        Write-Verbose $_
                    
                    }
                }
                
            $item.psobject.properties |                         
                Where-Object { 
                    ('Timestamp', 'RowKey', 'TableName', 'PartitionKey' -notcontains $_.Name) -and
                    (-not "$($_.Value)".Contains('<')) 
                }|                                   
                ForEach-Object {
                    try {
                        $fromMarkdown = ConvertFrom-Markdown -Markdown $_.Value
                        $item | Add-Member NoteProperty $_.Name $fromMarkdown -Force
                    } catch{
                        Write-Verbose $_
                    
                    }
                }

            $item                         
        }
        
        $embedUnpackItem = "`$unpackItem = {$unpackItem
        }"
        
        # This seems counter-intuitive, and so bears a little explanation.  
        # This makes schematics have a natural priority order according to how they were specified
        # That is, if you have multiple schematics, you want the first item to be the most important 
        # (and it's default page to be the default page).  If it was processed first, this wouldn't happen.
        # If this was sorted, also no.  So, it's flipped.
        
        if ($psboundParameters.useSchematic) {
            $useSchematic = $useSchematic[-1..(0 -$useSchematic.Length)]
        }
        
            
        foreach ($schematic in $useSchematic) {
            $moduleList = (@($realModule) + @($module.RequiredModules) + @(Get-Module Pipeworks))
            $moduleList  =  $moduleList  | Select-Object -Unique
            foreach ($moduleInfo in $moduleList  ) {
                $thisModuleDir = $moduleInfo | Split-Path
                $schematics = "$thisModuleDir\Schematics\$Schematic\" | Get-ChildItem -Filter "Use-*Schematic.ps1" -ErrorAction SilentlyContinue
                foreach ($s in $schematics) {
                    if (-not $s) { continue } 
                    if (-not $pipeworksManifest.$Schematic) {
                        Write-Error "Missing $schematic schematic parameters for $($module.Name)"
                        continue
                    }
                    $pagesToMerge = & {                            
                        . $s.Fullname
                        $schematicCmd = 
                            Get-Command -Verb Use -Noun *Schematic | 
                            Where-Object {$_.Name -ne 'Use-Schematic'} | 
                            Select-Object -First 1 
                        
                        $schematicParameters = @{
                            Parameter = $pipeworksManifest.$schematic
                            Manifest = $PipeworksManifest 
                            DeploymentDirectory = $outputDirectory 
                            inputDirectory = $moduleRoot
                        }
                        if ($schematicCmd.Name) {
                            & $schematicCmd @schematicParameters
                            Remove-Item "function:\$($schematicCmd.Name)"
                        }
                    }
                    
                    if ($pagesToMerge) {
                        foreach ($kv in $pagesToMerge.GetEnumerator()) {
                            $pipeworksManifest.pages[$kv.Key] = $kv.Value
                        }                   
                    }
                }                    
            }                
        }
        
        if ($pipeworksManifest.Table) {
            $RequiresPipeworks = $module.RequiredModules | Where-Object { $_.Name -eq 'Pipeworks'}             
            if (-not $requiresPipeworks -and ($module.Name -ne 'Pipeworks')) { 
                Write-Error "Modules that use the Pipeworks Manifest table features must require Pipeworks in the module manifest.  Please add RequiredModules='Pipeworks' to the module manifest.'"
                return
            }
            
            if ($PipeworksManifest.Table.StorageAccountSetting) {
                $storageAccount = $configSetting[$PipeworksManifest.Table.StorageAccountSetting]                
            }
            
            if ($PipeworksManifest.Table.StorageKeySetting) {
                $storageKey = $configSetting[$PipeworksManifest.Table.StorageKeySetting]                
            }                        
            
            if ($pipeworksManifest.Table.IndexBy) {
                $nolongerindexingForABitSplittingthisOffintoACommandLater = {
                if (-not $pipeworksManifest.Table.SqlAzureConnectionSetting) {
                    Write-Error "Modules that index tables must also declare a SqlAzureConnectionSetting within the table"
                    return
                }
            
                # Indexes the table entries by any number of fields                                
                Write-Progress "Building Index for $($pipeworksManifest.Table.Name)" "Querying for $($pipeworksManifest.Table.IndexBy -join ',')" 
                
                $indexProperties = 
                    Search-AzureTable -TableName $pipeworksManifest.Table.Name -StorageAccount $storageACcount -StorageKey $storageKey -Select ([string[]]($pipeworksManifest.Table.IndexBy + "RowKey", "PartitionKey", "Timestamp")) |
                    ForEach-Object $unpackItem
                
                Write-Progress "Building Index for $($pipeworksManifest.Table.Name)" "Indexing into SQL" 
                                
                $connectionString = $configSetting[$pipeworksManifest.Table.SqlAzureConnectionSetting]
                
                $sqlConnection = New-Object Data.SqlClient.SqlConnection "$connectionString"
                $sqlConnection.Open()
                                                
                #region Check if index exists 
                $tableExists = "Select table_name from information_schema.tables where table_name='$($pipeworksManifest.Table.Name)'"                
                
                $sqlAdapter= New-Object "Data.SqlClient.SqlDataAdapter" ($tableExists, $sqlConnection)
                $sqlAdapter.SelectCommand.CommandTimeout = 0
                $dataSet = New-Object Data.DataSet
                if ($sqlAdapter.Fill($dataSet)) {
                    #endregion Check if index exists 
                    #region Delete the existing index and table
                    $getAllIds = "select Id from $($pipeworksManifest.Table.Name)"
                    $sqlAdapter= New-Object Data.SqlClient.SqlDataAdapter ($getAllIds, $sqlConnection)
                    $sqlAdapter.SelectCommand.CommandTimeout = 0
                    $dataSet = New-Object Data.DataSet 
                    $null = $sqlAdapter.Fill($dataSet)
                    $allIds = @($dataSet.Tables | 
                        Select-Object -ExpandProperty Rows | 
                        Select-Object -ExpandProperty Id)
                    #endregion Delete the existing index and table
                } else {
                    $allIds = @()
                    $indexBySql = ($pipeworksManifest.Table.IndexBy -join ' varchar(max),
') + ' varchar(max)'                
                
                    #region Create the table and an index
                    $createTableAndIndex = @"
CREATE TABLE $($pipeworksManifest.Table.Name) (

Id char(100) NOT NULL Unique CLUSTERED ,
$indexBySql 
)
"@
                    #endregion Create the table and an index
                                                   
                    $sqlAdapter= New-Object Data.SqlClient.SqlDataAdapter ($createTableAndIndex, $sqlConnection)
                    $sqlAdapter.SelectCommand.CommandTimeout = 0
                    $dataSet = New-Object Data.DataSet 
                    $null = $sqlAdapter.Fill($dataSet)
                }
                
                
                
                
                
                $index = @{}
                
                #region Put the items into the index
                    
                $c = 0 
                
                if (-not ($allIds.Count -eq $indexProperties.Count)) {  
                    # drop the table and rebuild it
                    
                                                   
                    
                                              
                    foreach ($item in $indexProperties) 
                    {       
                        $itemId = "$($item.PartitionKey):$($item.RowKey)"
                        $cacheItem = @{Id=$itemId}
                        $idExists = $null
                        $idExists = 
                            foreach ($_ in $allIds) { if ($_ -and $_.StartsWith($itemId)) { $_; break; } }                    
                        $c++
                        
                        if ($idExists) {
                            continue
                        }

                        $perc = $c * 100 / $indexProperties.count                    

                        Write-Progress "Building Index for $($pipeworksManifest.Table.Name)" "$itemId" -PercentComplete $perc

                        $otherValues = foreach ($propertyName in $pipeworksManifest.Table.IndexBy) {
                            "$($item.$propertyName)"  -replace "'", "''"
                        }
                        
                        
                        $sqlInsertStatement = "Insert Into $($pipeworksManifest.Table.Name) (Id, $($pipeworksManifest.Table.IndexBy -join ','))
                        VALUES ('$itemId','$($otherValues -join "','")')
                        "                    
                        $sqlAdapter= New-Object Data.SqlClient.SqlDataAdapter ($sqlInsertStatement, $sqlConnection)
                        $sqlAdapter.SelectCommand.CommandTimeout = 0
                        $dataSet = New-Object Data.DataSet 
                        try {
                            $null = $sqlAdapter.Fill($dataSet)
                        } catch {
                            Write-Debug $_
                        }
                        
                    }
                }
                #endregion Put the items into the index
                
                $sqlConnection.Close()
                <#
                $tables= foreach ($c in $cache) {
                    Write-PowerShellHashtable -inputObject $c
                }
                ('(' + ($tables -join '),(') + ')' )| 
                    Set-Content "$outputDirectory/$($pipeworksManifest.Table.Name).Cache.psd1"
                #>
                
                Write-Progress "Building Index for $($pipeworksManifest.Table.Name)" "Indexing Complete" -Completed
                }
            }
    
            
            
            
            
            
            #endregion Handle Schematics
    
            #region Simple Search Table Page
                                                                                 
    }
        
        if ($hasPosts -and $ModuleRss) {
            # Generate the main page, which is an expanded first item with popouts linking to other items            
            $moduleRss | 
                Select-Xml //item/pubDate | 
                Sort-Object -Descending { ([DateTime]$_.Node.'#text') } | 
                Select-Object -First 1 | 
                ForEach-Object { 
                        $_.Node.SelectSingleNode("..")
                } | 
                Select-Object title, creator, pubdate, link, category, @{
                    Name='Description';
                    Expression={
                        $_.Description.InnerXml.Substring("<![CDATA[".Length).TrimEnd("]]>")
                    }
                } | 
                New-RssItem -AsHTML |
                New-Region -ItemType http://schema.org/BlogPosting -AsWidget -Style @{
                    'margin-left' = $MarginPercentLeftString
                    'margin-right' = $MarginPercentRightString
                    'margin-top' = '10px'   
                    'border' = '0px' 
                }|
                ForEach-Object -Begin {
                    New-Region -Container 'Headerbar' -Border '0px' -Style @{
                        "margin-top"="1%"
                        'margin-left' = $MarginPercentLeftString
                        'margin-right' = $MarginPercentRightString
                    } -Content "        
<h1 class='blogTitle'><a href='$moduleBlogLink'>$moduleBlogTitle</a></h1>
<p class='blogDescription'>$moduleBlogDescription</p>
"                        
                } -Process {
                    $_
                } | 
                New-WebPage -Title "$moduleBlogTitle" -Rss @{"Start-Scripting"= "$moduleRssName.xml"} |
                Set-Content "$outputDirectory/Blog.html"
        }
        
        
                
        #region Pages
        #If the manifest declares additional web pages, create a page for each item
        if ($PipeworksManifest.Pages -and 
            $PipeworksManifest.Pages.GetType() -eq [Hashtable] ) {
            $codeBehind = @"
using System;
using System.Web.UI;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Collections;
using System.Collections.ObjectModel;
public partial class PowerShellPage : Page {
    public InitialSessionState InitializeRunspace() {
        InitialSessionState iss = InitialSessionState.CreateDefault();
        $embedSection
        string[] commandsToRemove = new String[] { "$($functionBlacklist -join '","')"};
        foreach (string cmdName in commandsToRemove) {
            iss.Commands.Remove(cmdName, null);
        }
        return iss;
    }
    public void RunScript(string script) {
        bool shareRunspace = $((-not $IsolateRunspace).ToString().ToLower());
        UInt16 poolSize = $PoolSize;
        PowerShell powerShellCommand = PowerShell.Create();
        bool justLoaded = false;
        PSInvocationSettings invokeNoHistory = new PSInvocationSettings();
        invokeNoHistory.AddToHistory = false;
        Collection<PSObject> results;
        if (shareRunspace) {
            if (Application["RunspacePool"] == null) {                        
                justLoaded = true;
                
                RunspacePool rsPool = RunspaceFactory.CreateRunspacePool(InitializeRunspace());
                rsPool.SetMaxRunspaces($PoolSize);
                
                rsPool.ApartmentState = System.Threading.ApartmentState.STA;            
                rsPool.ThreadOptions = PSThreadOptions.ReuseThread;
                rsPool.Open();                                
                powerShellCommand.RunspacePool = rsPool;
                Application.Add("RunspacePool",rsPool);
                
                // Initialize the pool
                Collection<IAsyncResult> resultCollection = new Collection<IAsyncResult>();
                for (int i =0; i < $poolSize; i++) {
                    PowerShell execPolicySet = PowerShell.Create().
                        AddScript(@"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force 
`$pulseTimer = New-Object Timers.Timer -Property @{
    #Interval = ([Timespan]'$pulseInterval').TotalMilliseconds
}


Register-ObjectEvent -InputObject `$pulseTimer -EventName Elapsed -SourceIdentifier PipeworksPulse -Action {
    
    
    `$global:LastPulse = Get-Date        
    
}
`$pulseTimer.Start()



", false);
                    execPolicySet.RunspacePool = rsPool;
                    resultCollection.Add(execPolicySet.BeginInvoke());
                }
                
                foreach (IAsyncResult lastResult in resultCollection) {
                    if (lastResult != null) {
                        lastResult.AsyncWaitHandle.WaitOne();
                    }
                }
                
                powerShellCommand.Commands.Clear();
            }
            
            
                        
            
            powerShellCommand.RunspacePool = Application["RunspacePool"] as RunspacePool;
            
            
            
            string newScript = @"param(`$Request, `$Response, `$Server, `$session, `$Cache, `$Context, `$Application, `$JustLoaded, `$IsSharedRunspace, [Parameter(ValueFromRemainingArguments=`$true)]`$args)
            if (`$request -and `$request.Params -and `$request.Params['PATH_TRANSLATED']) {
                Split-Path `$request.Params['PATH_TRANSLATED'] |
                    Set-Location
            }
            
            " + script;            
            powerShellCommand.AddScript(newScript, false);
                       
            
            powerShellCommand.AddParameter("Request", Request);
            powerShellCommand.AddParameter("Response", Response);
            powerShellCommand.AddParameter("Session", Session);
            powerShellCommand.AddParameter("Server", Server);
            powerShellCommand.AddParameter("Cache", Cache);
            powerShellCommand.AddParameter("Context", Context);
            powerShellCommand.AddParameter("Application", Application);
            powerShellCommand.AddParameter("JustLoaded", justLoaded);
            powerShellCommand.AddParameter("IsSharedRunspace", true);
            results = powerShellCommand.Invoke();        
        
        } else {
            Runspace runspace;
            if (Session["UserRunspace"] == null) {
                
                Runspace rs = RunspaceFactory.CreateRunspace(InitializeRunspace());
                rs.ApartmentState = System.Threading.ApartmentState.STA;            
                rs.ThreadOptions = PSThreadOptions.ReuseThread;
                rs.Open();
                powerShellCommand.Runspace = rs;
                powerShellCommand.
                    AddCommand("Set-ExecutionPolicy", false).
                    AddParameter("Scope", "Process").
                    AddParameter("ExecutionPolicy", "Bypass").
                    AddParameter("Force", true).
                    Invoke(null, invokeNoHistory);
                powerShellCommand.Commands.Clear();

                Session.Add("UserRunspace",rs);
                justLoaded = true;
            }

            runspace = Session["UserRunspace"] as Runspace;

            if (Application["Runspaces"] == null) {
                Application["Runspaces"] = new Hashtable();
            }
            if (Application["RunspaceAccessTimes"] == null) {
                Application["RunspaceAccessTimes"] = new Hashtable();
            }
            if (Application["RunspaceAccessCount"] == null) {
                Application["RunspaceAccessCount"] = new Hashtable();
            }

            Hashtable runspaceTable = Application["Runspaces"] as Hashtable;
            Hashtable runspaceAccesses = Application["RunspaceAccessTimes"] as Hashtable;
            Hashtable runspaceAccessCounter = Application["RunspaceAccessCount"] as Hashtable;
            
            
            if (! runspaceTable.Contains(runspace.InstanceId.ToString())) {
                runspaceTable[runspace.InstanceId.ToString()] = runspace;
            }

            if (! runspaceAccessCounter.Contains(runspace.InstanceId.ToString())) {
                runspaceAccessCounter[runspace.InstanceId.ToString()] = 0;
            }
            runspaceAccessCounter[runspace.InstanceId.ToString()] = ((int)runspaceAccessCounter[runspace.InstanceId.ToString()]) + 1;
            runspaceAccesses[runspace.InstanceId.ToString()] = DateTime.Now;


            runspace.SessionStateProxy.SetVariable("Request", Request);
            runspace.SessionStateProxy.SetVariable("Response", Response);
            runspace.SessionStateProxy.SetVariable("Session", Session);
            runspace.SessionStateProxy.SetVariable("Server", Server);
            runspace.SessionStateProxy.SetVariable("Cache", Cache);
            runspace.SessionStateProxy.SetVariable("Context", Context);
            runspace.SessionStateProxy.SetVariable("Application", Application);
            runspace.SessionStateProxy.SetVariable("JustLoaded", justLoaded);
            runspace.SessionStateProxy.SetVariable("IsSharedRunspace", false);
            powerShellCommand.Runspace = runspace;


        
            powerShellCommand.AddScript(@"
`$timeout = (Get-Date).AddMinutes(-20)
`$oneTimeTimeout = (Get-Date).AddMinutes(-1)
foreach (`$key in @(`$application['Runspaces'].Keys)) {
    if ('Closed', 'Broken' -contains `$application['Runspaces'][`$key].RunspaceStateInfo.State) {
        `$application['Runspaces'][`$key].Dispose()
        `$application['Runspaces'].Remove(`$key)
        continue
    }
    
    if (`$application['RunspaceAccessTimes'][`$key] -lt `$Timeout) {
        
        `$application['Runspaces'][`$key].CloseAsync()
        continue
    }    
}
            ").Invoke(null, invokeNoHistory);
            powerShellCommand.Commands.Clear();        

            powerShellCommand.AddCommand("Split-Path", false).AddParameter("Path", Request.ServerVariables["PATH_TRANSLATED"]).AddCommand("Set-Location").Invoke(null, invokeNoHistory);
            powerShellCommand.Commands.Clear();        

            results = powerShellCommand.AddScript(script, false).Invoke();        

        }
            
        
        foreach (Object obj in results) {
            if (obj != null) {
                if (obj is IEnumerable) {
                    if (obj is String) {
                        Response.Write(obj);
                    } else {
                        IEnumerable enumerableObj = (obj as IEnumerable);
                        foreach (Object innerObject in enumerableObj) {
                            if (innerObject != null) {
                                Response.Write(innerObject);
                            }
                        }
                    }
                    
                } else {
                    Response.Write(obj);
                }
                    
            }
        }
        
        foreach (ErrorRecord err in powerShellCommand.Streams.Error) {
            Response.Write("<span class='ErrorStyle' style='color:red'>" + err + "<br/>" + err.InvocationInfo.PositionMessage + "</span>");
        }

        powerShellCommand.Dispose();
    
    }
}
"@ | 
            Set-Content "$outputDirectory\PowerShellPageBase.cs"
        
            foreach ($pageAndContent in $PipeworksManifest.Pages.GetEnumerator()) {
                
                $pageName = $pageAndContent.Key 
                Write-Progress "Creating Pages" "$pageName"
                $safePageName = $pageName.Replace("|", " ").Replace("/", "-").Replace(":","-").Replace("!", "-").Replace(";", "-").Replace(" ", "_").Replace("@","at")
                $pageContent = $pageAndContent.Value
                $realPageContent = 
                    if ($pageContent -is [Hashtable]) {                    
                        if (-not $pageContent.Css -and $pipeworksManifest.Style) {
                            $pageContent.Css = $pipeworksManifest.Style
                        }
                        if ($pageContent.PageContent) {
                            $pageContent.PageContent = try { [ScriptBlock]::Create($pageContent.PageContent) } catch {}                                                         
                        }
                        if ($hasPosts) {
                            # If there are posts, add a link to the feed to all pages
                            $pageContent.Rss = @{
                                "$($Module.Name) Blog" = "$($module.Name).xml"
                            }
                        }
                        
                        # Pass down the analytics ID to the page if one is not explicitly set
                        if (-not $pageContent.AnalyticsId -and $analyticsId) {
                            $pageContent.AnalyticsId = $analyticsId
                        }
                        New-WebPage @pageContent
                    } elseif ($pageContent -like ".\*.pspg" -or $pageName -like "*.pspg" -or $pageName -like "*.pspage"){
                        # .PSPages.  These are mixed syntax HTML and Powershell inlined in markup <| |>  
                        # Because they are loaded within the moudule, a PSPAge will contain $embedCommand, which imports the module
                        if ($pageContent -notlike ".\*.pspg" -and $pageContent -notlike ".\*.pspage") {
                            # the content isn't a filepath, so treat it as inline code 
                            $wholePageContent = "<| $embedCommand |>" + $pageContent                           
                            ConvertFrom-InlinePowerShell -PowerShellAndHtml $wholePageContent -RunScriptMethod this.RunScript -CodeFile PowerShellPageBase.cs -Inherit PowerShellPage | 
                                Add-Member NoteProperty IsPsPage $true -PassThru
                        } else {
                            # The content is a path, treat it like one
                            $pagePath = Join-Path $moduleRoot $pageContent.TrimStart(".\")
                            if (Test-Path $pagePath) {
                                $pageContent = [IO.File]::ReadAllText($pagePath)
                                $wholePageContent = "<| $embedCommand |>" + $pageContent 
                                ConvertFrom-InlinePowerShell -PowerShellAndHtml $wholePageContent -CodeFile PowerShellPageBase.cs -Inherit PowerShellPage   | 
                                    Add-Member NoteProperty IsPsPage $true -PassThru
                            }         
                        }
                    } elseif ($pageName -like "*.*" -and $pageContent -as [Byte[]]) {
                        # Path to item
                        $itemPath = Join-Path $outputDirectory $pageName.TrimStart(".\")
                        $parentPath = $itemPath | Split-Path
                        if (-not (Test-Path "$parentPath")) {
                            $null = New-Item -ItemType Directory -Path "$parentPath"
                        }
                        [IO.File]::WriteAllBytes("$itemPath", $pageContent)
                    } elseif ($pageContent -like ".\*.htm*"){
                        # .HTML files
                        $pagePath = Join-Path $moduleRoot $pageContent.TrimStart(".\")
                        if (Test-Path $pagePath) {
                            try {
                                $potentialPagecontent = [IO.File]::ReadAllText($pagePath)                                
                                $pageContent = $potentialPagecontent 
                            } catch {
                                $_ | Write-Error
                            }
                        }
                    } else {
                        $pageContentAsScriptBlock = try { [ScriptBlock]::Create($pageContent) } catch { } 
                        if ($pageContentAsScriptBlock) {
                            & $pageContentAsScriptBlock
                        } else {
                            $pageContent
                        }
                    }
                
              
                
                if ($realPageContent.IsPsPage) {
                    $safePageName = $safePageName.Replace(".pspage", "").Replace(".pspg", "")
                    $parentPath = $safePageName | Split-Path
                    if (-not (Test-Path "$outputDirectory\$parentPath")) {
                        $null = New-Item -ItemType Directory -Path "$outputDirectory\$parentPath"
                    }
                    $realPageContent | 
                        Set-Content "$outputDirectory\${safepageName}.aspx"
                } else {
                    # Output the bytes
                    $parentPath = $safePageName | Split-Path
                    if (-not (Test-Path "$outputDirectory\$parentPath")) {
                        $null = New-Item -ItemType Directory -Path "$outputDirectory\$parentPath"
                    }
                    if ($pageContent -as [Byte[]]) {
                        [IO.File]::WriteAllBytes("$outputDirectory\$($pageName)", $pageContent)
                    } else {
                        [IO.File]::WriteAllText("$outputDirectory\$($pageName)", $pageContent)
                    }
                    <#                    
                    $safePageName = $safePageName.Replace(".html", "").Replace(".htm", "")
                    $parentPath = $safePageName | Split-Path
                    if (-not (Test-Path "$outputDirectory\$parentPath")) {
                        $null = New-Item -ItemType Directory -Path "$outputDirectory\$parentPath"
                    }
                    $realPageContent | 
                        Set-Content "$outputDirectory\${safepageName}.html"
                    #>
                }
            }            
        }
        #endregion Pages
        
        
               
        #region Command Handlers
        $webCmds = @()
        $downloadableCmds = @()
        $cmdOutputDirs = @()
        foreach ($command in $module.ExportedCommands.Values) {
            # Generate individual handlers
            $extraParams = if ($pipeworksManifest -and $pipeworksManifest.WebCommand.($Command.Name)) {                
                $pipeworksManifest.WebCommand.($Command.Name)
            } else { 
                @{
                    ShowHelp = $true
                } 
            }             
            
            if ($pipeworksManifest -and $pipeworksManifest.Style -and (-not $extraParams.Style)) {
                $extraParams.Style = $pipeworksManifest.Style 
            }
            if ($extraParams.Count -gt 1) {
                # Very explicitly make sure it's there, and not explicitly false
                if (-not $extra.RunOnline -or 
                    $extraParams.Contains("RunOnline") -and $extaParams.RunOnline -ne $false) {
                    $extraParams.RunOnline = $true                     
                }                
            } 
            
            if ($extaParams.PipeInto) {
                $extaParams.RunInSandbox = $true
            }
            
            if (-not $extraParams.AllowDownload) {
                $extraParams.AllowDownload = $allowDownload
            }
            
            if ($extraParams.RunOnline) {
                # Commands that can be run online
                $webCmds += $command.Name
            }
            
            if ($extraParams.RequireAppKey -or $extraParams.RequireLogin -or $extraParams.IfLoggedAs -or $extraParams.ValidUserPartition) {
                $extraParams.UserTable = $pipeworksManifest.Usertable.Name
                $extraParams.UserPartition = $pipeworksManifest.Usertable.Partition
                $extraParams.StorageAccountSetting = $pipeworksManifest.Usertable.StorageAccountSetting
                $extraParams.StorageKeySetting = $pipeworksManifest.Usertable.StorageKeySetting 
            }
            
            if ($extraParams.AllowDownload) {
                # Downloadable Commands
                $downloadableCommands += $command.Name                
            }
                        
            
            
            if ($psBoundParameters.OutputDirectory) {
                $extraParams.OutputDirectory = Join-Path $psBoundParameters.OutputDirectory $command.Name
                $cmdOutputDirs += "$(Join-Path $psBoundParameters.OutputDirectory $command.Name)"                
            } else {
                $extraParams.OutputDirectory = Join-Path $OutputDirectory $command.Name
            }
            
            if ($MarginPercentLeftString -and (-not $extraParams.MarginPercentLeft)) {
                $extraParams.MarginPercentLeft = $MarginPercentLeftString.TrimEnd("%")
            }
            
            if ($MarginPercentRightString-and -not $extraParams.MarginPercentRight) {
                $extraParams.MarginPercentRight = $MarginPercentRightString.TrimEnd("%")
            }
            
            if ($IsolateRunspace) {
                $extraParams.IsolateRunspace = $IsolateRunspace
            }
            
            if ($psBoundParameters.StartOnCommand) {
                # only create a full command service when the Module service starts on a command
                # ConvertTo-CommandService -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId"
            }
                        
            $cmdOutputDir = $extraParams.OutputDirectory.ToString()
            
        }
                                                             
        #endregion Command Handlers
        
        foreach ($cmdOutputDir in $cmdOutputDirs) {
            
        }

        if (-not $CommandOrder) {
            if ($pipeworksManifest.CommandOrder) {
                $CommandOrder = $pipeworksManifest.CommandOrder
            } else {
                $CommandOrder = $module.ExportedCommmands.Keys | Sort-Object
            }
        }
        
        # This script is embedded in the module handler
            $getModuleMetaData = {
$moduleRoot = [IO.Path]::GetDirectoryName($module.Path)
$psd1Path = $moduleRoot + '\' + $module.Name + '.psd1'
$versionHistoryPath = $moduleRoot + '\' + $module.Name + '.versionHistory.txt'
$versionHistoryExists = [IO.File]::Exists($versionHistoryPath)
$versionHistoryDetails = if ($versionHistoryExists) {
    [IO.File]::ReadAllText($versionHistoryPath)
} else {$null } 
        

# $currentPageCulture = 
$cultureNames = 
    foreach ($cult in ([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::AllCultures))) {
        $cult.Name
    }


$requestCulture = 
    if ($request -and $request["HTTP_ACCEPT_LANGUAGE"]) {
        $request["HTTP_ACCEPT_LANGUAGE"]
    } else {
        ""
    }


# en-us and the current request culture get are used to create a list of help topics
$aboutFiles  =  @(Get-ChildItem -Filter *.help.txt -Path "$moduleRoot\en-us" -ErrorAction SilentlyContinue)

if ($requestCulture -and ($requestCulture -ine 'en-us')) {
    $aboutFiles  +=  @(Get-ChildItem -Filter *.help.txt -Path "$moduleRoot\$requestCulture" -ErrorAction SilentlyContinue)
}


$walkThrus = @{}
$aboutTopics = @()
$namedTopics = @{}
$customAnyHandler = [IO.File]::Exists("$searchDirectory\AnyUrl.aspx")

$spacingDiv = "<div style='clear:both;margin-top:1.5%;margin-bottom:1.5%'></div>"

if ($aboutFiles) {
    foreach ($topic in $aboutFiles) {        
        if ($topic.fullname -like "*.walkthru.help.txt") {
            $topicName = $topic.Name.Replace('_',' ').Replace('.walkthru.help.txt','')
            $walkthruContent = Get-Walkthru -File $topic.Fullname            
            $walkThruName = $topicName             
            $walkThrus[$walkThruName] = $walkthruContent                                     
        } else {
            $topicName = $topic.Name.Replace(".help.txt","")
            $aboutTopics += 

                New-Object PSObject -Property @{

                    Name = $topicName.Replace("_", " ")
                    SystemName = $topicName
                    Topic = Get-Help $topicName
                    LastWriteTime = $topic.LastWriteTime
                } 
        }
    }
}
}

        $topicRssHandler = {
        

    if ($aboutTopics) {
        $feed = $aboutTopics | 
            New-RssItem -Author {
                if ($module.Author) {
                    $module.Author
                } else {
                    " "
                }
            } -Title {$_.Name } -Description { 
                ConvertFrom-Markdown -Markdown $_.Topic -ScriptAsPowerShell
            } -DatePublished { $_.LastWriteTime } -Link {
                if ($customAnyHandler) {                    
                    "?About=" + $_.Name                    
                } else {                    
                    $_.Name + "/"                    
                }
            } |
            Out-RssFeed -Title "$($module.Name) | Topics" -Description "$($module.Description) " -Link "/"

        $response.ContentType = "text/xml"
        $strWrite = New-Object IO.StringWriter
        ([xml]($feed)).Save($strWrite)
        $resultToOutput  = "$strWrite" -replace "encoding=`"utf-16`"", "encoding=`"utf-8`""
        $response.Write("$resultToOutput")        
    } 

}

        $walkThruRssHandler = {


        $feed = $walkThrus.Keys |
            Sort-Object {
                $walkthrus[$_] | Select-Object -ExpandProperty LastWriteTime -Unique
            } |
            New-RssItem -Title { 
                $_
            } -Author {
                if ($module.Author) {
                    $module.Author
                } else {
                    " "
                }
            } -Description {
                Write-WalkthruHTML -WalkThru ($walkThrus[$_]) 
            } -DatePublished {
                $walkThrus[$_] | Select-Object -ExpandProperty LastWriteTime -Unique
            } -Link {
                if ($customAnyHandler) {                    
                    "?Walkthru=" + $_
                } else {                    
                    $_ + "/"                    
                }
            } |
            Out-RssFeed -Title "$($module.Name) | Topics" -Description "$($module.Description) " -Link "/"

        if ($feed) {
            $response.ContentType = "text/xml"
            $strWrite = New-Object IO.StringWriter
            ([xml]($feed)).Save($strWrite)
            $resultToOutput  = "$strWrite" -replace "encoding=`"utf-16`"", "encoding=`"utf-8`""
            $response.Write("$resultToOutput")        
        }

}
        

        #region About Topic Handler
        $aboutHandler = {

$theTopic = $aboutTopics | 
    Where-Object { 
    $_.SystemName -eq $request['about'].Trim() -or 
    $_.Name -eq $request['About'].Trim()
}

$topicMatch = if ($theTopic) {
    ConvertFrom-Markdown -Markdown $theTopic.Topic -ScriptAsPowerShell
} else {
    '<span style=''color:red''>Topic not found</span>'
}
    
    
    $page =(New-Region -LayerID "About$($module.Name)Header" -AsWidget -Style @{
            'margin-left' = $MarginPercentLeftString
            'margin-right' = $MarginPercentRightString
        } -Content "
            <h1 itemprop='name' class='ui-widget-header'><a href='.'>$($module.Name)</a> | $($Request['about'].Replace('_', ' '))</h1>            
        "),(New-Region -Container "About$($module.Name)" -Style @{
            'margin-left' = $MarginPercentLeftString
            'margin-right' = $MarginPercentRightString
        } -AsAccordian -HorizontalRuleUnderTitle -DefaultToFirst -Layer @{
            $request['about'].Replace("_", " ") = "
            <div itemprop='ArticleText'>
            $topicMatch
            </div>
            "   
        }) |
        New-WebPage -UseJQueryUI -Css $cssStyle -Title "$($module.Name) | About $($Request['about'])" -AnalyticsID "$analyticsId"
    $response.contentType = 'text/html'
    $response.Write("$page")
        }
        #endregion About Topic Handler
                        
        #region Walkthru (Demo) Handler
        $walkThruHandler = {
$pipeworksManifestPath = Join-Path (Split-Path $module.Path) "$($module.Name).Pipeworks.psd1"
$pipeworksManifest = if (Test-Path $pipeworksManifestPath) {
    try {                     
        & ([ScriptBlock]::Create(
            "data -SupportedCommand Add-Member, New-WebPage, New-Region, Write-CSS, Write-Ajax, Out-Html, Write-Link { $(
                [ScriptBlock]::Create([IO.File]::ReadAllText($pipeworksManifestPath))                    
            )}"))            
    } catch {
        Write-Error "Could not read pipeworks manifest: ($_ | Out-String)" 
    }                                                
} else { $null } 
    
    
$topicMatch = 
    if ($walkthrus.($request['walkthru'].Trim())) {
        # Use splatting to tack on any extra parameters
        $params = @{
            Walkthru = $walkthrus.($request['walkthru'].Trim())
            WalkThruName = $request['walkthru'].Trim()
            StepByStep = $true
        }    

        if ($pipeworksManifest.TrustedWalkthrus -contains $request['Walkthru'].Trim()) {
            $params['RunDemo'] = $true
        }
        if ($pipeworksManifest.WebWalkthrus -contains $request['Walkthru'].Trim()) {
            $params['OutputAsHtml'] = $true
        }
        Write-WalkthruHTML @params
    } else {
        '<span style=''color:red''>Topic not found</span>'
    }
        $page = (New-Region -LayerID "About$($module.Name)Header" -AsWidget -Style @{
            'margin-left' = $MarginPercentLeftString
            'margin-right' = $MarginPercentRightString
        } -Content "
            <h1 itemprop='name' class='ui-widget-header'><a href='.'>$($module.Name)</a> | $($Request['walkthru'].Replace('_', ' '))</h1>            
        "), 
        (New-Region -LayerId WalkthruContainer -Style @{
            'margin-left' = $MarginPercentLeftString
            'margin-right' = $MarginPercentRightString
        } -Content $topicMatch ) |
        New-WebPage -UseJQueryUI -Css $cssStyle -Title "$($module.Name) | Walkthrus | $($Request['walkthru'].Replace('_', ' '))" -AnalyticsID '$analyticsId' 
$response.contentType = 'text/html'
$response.Write("$page")

        }
        #endregion Walkthru (Demo) Handler   
        
        #region Help Handler
        $helpHandler = {
            $RequestedCommand = $Request["GetHelp"]               
            
            $webCmds = @()
            $downloadableCmds = @()
            $cmdOutputDirs = @()
            
            $command = $module.ExportedCommands[$RequestedCommand]
            
            if (-not $command)  {
                throw "$requestedCommand not found in module $module"
            }
         
            $extraParams = if ($pipeworksManifest -and $pipeworksManifest.WebCommand.($Command.Name)) {                
                $pipeworksManifest.WebCommand.($Command.Name)
            } else { @{} }                
            
            $extraParams.ShowHelp=$true


            $titleArea = 
                if ($PipeworksManifest -and $pipeworksManifest.Logo) {
                    "<a href='$FinalUrl'><img src='$($pipeworksManifest.Logo)' style='border:0' /></a>"
                } else {
                    "<a href='$FinalUrl'>$($Module.Name)</a>"
                }

            $TitleAlignment = if ($pipeworksManifest.Alignment) {
                $pipeworksManifest.Alignment
            } else {
                'center'
            }
            $titleArea = "<div style='text-align:$TitleAlignment'><h1 style='text-align:$TitleAlignment'>$titleArea</h1></div>"
            # Create a Social Row (Facebook Likes, Google +1, Twitter)
            $socialRow = "
                <div style='padding:20px'>
            "

            if (-not $antiSocial) {
                if ($pipeworksManifest -and $pipeworksManifest.Facebook.AppId) {
                    $socialRow +=  
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "facebook:like" ) + 
                        "</span>"
                }
                if ($pipeworksManifest -and ($pipeworksManifest.GoogleSiteVerification -or $pipeworksManifest.AddPlusOne)) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "google:plusone" ) +
                        "</span>"
                }
                if ($pipeworksManifest -and ($pipeworksManifest.Tweet -or $pipeworksManifest.AddTweet)) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:tweet" ) +
                        "</span>"
                } elseif ($pipeworksManifest -and ($pipeworksManifest.TwitterId)) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:tweet" ) +
                        "</span>"
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:follow@$($pipeworksManifest.TwitterId.TrimStart('@'))" ) +
                        "</span>"
                }
            }
                     
            $socialRow  += "</div>"        
            
            $result = 
                Invoke-Webcommand -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1

            if ($result) {
                if ($Request.params["AsRss"] -or 
                    $Request.params["AsCsv"] -or
                    $Request.params["AsXml"] -or
                    $Request.Params["bare"]) {
                    $response.Write($result)
                } else {
                    $outputPage = $socialRow + $titleArea + $spacingDiv + $descriptionArea +($spacingDiv * 4) +$result |
                        New-Region -Style @{
                            "Margin-Left" = $marginPercentLeftString
                            "Margin-Right" = $marginPercentLeftString
                        }|
                        New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI 
                    $response.Write($outputPage)
                }                
            }
            
        }
        #endregion Help Handler
        
        #region Command Handler
        $commandHandler = {
            
            
            $RequestedCommand = $Request["Command"]                                                   
            
            
            . $getCommandExtraInfo $RequestedCommand

            $result = try {
                Invoke-Webcommand -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1
            } catch {
                $_
            }

            $titleArea = 
                if ($PipeworksManifest -and $pipeworksManifest.Logo) {
                    "<a href='$FinalUrl'><img src='$($pipeworksManifest.Logo)' style='border:0' /></a>"
                } else {
                    "<a href='$FinalUrl'>" + $Module.Name + "</a>"
                }

            $TitleAlignment = if ($pipeworksManifest.Alignment) {
                $pipeworksManifest.Alignment
            } else {
                'center'
            }
            $titleArea = "<div style='text-align:$TitleAlignment'><h1 style='text-align:$TitleAlignment'>$titleArea</h1></div>"

            $commandDescription  = ""                        
            $commandHelp = Get-Help $command -ErrorAction SilentlyContinue | Select-Object -First 1 
            if ($commandHelp.Description) {
                $commandDescription = $commandHelp.Description[0].text
                $commandDescription = $commandDescription -replace "`n", ([Environment]::NewLine) 
            }

            $descriptionArea = "<h2 style='text-align:$titleAlignment' >
            <div style='margin-left:30px;margin-top:15px;margin-bottom:15px'>
            $(ConvertFrom-Markdown -Markdown "$commandDescription ")
            </div>
            </h2>
            <br/>"

            if ($result) {
                if ($Request.params["AsRss"] -or 
                    $Request.params["AsCsv"] -or
                    $Request.params["AsXml"] -or
                    $Request.Params["bare"] -or 
                    $extraParams.ContentType -or
                    $extraParams.PlainOutput) {
                            
                            
                    if (-not ($extraParams.ContentType) -and                        
                        $result -like "*<*>*" -and 
                        $result -like '*`$(*)*') {
                        # If it's not HTML or XML, but contains tags, then render it in a page with JQueryUI
                        $outputPage = $socialRow +  $spacingDiv + $descriptionArea + $spacingDiv + $result |
                            New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                        $response.Write($outputPage)
                    } else {
                        $response.Write($result)
                    }
                            
                } else {
                    if (($result -is [Collections.IEnumerable]) -and ($result -isnot [string])) {
                        $Result = $result | Out-HTML                                
                    }
                    if ($request["Snug"]) {
                        $outputPage = $socialRow + "<div style='clear:both;margin-top:1%'> </div>" +  "<div style='float:left'>$(ConvertFrom-Markdown -Markdown "$commandDescription ")</div>" +  "<div style='clear:both;margin-top:1%'></div>" + $result |
                            New-Region -Style @{
                                "Margin-Left" = "1%"
                                "Margin-Right" = "1%"
                            }|
                            New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                        $response.Write($outputPage)
                    } else {
                        $outputPage = $socialRow + $titleArea +  "<div style='clear:both;margin-top:1%'></div>" + $descriptionArea + $spacingDiv + $result |
                        New-Region -Style @{
                            "Margin-Left" = $marginPercentLeftString
                            "Margin-Right" = $marginPercentLeftString
                        }|
                        New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                        $response.Write($outputPage)
                    }
                            
                }                
            }
                        
            
        }
                
        #endregion Command Handler
        $validateUserTable = {
            if (-not ($pipeworksManifest.UserTable.Name -and $pipeworksManifest.UserTable.StorageAccountSetting -and $pipeworksManifest.UserTable.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include these settings in order to manage users: UserTable.Name, UserTable.EmailAddress, UserTable.ExchangeServer, UserTable.ExchangePasswordSetting UserTable.StorageAccountSetting, and UserTable.StorageKeySetting'
                return
            }            
        }
                
        
        
        #region Join Handler
        $joinHandler = $validateUserTable.ToString()  + {
            $DisplayForm = $false
            $FormErrors = ""
          
            
          
            
            if (-not $request["Join-$($module.Name)_EmailAddress"]) {
                #$missingFields 
                $displayForm = $true
            }
            
            $newUserData =@{}
            $missingFields = @()
            $paramBlock = @()
            if ($session['ProfileEditMode'] -eq $true) {
                $editMode = $true
            }
            $defaultValue = if ($editMode -and $session['User'].UserEmail) {
                "|Default $($session['User'].UserEmail)"
            } else {
                ""
            }
            
            if ($Request['ReferredBy']) {
                $session['ReferredBy'] = $Request['ReferredBy']
            }
            $paramBlock += "
            #$defaultValue
            [Parameter(Mandatory=`$true,Position=0)]
            [string]
            `$EmailAddress
            "
            if ($pipeworksManifest.UserTable.RequiredInfo) {
                $Position = 1
                foreach ($k in $pipeworksManifest.UserTable.RequiredInfo.Keys) {
                    $newUserData[$k] = $request["Join-$($module.Name)_${k}"] -as $pipeworksManifest.UserTable.RequiredInfo[$k]
                    $defaultValue = if ($session['User'].$k) {
                        "|Default $($session['User'].$k)"
                    } else {
                        ""
                    }
                    
                    $paramBlock += "
            #$defaultValue
            [Parameter(Mandatory=`$true,Position=$position)]
            [$($pipeworksManifest.UserTable.RequiredInfo[$k].Fullname)]
            `$$k
            "
                    $Position++
                    if (-not $newUserData[$k]) { 
                        $missingFields += $k
                    }
                }
            }
            
            
            if ($pipeworksManifest.UserTable.OptionalInfo) {
                foreach ($k in $pipeworksManifest.UserTable.OptionalInfo.Keys) {
                    $newUserData[$k] = $request["Join-$($module.Name)_${k}"] -as $pipeworksManifest.UserTable.OptionalInfo[$k]
                    $defaultValue = if ($session['User'].$k) {
                        "|Default $($session['User'].$k)"
                    } else {
                        ""
                    }
                    $paramBlock += "
            #${defaultValue}
            [Parameter(Position=$position)]
            [$($pipeworksManifest.UserTable.OptionalInfo[$k].Fullname)]
            `$$k
            "
                }
            }
            
            
            if ($pipeworksManifest.UserTable.TermsOfService) {
            
            }
            
            .([ScriptBlock]::Create(
                "function Join-$($module.Name) {
                    <#
                    .Synopsis
                        Joins $($module.Name) or edits a profile
                    .Description
                           
                    #>
                    param(
                    $($paramBlock -join ",$([Environment]::NewLine)")
                    )
                }                
                "))
            
            $cmdInput = Get-WebInput -CommandMetaData (Get-Command "Join-$($module.Name)" -CommandType Function)
            if ($cmdInput.Count -gt 0) {
                $DisplayForm = $false
            }
            
            
            if ($missingFields) {
                $email = $request["Join-$($module.Name)_EmailAddress"]
                $emailFound = [ScriptBlock]::Create("`$_.UserEmail -eq '$email'")
                $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting)
                $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting)

                $mailAlreadyExists = 
                    Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -StorageAccount $storageAccount -StorageKey $storageKey  -Where $emailFound

                if (-not $mailAlreadyExists) {
                    # Get required fields
                    $DisplayForm = $true
                } elseif ($editMode -and $session['User']) {
                    # Get required fields
                    $DisplayForm = $true
                } else {
                    # Reconfirm
                    $DisplayForm = $false
                }
                
            }

                    
            $sendMailParams = @{
                BodyAsHtml = $true
                To = $request["Join-$($module.Name)_EmailAddress"]
                
            }
            
            $sendMailCommand = if ($pipeworksManifest.UserTable.SmtpServer -and $pipeworksManifest.UserTable.FromEmail -and $pipeworksManifest.UserTable.FromUser -and $pipeworksManifest.UserTable.EmailPasswordSetting) {
                $($ExecutionContext.InvokeCommand.GetCommand("Send-MailMessage", "All"))
                $un  = $pipeworksManifest.UserTable.FromUser
                $pass = Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.EmailPasswordSetting
                $pass = ConvertTo-SecureString $pass  -AsPlainText -Force 
                $cred = 
                    New-Object Management.Automation.PSCredential ".\$un", $pass 
                        
                $sendMailParams += @{
                    SmtpServer = $pipeworksManifest.UserTable.SmtpServer 
                    From = $pipeworksManifest.UserTable.FromEmail
                    Credential = $cred
                    UseSsl = $true
                }

            } else {
                $($ExecutionContext.InvokeCommand.GetCommand("Send-Email", "All"))
                $sendMailParams += @{
                    UseWebConfiguration = $true
                    AsJob = $true
                }
            }
            
            
            if ($displayForm) {
                $formErrors = if ($missingFields -and ($cmdInput.Count -ne 0)) {
                    "Missing $missingFields"
                } else {
                
                }                                
                
                $buttonText = if ($mailAlreadyExists -or $session['User']) {
                    "Edit Profile"                    
                } else {
                    "Join / Login"
                }

                
                $response.Write("
                $FormErrors
                $(Request-CommandInput -ButtonText $buttonText -Action "${FinalUrl}?join=true" -CommandMetaData (Get-Command "Join-$($module.Name)" -CommandType Function))
                ")
                
            } else {
                $session['UserEmail'] = $request["Join-$($module.Name)_EmailAddress"]
                $session['UserData'] = $newUserData
                $session['EditMode'] = $editMode
                
                
                $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting)
                $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting)

                $email = $Session['UserEmail']
                $editMode = $session['EditMode']
                $session['EditMode'] = $null
                $emailFound = [ScriptBlock]::Create("`$_.UserEmail -eq '$email'")

                $userProfilePartition =
                    if (-not $pipeworksManifest.UserTable.Partition) {
                        "UserProfiles"
                    } else {
                        $pipeworksManifest.UserTable.Partition
                    }

                
                $mailAlreadyExists = 
                    Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -StorageAccount $storageAccount -StorageKey $storageKey  -Where $emailFound |
                    Where-Object {
                        $_.PartitionKey -eq $userProfilePartition
                    }
                
                
                $newUserObject = New-Object PSObject -Property @{
                    UserEmail = $Session['UserEmail']
                    UserID = [GUID]::NewGuid()
                    Confirmed = $false
                    Created = Get-Date                
                }
                
                
                $ConfirmCode = [Guid]::NewGuid()
                $newUserObject.pstypenames.clear()
                $newUserObject.pstypenames.add("$($module.Name)_UserInfo")
                
                $extraPropCommonParameters = @{
                    InputObject = $newUserObject
                    MemberType = 'NoteProperty'
                }
                        
                Add-Member @extraPropCommonParameters -Name ConfirmCode -Value "$confirmCode"
                if ($session['UserData']) {
                    foreach ($kvp in $session['UserData'].GetEnumerator()) {
                        Add-Member @extraPropCommonParameters -Name $kvp.Key -Value $kvp.Value
                    }
                }
                
                $commonAzureParameters = @{
                    TableName = $pipeworksManifest.UserTable.Name
                    PartitionKey = $userProfilePartition
                }
                
                
                
                if ($mailAlreadyExists) {
                    
                    
                    
                    if ((-not $editMode) -or (-not $session['User'])) {
                    
                        # Creating a brand new item via the email system.  Email the confirmation code out.
                    
                    
                        $rootLocation= "$finalUrl".Substring(0, $finalUrl.LAstIndexOf("/"))
                        $introMessage = if ($pipeworksManifest.UserTable.IntroMessage) {
                            $pipeworksManifest.UserTable.IntroMessage + "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Confirm Email Address</a>"
                        } else {
                            "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Re-confirm Email Address to login</a>"
                        }
                        
                        $sendMailParams += @{
                            Subject= "Please re-confirm your email for $($module.Name)"
                            Body = $introMessage
                        }                    
                        
                        
                        & $sendMailcommand @sendMailParams 
                        
                        "Account already exists.  A request to login has been sent to $($mailAlreadyExists.UserEmail)." |
                            New-WebPage -Title "Email address is already registered, sending reconfirmation mail" -RedirectTo $rootLocation -RedirectIn "0:0:5"  |
                            Out-HTML -WriteResponse                                                           #
                            
                        <# Send-Email -To $newUserObject.UserEmail -UseWebConfiguration - -Body $introMessage -BodyAsHtml -AsJob                
                        "Account already exists.  A request to login has been sent to $($mailAlreadyExists.UserEmail)." |
                            New-WebPage -Title "Email address is already registered, sending reconfirmation mail" -RedirectTo $rootLocation -RedirectIn "0:0:5"  |
                            Out-HTML -WriteResponse                                                           #>
                        
                        $mailAlreadyExists |
                            Add-Member NoteProperty ConfirmCode "$confirmCode" -Force -PassThru | 
                            Update-AzureTable @commonAzureParameters -RowKey $mailAlreadyExists.RowKey -Value { $_}
                    } else {
                        
                        # Reconfirmation of Changes.  If the user is logged in via facebook, then simply make the change.  Otherwise, make the changes pending.
                        if (-not $pipeworksManifest.Facebook.AppId) {
                        
                            $introMessage = 
                            "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Please confirm changes to your $($module.Name) account</a>"                   
                            
                            $introMessage += "<br/><br/>"
                            $introMessage += New-Object PSObject -Property $session['UserData'] |
                                Out-HTML
                         
                            $sendMailParams += @{
                                Subject= "Please confirm changes to your $($module.Name) account"
                                Body = $introMessage
                            }   
                            
                            & $sendMailcommand @sendMailParams
                            
                            "An email has been sent to $($mailAlreadyExists.UserEmail) to confirm the changes to your acccount" |
                                New-WebPage -Title "Confirming Changes" -RedirectTo $rootLocation -RedirectIn "0:0:5" |
                                Out-HTML -WriteResponse
                            
                            $mailAlreadyExists |
                                Add-Member NoteProperty ConfirmCode "$confirmCode" -Force -PassThru | 
                                Update-AzureTable @commonAzureParameters -RowKey $mailAlreadyExists.RowKey -Value { $_}
                            $changeToMake = @{} + $commonAzureParameters
                            
                            $changeToMake.PartitionKey = "${userProfilePartition}_PendingChanges"
                                                
                            # Create a row in the pending change table
                            $newUserObject.psobject.properties.Remove('ConfirmCode')
                            $newUserObject |
                                Set-AzureTable @changeToMake -RowKey {[GUID]::NewGuid() } 
                        } else {
                            # Make the profile change
                            $newUserObject |
                                Update-AzureTable @commonAzureParameters -RowKey $mailAlreadyExists.RowKey
                        }
                        
                            
                            
                    }
                    
                    
                } else {
                    # Check for a whitelist or blacklist within the user table
                    if ($pipeworksManifest.UserTable.BlacklistParition) {
                        $blackList = 
                            Search-AzureTable -TableName $pipeworks.UserTable.Name -Filter "PartitionKey eq '$($pipeworksManifest.UserTable.BlacklistParition)'"                        
                            
                        if ($blacklist) {
                            foreach ($uInfo in $Blacklist) {
                                if ($newUserObject.UserEmail -like "*$uInfo*") {
                                    Write-Error "$($newUserObject.UserEmai) is blacklisted from $($module.Name)"
                                    return
                                }
                            }
                        }
                    }
                    
                    if ($pipeworksManifest.UserTable.WhitelistPartition) {
                        $whiteList = 
                            Search-AzureTable -TableName $pipeworks.UserTable.Name -Filter "PartitionKey eq '$($pipeworksManifest.UserTable.WhitelistParition)'"                        
                            
                        if ($whiteList) {
                            $inWhiteList = $false
                            foreach ($uInfo in $whiteList) {
                                if ($newUserObject.UserEmail -like "*$uInfo*") {
                                    $inWhiteList = $true
                                    break
                                }
                            }
                            if (-not $inWhiteList) {
                                Write-Error "$($newUserObject.UserEmai) is not on the whitelist for $($module.Name)"
                            }
                        }

                    }
                    
                    if ($pipeworksManifest.UserTable.InitialBalance) {
                        $newUserObject | 
                            Add-Member NoteProperty Balance (0- ([Double]$pipeworksManifest.UserTable.InitialBalance))
                    }
                
                    if ($session['RefferedBy']) {
                        $newUserObject |
                            Add-Member NoteProperty RefferedBy $session['RefferedBy'] -PassThru |
                            Add-Member NoteProperty RefferalCreditApplied $false 
                    }
                
                    $newUserObject |
                        Set-AzureTable @commonAzureParameters -RowKey $newUserObject.UserId
                        
                        
                    $introMessage = if ($pipeworksManifest.UserTable.IntroMessage) {
                        $pipeworksManifest.UserTable.IntroMessage + "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Confirm Email Address</a>"
                    } else {
                        "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Confirm Email Address</a>"
                    }
                    
                    $sendMailParams += @{
                        Subject= "Please confirm your email for $($module.Name)"
                        Body = $introMessage
                    }
                    & $sendMailcommand @sendMailParams
                                    
                    if ($passThru) {
                        $newUserObject
                    }
                    
                    $almostWelcomeScreen  = if ($pipeworksManifest.UserTable.ConfirmationMailSent) {
                        $pipeworksManifest.UserTable.ConfirmationMailSent 
                    } else {
                        "A confirmation mail has been sent to $($newUserObject.UserEmail)"
                    }
                                    
                    $html = New-Region -Content $almostWelcomeScreen -AsWidget -Style @{
                        'margin-left' = $MarginPercentLeftString
                        'margin-right' = $MarginPercentRightString
                        'margin-top' = '10px'   
                        'border' = '0px' 
                    } |
                    New-WebPage -Title "Welcome to $($module.Name) | Confirmation Mail Sent" 
                    
                    $response.Write($html)                      
                    
                    
                }
                
            }
            
        }
        #endregion

        $AddUserStat = $validateUserTable.ToString() + { 
            if (-not $session["User"]) {
                throw "Must be logged in"
               
            }
                        


        }

        
        
        $ShowApiKeyHandler = $validateUserTable.ToString() + {
            if ($request.Cookies["$($module.Name)_ConfirmationCookie"]) {
                $response.Write($request.Cookies["$($module.Name)_ConfirmationCookie"]["Key"])
            }
        }
        
        $logoutUserHandler = $validateUserTable.ToString()  + {                        
            $secondaryApiKey = $session["$($module.Name)_ApiKey"]
            $confirmCookie = New-Object Web.HttpCookie "$($module.Name)_ConfirmationCookie"
            $confirmCookie["Key"] = "$secondaryApiKey"
            $confirmCookie["CookiedIssuedOn"] = (Get-Date).ToString("r")
            $confirmCookie.Expires = (Get-Date).AddDays(-365)                    
            $response.Cookies.Add($confirmCookie)
            $session['User'] = $null            
            $html = New-WebPage -Title "Logging Out" -RedirectTo "$finalUrl"
            $response.Write($html)                        
        }
        
        $loginUserHandler = $validateUserTable.ToString()  + {

            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting)
            $confirmCookie= $Request.Cookies["$($module.Name)_ConfirmationCookie"]
            
            if ($confirmCookie) {            
                $matchApiInfo = [ScriptBLock]::Create("`$_.SecondaryApiKey -eq '$($confirmCookie.Values['Key'])'")           
                $userFound = 
                    Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -StorageAccount $storageAccount -StorageKey $storageKey -Where $matchApiInfo 
                
                if (-not $userFound) {
                    $secondaryApiKey = $session["$($module.Name)_ApiKey"]
                    $confirmCookie = New-Object Web.HttpCookie "$($module.Name)_ConfirmationCookie"
                    $confirmCookie["Key"] = "$secondaryApiKey"
                    $confirmCookie["CookiedIssuedOn"] = (Get-Date).ToString("r")
                    $confirmCookie.Expires = (Get-Date).AddDays(-365)                    
                    $response.Cookies.Add($confirmCookie)
                    $response.Flush()
                    
                    $response.Write("User $($confirmCookie | Out-String) Not Found, ConfirmationCookie Set to Expire")                                        
                    return
                }                                        

                $userIsConfirmed = $userFound |
                    Where-Object {
                        $_.Confirmed -ilike "*$true*" 
                    }
                    
                $userIsConfirmedOnThisMachine = $userIsConfirmed |
                    Where-Object {
                        $_.ConfirmedOn -ilike "*$($Request['REMOTE_ADDR'] + $request['REMOTE_HOST'])*"
                    }
                    
                $sendMailParams = @{
                    BodyAsHtml = $true
                    To = $newUserObject.UserEmail
                }
                
                $sendMailCommand = if ($pipeworksManifest.UserTable.SmtpServer -and 
                    $pipeworksManifest.UserTable.FromEmail -and 
                    $pipeworksManifest.UserTable.FromUser -and 
                    $pipeworksManifest.UserTable.EmailPasswordSetting) {
                    $($ExecutionContext.InvokeCommand.GetCommand("Send-MailMessage", "All"))
                    $un  = $pipeworksManifest.UserTable.FromUser
                    $pass = Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.EmailPasswordSetting
                    $pass = ConvertTo-SecureString $pass  -AsPlainText -Force 
                    $cred = 
                        New-Object Management.Automation.PSCredential ".\$un", $pass 
                    $sendMailParams += @{
                        SmtpServer = $pipeworksManifest.UserTable.SmtpServer 
                        From = $pipeworksManifest.UserTable.FromEmail
                        Credential = $cred
                        UseSsl = $true
                    }
                    
                } else {
                    $($ExecutionContext.InvokeCommand.GetCommand("Send-Email", "All"))
                    $sendMailParams += @{
                        UseWebConfiguration = $true
                        AsJob = $true
                    }
                }
                        
                if (-not $userIsConfirmedOnThisMachine) {
                    $confirmCode = [guid]::NewGuid()
                    Add-Member -MemberType NoteProperty -InputObject $userIsConfirmed -Name ConfirmCode -Force -Value "$confirmCode"
                    
                    
                    $introMessage = if ($pipeworksManifest.UserTable.IntroMessage) {
                        $pipeworksManifest.UserTable.IntroMessage + "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Confirm Email Address</a>"
                    } else {
                        "<br/> <a href='${finalUrl}?confirmUser=$confirmCode'>Confirm Email Address</a>"
                    }
                    
                    $sendMailParams += @{
                        Subject= "Welcome to $($module.Name)"
                        Body = $introMessage
                    }                    
                    
                    
                    & $sendMailcommand @sendMailParams

                    # Send-Email -To $userIsConfirmed.UserEmail -UseWebConfiguration -Subject  -Body $introMessage -BodyAsHtml -AsJob
                    $partitionKey = $userIsConfirmed.PartitionKey
                    $rowKey = $userIsConfirmed.RowKey
                    $tableName = $userIsConfirmed.TableName
                    $userIsConfirmed.psobject.properties.Remove('PartitionKey')
                    $userIsConfirmed.psobject.properties.Remove('RowKey')
                    $userIsConfirmed.psobject.properties.Remove('TableName')                    
                    $userIsConfirmed |
                        Update-AzureTable -TableName $tableName -RowKey $rowKey -PartitionKey $partitionKey -Value { $_} 
                    
                    $message = "User Not confirmed on this machine/ IPAddress.  A confirmation mail has been sent to $($userFound.UserEmail)"
                    
                    $html = New-Region -Content $message -AsWidget -Style @{
                        'margin-left' = $MarginPercentLeftString
                        'margin-right' = $MarginPercentRightString
                        'margin-top' = '10px'   
                        'border' = '0px' 
                    } |
                    New-WebPage -Title "$($module.Name)| Login Error: Unrecognized Machine"                    

                    
                    
                    $response.Write("$html")
                    
                    
                    return
                } else {
                    $session['User'] = $userIsConfirmedOnThisMachine
                    $session['UserId'] = $userIsConfirmedOnThisMachine.UserId
                    $welcomeBackMessage = "Welcome back " + $(
                        if ($userIsConfirmedOnThisMachine.Name) {
                            $userIsConfirmedOnThisMachine.Name
                        } else {
                            $userIsConfirmedOnThisMachine.UserEmail
                        }
                    )
                    
                    $secondaryApiKey = "$($confirmCookie.Values['Key'])"                    
                    
                    $backToUrl = if ($session['BackToUrl']) {
                        $session['BackToUrl']
                        $session['BackToUrl'] = $null
                    } else {
                        $finalUrl.ToString().Substring(0,$finalUrl.ToString().LastIndexOf("/"))
                    }
                    
                    $html = New-Region -Content $welcomeBackMessage -AsWidget -Style @{
                        'margin-left' = $MarginPercentLeftString
                        'margin-right' = $MarginPercentRightString
                        'margin-top' = '10px'   
                        'border' = '0px' 
                    } |
                    New-WebPage -Title "Welcome to $($module.Name)" -RedirectTo $backToUrl -RedirectIn "0:0:0.125"
                    $response.Write("$html")
                    
                    
   
                    
                    $partitionKey = $userIsConfirmedOnThisMachine.PartitionKey
                    $rowKey = $userIsConfirmedOnThisMachine.RowKey
                    $tableName = $userIsConfirmedOnThisMachine.TableName
                    $userIsConfirmedOnThisMachine.psobject.properties.Remove('PartitionKey')
                    $userIsConfirmedOnThisMachine.psobject.properties.Remove('RowKey')
                    $userIsConfirmedOnThisMachine.psobject.properties.Remove('TableName')                    
                    $userIsConfirmedOnThisMachine | Add-Member -MemberType NoteProperty -Name LastLogon -Force -Value (Get-Date)
                    $userIsConfirmedOnThisMachine | Add-Member -MemberType NoteProperty -Name LastLogonFrom -Force -Value "$($Request['REMOTE_ADDR'] + $request['REMOTE_HOST'])"
                    $userIsConfirmedOnThisMachine |
                        Update-AzureTable -TableName $tableName -RowKey $rowKey -PartitionKey $partitionKey -Value { $_} 
                        
                    $session['User'] = $userIsConfirmedOnThisMachine
                }
                
                
                
            } else {
            
                $html = New-WebPage -Title "User Information Not Found - Redirecting to Signup Page" -RedirectTo "${finalUrl}?join=true"
                $response.Write($html)
                return
            }

        }
        
        
        $confirmUserHandler = $validateUserTable.ToString()  + {
            
            $confirmationCode = [Web.HttpUtility]::UrlDecode($request['confirmUser']).TrimEnd(" ").TrimEnd("#").TrimEnd(">").TrimEnd("<")
            
            $session['ProfileEditMode'] = $false            
            
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting)
            $confirmCodeFilter = 
                [ScriptBLock]::Create("`$_.ConfirmCode -eq '$confirmationCode'")
            $confirmationCodeFound = 
                Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -StorageAccount $storageAccount -StorageKey $storageKey -Where $confirmCodeFilter
            
            if (-not $confirmationCodeFound) {
                Write-Error "Confirmation Code Not Found"
                return
            }
                        
            $confirmedOn = ($confirmationCodeFound.ConfirmedOn + "," +
                ($Request['REMOTE_ADDR'] + $request['REMOTE_HOST'])) -split "," -ne "" | Select-Object -Unique
            
            $confirmSalts = @($confirmationCodeFound.ConfirmSalt -split "\|")
            
            $confirmationCodeFound | 
                Add-Member NoteProperty Confirmed $true -Force
            $confirmationCodeFound |
                Add-Member NoteProperty ConfirmedOn ($confirmedOn -join ',') -Force
                
            
            # When we confirm the item, we set two cookies.  One keeps the Secondary API key, and the other a confirmation salt.  Both are HTTP only
            $ThisConfirmationSalt = [GUID]::NewGuid()
            $confirmSalts += $ThisConfirmationSalt 
            $confirmationCodeFound |                
                Add-Member NoteProperty ConfirmedOn ($confirmedOn -join ',') -Force
<#            $confirmationCodeFound |                
                Add-Member NoteProperty ConfirmSalt ($confirmSalts -join '|') -Force
#>            
            if (-not $confirmationCodeFound.PrimaryApiKey) { 
                $primaryApiKey  =[guid]::NewGuid()
                $secondaryApiKey = [guid]::NewGuid()
                $confirmationCodeFound |
                    Add-Member NoteProperty PrimaryApiKey "$primaryApiKey" -PassThru -ErrorAction SilentlyContinue |
                    Add-Member NoteProperty SecondaryApiKey "$secondaryApiKey" -ErrorAction SilentlyContinue  
            } else {
                $primaryApiKey = $confirmationCodeFound.PrimaryApiKey
                $secondaryApiKey = $confirmationCodeFound.SecondaryApiKey
                $sessionApiKey = [Convert]::ToBase64String(([Guid]$secondaryApiKey).ToByteArray())
                $session["$($module.Name)_ApiKey"] = $sessionApiKey
            }
            
            $confirmCookie = New-Object Web.HttpCookie "$($module.Name)_ConfirmationCookie"
            $confirmCookie["Key"] = "$secondaryApiKey"
            $confirmCookie["CookiedIssuedOn"] = (Get-Date).ToString("r")
            $confirmCookie["ConfirmationSalt"] = $ThisConfirmationSalt
            $confirmCookie["Email"] = $confirmationCodeFound.UserEmail
            $confirmCookie.Expires = (Get-Date).AddDays(365)
            $response.Cookies.Add($confirmCookie)
            
                
            $partitionKey = $confirmationCodeFound.PartitionKey
            $rowKey = $confirmationCodeFound.RowKey
            $tableName = $confirmationCodeFound.TableName
            $confirmCount =$confirmationCodeFound.ConfirmCount -as [int] 
            $confirmCount++
            $confirmationCodeFound | Add-Member NoteProperty ConfirmCount $ConfirmCount -Force
            $confirmationCodeFound.psobject.properties.Remove('PartitionKey')
            $confirmationCodeFound.psobject.properties.Remove('RowKey')
            $confirmationCodeFound.psobject.properties.Remove('TableName')
            $confirmationCodeFound.psobject.properties.Remove('ConfirmCode')
            
            
            # At this point they are actually confirmed
            $confirmationCodeFound | 
                Update-AzureTable -TableName $pipeworksManifest.UserTable.Name  -RowKey $rowKey -PartitionKey $partitionKey -Value { $_} 
                
            if ($confirmationCodeFound.ConfirmCount -eq 1 ) {
                $ConfirmMessage = @"
$($pipeworksManifest.UserTable.WelcomeEmailMessage)
<BR/>
Thanks for confirming,<br/>
<br/>
Your API key is: $secondaryApiKey <br/>
<br/>

Whenever you need to use a software service in $($module.Name), use this API key.

(It's also being emailed to you)
"@
                                            
                $html = New-Region -Content $confirmMessage -AsWidget -Style @{
                    'margin-left' = $MarginPercentLeftString
                    'margin-right' = $MarginPercentRightString
                    'margin-top' = '10px'   
                    'border' = '0px' 
                } |
                New-WebPage -Title "Welcome to $($module.Name)" -RedirectTo "${finalUrl}?login=true" -RedirectIn "0:0:5"
                $session['User']  = Get-AzureTable -TableName $pipeworksManifest.UserTable.Name  -RowKey $rowKey -PartitionKey $partitionKey
                $response.Write("$html")
                
                
                $sendMailParams = @{
                    BodyAsHtml = $true
                    To = $newUserObject.UserEmail
                }
                
                $sendMailCommand = if ($pipeworksManifest.UserTable.SmtpServer -and 
                    $pipeworksManifest.UserTable.FromEmail -and 
                    $pipeworksManifest.UserTable.FromUser -and 
                    $pipeworksManifest.UserTable.EmailPasswordSetting) {
                    $($ExecutionContext.InvokeCommand.GetCommand("Send-MailMessage", "All"))
                    $un  = $pipeworksManifest.UserTable.FromUser
                    $pass = Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.EmailPasswordSetting
                    $pass = ConvertTo-SecureString $pass  -AsPlainText -Force 
                    $cred = 
                        New-Object Management.Automation.PSCredential ".\$un", $pass 
                    $sendMailParams += @{
                        SmtpServer = $pipeworksManifest.UserTable.SmtpServer 
                        From = $pipeworksManifest.UserTable.FromEmail
                        Credential = $cred
                        UseSsl = $true
                    }
                    

                } else {
                    $($ExecutionContext.InvokeCommand.GetCommand("Send-Email", "All"))
                    $sendMailParams += @{
                        UseWebConfiguration = $true
                        AsJob = $true
                    }
                }
                
                
                $sendMailParams += @{
                    Subject= "Welcome to $($module.Name)"
                    Body = @"
$($pipeworksManifest.UserTable.WelcomeEmailMessage)
<BR/>
Thanks for confirming,<br/>
<br/>
Your API key is: $secondaryApiKey <br/>
<br/>
"@                    
                }
                
                & $sendMailcommand @sendMailParams 
                   
                # Send-Email -UseWebConfiguration -AsJob -To $confirmationCodeFound.UserEmail -BodyAsHtml  
                
            } else {  
                # Check to see if this is confirming an update, and make the changes
                $emailFilter = [ScriptBlock]::Create("`$_.UserEmail -eq '$($confirmationCodeFound.UserEmail)'")
                $emailEditsByTime = Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -Where $emailFilter  | 
                    Sort-Object { [DateTime]$_.Timestamp } 
                
                $userProfilePartition =
                    if (-not $pipeworksManifest.UserTable.Partition) {
                        "UserProfiles"
                    } else {
                        $pipeworksManifest.UserTable.Partition
                    }
                
                $original  = $emailEditsByTime|
                    Where-Object { $_.PartitionKey -eq $userProfilePartition } |
                    Select-Object -First 1 
                    
                $update =  $emailEditsByTime|
                    Where-Object { $_.PartitionKey -ne $userProfilePartition } |
                    Select-Object -Last 1 
                
                                                    
                if ($original -and $update) {
                    $changeProperties = @($pipeworksManifest.UserTable.RequiredInfo.Keys) + @($pipeworksManifest.UserTable.OptionalInfo.Keys)
                    $toChange = $update | Select-Object -First 1 | Select-Object $changeProperties 
                    
                    foreach ($prop in $toChange.psobject.properties) {
                        $original | Add-Member NoteProperty $prop.Name $prop.Value -Force
                    }

                    
                    $original | 
                        Update-AzureTable -TableName $pipeworksManifest.UserTable.name -PartitionKey $userProfilePartition -RowKey $original.UserId -Value { $_}
                        
                    $userInfo  =
                        Get-AzureTable -TableName $pipeworksManifest.UserTable.name -PartitionKey $userProfilePartition -RowKey $original.UserId
                    $session['User']  = $userInfo
                    
                    $update |
                        Remove-AzureTable -Confirm:$false
                    
                    $ConfirmMessage = @"
<BR/>
Thanks for confirming.  The following changes have been made to your account:<br/>

$($toChange | Out-HTML)
"@
                
                
                } else {
                    $ConfirmMessage = @"
$($pipeworksManifest.UserTable.WelcomeBackMessage)
<BR/>
Thanks for re-confirming, and welcome back<br/>
"@
                }
                
                
                
                $html = New-Region -Content $confirmMessage -AsWidget -Style @{
                    'margin-left' = $MarginPercentLeftString
                    'margin-right' = $MarginPercentRightString
                    'margin-top' = '10px'   
                    'border' = '0px' 
                } |
                New-WebPage -Title "Welcome back to $($module.Name)" -RedirectTo "${finalUrl}?login=true"
                $response.Write("$html")
            }
        }
        
        
        $TextHandler = {
            # Handle text input for all commands in WebCommand
            
            
                    
        }
        
        $MeHandler = {
            $confirmPersonHtml = . Confirm-Person -WebsiteUrl $finalUrl
            if ($session -and $session["User"]) {
                $profilePage = $session["User"] | 
                    Out-HTML | 
                    New-WebPage -UseJQueryUI
                $response.Write($profilePage)
            } else {
                throw "Not Logged In"
            }
        }
        
        $settleHandler = $validateUserTable.ToString() + {
            if (-not ($session -and $session["User"])) {
                throw "Not Logged in"
            }
            
                        New-WebPage -RedirectTo "?Purchase=true&ItemName=Settle Account Balance&ItemPrice=$($session["User"].Balance)" |
                Out-html -writeresponse
        }
        

        
        $addCartHandler = {
            if (-not ($request -and $request["ItemId"] -and $request["ItemName"] -and $Request["ItemPrice"])) {
                throw "Must provide an ItemID and ItemName and ItemPrice"    
            }
            $cartCookie = $request.Cookies["$($module.Name)_CartCookie"]
            if (-not $cartCookie) {
                $CartCookie = New-Object Web.HttpCookie "$($module.Name)_CartCookie"            
            }
            $CartCookie["Item_" + $request["ItemID"]]= $request["ItemName"] + "|" + $request["ItemPrice"]
            $CartCookie["LastUpdatedOn"] = (Get-Date).ToString("r")
            $CartCookie.Expires = (Get-Date).AddMinutes(60)                    
            $response.Cookies.Add($CartCookie )            
            $response.Write("<p style='display:none'>")
            $response.Flush()
            return
        }

        $showCartHandler = {
            $cartCookie = $request.Cookies["$($module.Name)_CartCookie"]
            if (-not $cartCookie) {
                $CartCookie = New-Object Web.HttpCookie "$($module.Name)_CartCookie"            
            }
            
            
            $cartCookie.Values.GetEnumerator()  |
                Where-Object {
                    $_ -like "Item_*"
                } |
                Foreach-Object -Begin {
                    $items = @()
                    
                } {
                    $itemId = $_.Replace("Item_", "")
                    $itemName, $itemPrice = $cartCookie.Values[$_] -split "\|"       
                    
                    if (-not ($itemPrice -as [Double])) {
                        if ($itemPrice.Substring(1) -as [Double]) {
                            $itemPrice = $itemPrice.Substring(1)
                        }
                    }             
                    $items+= New-Object PSObject |
                        Add-Member NoteProperty Name $itemName -passthru | 
                        Add-Member NoteProperty Price ($itemPrice -as [Double]) -passthru 
                } -End {
                    $subtotal = $items | 
                        Measure-Object -Sum Price | 
                        Select-Object -ExpandProperty Sum
                    ($items | Out-HTML ) + 
                        "<HR/>" + 
                        ("<div style='float:right;text-align:right'><b>Subtotal:</b><br/><br/><span style='margin:5px'>$Subtotal</span></div><div style='clear:both'></div>")
                }|
                Out-HTML -WriteResponse


            if ($session -and $session["User"]) {
            
            } else {
                function Request-ContactInfo
                {
                    <#
                    .Synopsis
                    
                    .Description
                        Please let us know how to get in touch with you in case there's a problem with your order
                    .Example

                    #>
                    param(
                    # Your Name
                    [string]
                    $Name,

                    # Your email
                    [string]
                    $Email,


                    # Your Phone number
                    [string]
                    $PhoneNumber
                    )
                }

                Request-CommandInput -CommandMetaData (Get-Command Request-Contactinfo) -ButtonText "Checkout" -Action "${finalUrl}?Checkout=true" | Out-HTML -WriteResponse
                
            }
            
            return
        }


        $checkoutCartHandler = {
            
            if ($pipeworksManifest.Checkout.To -and
                $pipeworksManifest.Checkout.SmtpServer -and 
                $pipeworksManifest.Checkout.SmtpUserSetting -and 
                $pipeworksManifest.Checkout.SmtpPasswordSetting) {
                # Email based cart, send the order along

                $emailContent = $cartCookie.Values.GetEnumerator()  |
                    Where-Object {
                        $_ -like "Item_*"
                    } |
                    Foreach-Object -Begin {
                        $items = @()
                    
                    } {
                        $itemId = $_.Replace("Item_", "")
                        $itemName, $itemPrice = $cartCookie.Values[$_] -split "\|"       
                    
                        if (-not ($itemPrice -as [Double])) {
                            if ($itemPrice.Substring(1) -as [Double]) {
                                $itemPrice = $itemPrice.Substring(1)
                            }
                        }             
                        $items+= New-Object PSObject |
                            Add-Member NoteProperty Name $itemName -passthru | 
                            Add-Member NoteProperty Price ($itemPrice -as [Double]) -passthru 
                    } -End {
                        $subtotal = $items | 
                            Measure-Object -Sum Price | 
                            Select-Object -ExpandProperty Sum
                        ($items | Out-HTML ) + 
                            "<HR/>" + 
                            ("<div style='float:right;text-align:right'><b>Subtotal:</b><br/><br/><span style='margin:5px'>$Subtotal</span></div><div style='clear:both'></div>")
                    }


                $emailAddress = Get-SecureSetting -Name $pipeworksManifest.Checkout.SmtpUserSetting
                $emailPassword = Get-SecureSetting -Name $pipeworksManifest.Checkout.SmtpPasswordSetting 

                $emailCred = New-Object Management.Automation.PSCredential ".\$emailAddress", (ConvertTo-SecureString -AsPlainText -Force $emailPassword)


                $to = $pipeworksManifest.Checkout.To -split "\|"
                Send-MailMessage -SmtpServer $pipeworksManifest.Checkout.SmtpServer -From $emailAddress -UseSsl -BodyAsHtml -Body $emailContent -Subject "Order From $from" -To $to -Credential $emailCred 
            }
        }


        $AddPurchaseHandler = $validateUserTable.ToString() + {                        
            if ($request["Rent"]) {
                $isRental = $true
                $billingFrequency = $request["BillingFrequency"]
            } else {
                $isRental = $false
                $billingFrequency = ""
            }
            if (-not ($session -and $session["User"])) {
                throw "Not Logged in"
            }
            
            if (-not ($Request -and $request["ItemName"])) {
                throw "Must Provide an ItemName"
            }
            
            if (-not ($Request -and $request["ItemPrice"])) {
                throw "Must Provide an ItemPrice"
            }
            
            $currency = "USD"
            if ($request -and $request["Currency"]) {
                $currency  = $reqeust["Currency"]
            }
            
            if (-not ($Request -and $request["ItemPrice"])) {
                throw "Must Provide an ItemPrice"
            }

            $PostPaymentParameter,$postPaymentCommand = $null
            
            if ($session["PostPaymentCommand"]) {
                
                $postPaymentCommand= $session["PostPaymentCommand"]
                if ($session["PostPaymentParameter"]) {
                    try {
                        $PostPaymentParameter= $session["PostPaymentParameter"]
                    } catch {
                    }

                }
                
            }
            
                        
            $userPart = if ($pipeworksManifest.UserTable.Partition) {
                $pipeworksManifest.UserTable.Partition
            } else {
                "Users"
            }
            
            $purchaseHistory = $userPart + "_Purchases"
            
            $purchaseId = [GUID]::NewGuid()
            
            
            $purchase = New-Object PSObject
            $purchase.pstypenames.clear()
            $purchase.pstypenames.add('http://shouldbeonschema.org/ReceiptItem')
            
            
            $purchase  = $purchase |
                Add-Member NoteProperty PurchaseId $purchaseId -PassThru |
                Add-Member NoteProperty ItemName $request["ItemName"] -PassThru |
                Add-Member NoteProperty ItemPrice $request["ItemPrice"] -PassThru |
                Add-Member NoteProperty Currency $request["Currency"] -PassThru |
                Add-Member NoteProperty OrderTime $request["OrderTime"] -PassThru |
                Add-Member NoteProperty UserID $session["User"].UserID -PassThru

            if ($postPaymentCommand) {
                $purchase = $purchase |
                    Add-Member NoteProperty PostPaymentCommand $postPaymentCommand -PassThru
            }

            if ($PostPaymentParameter) {
                $purchase  = $purchase |
                    Add-Member NoteProperty PostPaymentParameter $PostPaymentParameter -PassThru
            }
            
            $azureStorageAccount = Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting
            $azureStorageKey= Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting

            $purchase | 
                Set-AzureTable -TableName $pipeworksManifest.UserTable.Name -PartitionKey $purchaseHistory -RowKey $purchaseId -StorageAccount $azureStorageAccount  -StorageKey $azureStorageKey
            
            $payLinks = ""
            $payLinks += 
                if ($pipeworksManifest.PaymentProcessing.AmazonPaymentsAccountId -and 
                    $pipeworksManifest.PaymentProcessing.AmazonAccessKey) {
                    Write-Link -ItemName $request["ItemName"] -Currency $currency -ItemPrice $request["ItemPrice"] -AmazonPaymentsAccountId $pipeworksManifest.PaymentProcessing.AmazonPaymentsAccountId -AmazonAccessKey $pipeworksManifest.PaymentProcessing.AmazonAccessKey
                }
                
            
            $payLinks += 
                if ($pipeworksManifest.PaymentProcessing.PaypalEmail) {
                    Write-Link -ItemName $request["ItemName"] -Currency $currency -ItemPrice $request["ItemPrice"] -PaypalEmail $pipeworksManifest.PaymentProcessing.PaypalEmail -PaypalIPN "${FinalUrl}?-PaypalIPN" -PaypalCustom $purchaseId -Subscribe:$isRental
                }
                
            $paypage = $payLinks | 
                New-WebPage -Title "Buy $($Request["ItemName"]) for $($Request["ItemPrice"])"  
                
            $paypage|
                Out-html -writeresponse

            if ($PipeworksManifest.Mail.SmtpServer -and
                $pipeworksManifest.Mail.SmtpUserSetting -and
                $pipeworksManifest.Mail.SmtpPasswordSetting -and
                $pipeworksManifest.Mail.From) {
                $smtpServer = $pipeworksManifest.Mail.SmtpServer
                $smtpUser = Get-WebConfigurationSetting -Setting $pipeworksManifest.Mail.SmtpUserSetting
                $smtpPassword =  Get-WebConfigurationSetting -Setting $pipeworksManifest.Mail.SmtpPasswordSetting

                $smtpCred = New-Object Management.Automation.PSCredential ".\$smtpUser",
                    (ConvertTo-SecureString -String $smtpPassword -AsPlainText -Force)

                Send-MailMessage -UseSsl -SmtpServer $smtpServer -Subject $Request["ItemName"] -Body $payPage -BodyAsHtml -Credential $smtpCred 
            }
            
        }
        
        
        
        $payPalIpnHandler =  $validateUserTable.ToString() + {
            
            $error.Clear()

            $userPart = 
                if ($pipeworksManifest.UserTable.Partition) {
                    $pipeworksManifest.UserTable.Partition
                } else {
                    "Users"
                }
            
            $purchaseHistory = $userPart + "_Purchases"                        
            $req = [Net.HttpWebRequest]::Create("https://www.paypal.com/cgi-bin/webscr") 
            # //Set values for the request back
            $req.Method = "POST";
            $req.ContentType = "application/x-www-form-urlencoded"
            
            $strRequest = $request.Form.ToString() + 
                "&cmd=_notify-validate";
            $req.ContentLength = $strRequest.Length;
 
            $parsed = [Web.HttpUtility]::ParseQueryString($strRequest)

            $streamOut = New-Object IO.StreamWriter $req.GetRequestStream()
            $streamOut.Write($strRequest);
            $streamOut.Close();
            $streamIn = New-Object IO.StreamReader($req.GetResponse().GetResponseStream());
            $strResponse = $streamIn.ReadToEnd();
            $streamIn.Close();
 
            $azureStorageAccount = Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageAccountSetting
            $azureStorageKey= Get-WebConfigurationSetting -Setting $pipeworksManifest.UserTable.StorageKeySetting
            
            
            $custom = $Request["Custom"]
            $ipnResponse = $strResponse

            $ipn = 
                New-Object PSObject -Property @{
                    Custom = "$custom"
                    Request = $strRequest 
                    IPNResponse = $ipnResponse
                    UserPart = $purchaseHistory 
                } 
            $ipn |
                Set-AzureTable -TableName $pipeworksManifest.UserTable.Name -RowKey { [GUID]::NewGuid() } -PartitionKey "PaypalIPN" -StorageAccount $azureStorageAccount -StorageKey $azureStorageKey
                

            if ($ipnResponse -eq "VERIFIED")
            {
            <#    //check the payment_status is Completed
                //check that txn_id has not been previously processed
                //check that receiver_email is your Primary PayPal email
                //check that payment_amount/payment_currency are correct
                //process payment
            #>                
                
                
                
                $filterString = "PartitionKey eq '$purchaseHistory' and RowKey eq '$($ipn.Custom)'" 
                $transactionExists = Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -Filter $filterString
                
                if ($transactionExists) {
                    # Alter the user balance 
                    
                    if ($transactionExists.Processed -like "True*") {
                        # already processed, skip
                        New-Object PSObject -Property @{
                            Custom = "$custom"
                            SkippingProcessedTransaction=$true                        
                            
                        } |
                            Set-AzureTable -TableName $pipeworksManifest.UserTable.Name -RowKey { [GUID]::NewGuid() } -PartitionKey "PaypalIPN"

                        return
                    }

                    $result = " " 
                    if ($request["Payment_Status"] -ne "Completed") {
                        New-Object PSObject -Property @{
                            Custom = $custom                        
                            TransactionIncomplete = $request["Payment_Status"]
                        } |
                            Set-AzureTable -TableName $pipeworksManifest.UserTable.Name -RowKey { [GUID]::NewGuid() } -PartitionKey "PaypalIPN"
                    } else {
                        $userInfo =
                            Search-AzureTable -TableName $pipeworksManifest.UserTable.Name -Filter "PartitionKey eq '$userPart' and RowKey eq '$($transactionExists.UserID)'"
                        
                        $balance = $userInfo.Balance -as [Double]                    
                        $balance -= $request["payment_gross"] -as [Double]
                        $userInfo |
                            Add-Member NoteProperty Balance $balance -Force -PassThru | 
                            Update-AzureTable -TableName $pipeworksManifest.UserTable.Name -Value { $_ } 
                        
                        $session["User"] = $userInfo

                        if ($transactionExists.postPaymentCommand) {
                            $postPaymentCommand = Get-Command -Module $module.Name -Name "$($transactionExists.postPaymentCommand)".Trim()
                            $PostPaymentParameter = if ($transactionExists.postPaymentParameter) {
                                invoke-expression "data { $($transactionExists.postPaymentParameter) }"
                            } else {
                                @{}
                            }

                            $extra = if ($pipeworksManifest.WebCommand."$($transactionExists.postPaymentCommand)".Trim()) {
                                $pipeworksManifest.WebCommand."$($transactionExists.postPaymentCommand)".Trim()
                            } else {
                                @{}
                            }

                            if ($extra.RunWithoutInput) {
                                $null = $extra.Remove("RunWithoutInput")                                
                            }

                            if ($extra.ParameterDefaultValue) {
                                try {
                                    $postPaymentParameter += $extra.ParameterDefaultValue
                                } catch {
                                }
                                $null = $extra.Remove("ParameterDefaultValue")                                
                            }


                            if ($extra.RequireAppKey -or 
                                $extra.RequireLogin -or 
                                $extra.IfLoggedAs -or 
                                $extra.ValidUserPartition -or 
                                $extra.Cost -or 
                                $extra.CostFactor) {

                                $extra.UserTable = $pipeworksManifest.Usertable.Name
                                $extra.UserPartition = $pipeworksManifest.Usertable.Partition
                                $extra.StorageAccountSetting = $pipeworksManifest.Usertable.StorageAccountSetting
                                $extra.StorageKeySetting = $pipeworksManifest.Usertable.StorageKeySetting 

                            }

                            
                            $result = Invoke-WebCommand @extra -RunWithoutInput -PaymentProcessed -Command $postPaymentCommand -ParameterDefaultValue $PostPaymentParameter -AsEmail $userInfo.UserEmail  2>&1
                            
                        }

                        $transactionExists |
                            Add-Member NoteProperty Processed $true -Force -PassThru |
                            Add-Member NoteProperty CommandResult ($result | Out-Html) -force -passthru | 
                            Add-Member NoteProperty PayPalIpnID $request['Transacation_Subject'] -Force -PassThru |
                            Update-AzureTable -TableName $pipeworksManifest.UserTable.Name -Value { $_ } 


                        $smtpServer = $pipeworksManifest.UserTable.SmtpServer
                        if ($smtpServer) {

                        }        
                    }
                    
                    
                    
                    
                } else {
                    New-Object PSObject -Property @{
                        Custom = $custom
                        Errors = "$($error | Select-Object -First 1 | Out-String)"
                        TransactionNotFound = $true
                        Filter = $filterString 
                    } |
                        Set-AzureTable -TableName $pipeworksManifest.UserTable.Name -RowKey { [GUID]::NewGuid() } -PartitionKey "PaypalIPN"
                }
            } elseif ($strResponse -eq "INVALID") {
                # //log for manual investigation
                $strResponse
            } else {
                # //log response/ipn data for manual investigation
                
            }
        }
        
        
        $facebookConfirmUser = {
            
            
            if (-not ($pipeworksManifest.Facebook.AppId -or $pipeworksManifest.Facebook.AppIdSetting)) {
                throw 'The Pipeworks manifest must include a facebook section with an AppId or AppIdSetting'
                return
            }
            
            
            
            $fbAppId = $pipeworksManifest.Facebook.AppId
            
            if (-not $fbAppId) {
                $fbAppId= Get-WebConfigurationSetting -Setting $pipeworksManifest.Facebook.AppIdSetting
            }
            
            if (-not $fbAppId) {
                throw "No Facebook AppID found"
                return
            }
            
            
            if ($request.Params["accesstoken"]) {
                $accessToken = $request.Params["accesstoken"]
                . Confirm-Person -FacebookAccessToken $accessToken -FacebookAppId $fbAppId -WebsiteUrl $finalUrl
            } elseif ($request.Params["code"]) {
                $code = $request.Params["code"]

                $fbSecret = Get-WebConfigurationSetting -Setting $pipeworksManifest.Facebook.AppSecretSetting

                $result =Get-Web -url "https://graph.facebook.com/oauth/access_token?client_id=$fbAppId&redirect_uri=$([Web.HttpUtility]::UrlEncode("${finalUrl}?FacebookConfirmed=true"))&client_secret=$fbsecret&code=$code"

                $token = [web.httputility]::ParseQueryString($result)["access_token"]                

                . Confirm-Person -FacebookAccessToken $Token -FacebookAppId $fbAppId -WebsiteUrl $finalUrl
            }

            
            
            
            if ($request.Params["ReturnTo"]) {
                $returnUrl = [Web.HttpUtility]::UrlDecode($request.Params["ReturnTo"])
                New-WebPage -AnalyticsId "" -title "Welcome to $($module.Name)" -RedirectTo $returnUrl |
                    Out-HTML -WriteResponse
            } elseif ($Request.Params["ThenRun"]) { 
                . $getCommandExtraInfo $Request.Params["ThenRun"]

                $result = 
                    Invoke-Webcommand -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1
            } else {
                New-WebPage -AnalyticsId "" -title "Welcome to $($module.Name)" -RedirectTo "/" |
                    Out-HTML -WriteResponse
            }                         
        }
        
        
        $liveIdConfirmUser = {
            if ($request.Params["accesstoken"]) {
                $accessToken = $request.Params["accesstoken"]
                . Confirm-Person -liveIDAccessToken $accessToken -WebsiteUrl $finalUrl
            } elseif ($request.Params["code"]) {
                $code = $request.Params["code"]

                $appId = $pipeworksManifest.LiveConnect.ClientId
                $appSecret = Get-WebConfigurationSetting -Setting $pipeworksManifest.LiveConnect.ClientSecretSetting

                $redirectUri = $session["LiveIDRedirectURL"]
                $result =Get-Web -url "https://login.live.com/oauth20_token.srf" -RequestBody "client_id=$([Web.HttpUtility]::UrlEncode($appId))&redirect_uri=$([Web.HttpUtility]::UrlEncode($redirectUri))&client_secret=$([Web.HttpUtility]::UrlEncode($appSecret.Trim()))&code=$([Web.HttpUtility]::UrlEncode($code.Trim()))&grant_type=authorization_code" -UseWebRequest -Method POST -AsJson

                
                    $token = $result.access_token
                if (-not $Token) {
                    New-Object PSObject -Property @{
                        Code = $code
                        #Secret = $appSecret
                        AppId = $appId
                        RedirectUrl = $redirectUri
                    } | Out-HTML
                } else {
                    . Confirm-Person -LiveIDAccessToken $token -WebsiteUrl $finalUrl 
                }
            }


            if ($session["User"]) {
                if ($request.Params["ReturnTo"]) {
                    $returnUrl = [Web.HttpUtility]::UrlDecode($request.Params["ReturnTo"])
                    New-WebPage -AnalyticsId "" -title "Welcome to $($module.Name)" -RedirectTo $returnUrl |
                        Out-HTML -WriteResponse
                } elseif ($Request.Params["ThenRun"]) { 
                    . $getCommandExtraInfo $Request.Params["ThenRun"]

                    $result = 
                        Invoke-Webcommand -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1

                    if ($result) {
                        $result |
                            New-WebPage -UseJQueryUI 
                    }
                } else {
                    New-WebPage -AnalyticsId "" -title "Welcome to $($module.Name)" -RedirectTo "/" |
                        Out-HTML -WriteResponse
                }
            }

            
        }             
        
        
        #region Facebook Login Chunk
        $facebookLoginDisplay = {
            if (-not ($pipeworksManifest.Facebook.AppId -or $pipeworksManifest.Facebook.AppIdSetting)) {
                throw 'The Pipeworks manifest must include a facebook section with an AppId or AppIdSetting'
                return
            }
            
            
            
            $fbAppId = $pipeworksManifest.Facebook.AppId
            
            if (-not $fbAppId) {
                $fbAppId= Get-WebConfigurationSetting -Setting $pipeworksManifest.Facebook.AppIdSetting
            }
            
            if (-not $fbAppId) {
                throw "No Facebook AppID found"
                return
            }
            
            #if (-not $pipew
            $scope = if ($pipeworksManifest -and $pipeworksManifest.Facebook.Scope) {
                @($pipeworksManifest.Facebook.Scope) + "email" | 
                    Select-Object -Unique
            } else {
                "email"
            }
            
            
            $response.Write(("$(Write-Link -ToFacebookLogin -FacebookAppId $fbAppId -FacebookLoginScope $scope |
    New-WebPage -Title "Login with Facebook")"))
            
                       
        }        
        #endregion                
        
        #region MailHandler
        $mailHandler = {
            $to = $request["To"]
            $from = $Request["From"]
            $replyTo = $request["Replyto"]
            $body = $Request["Body"]
            $subject= $Request["Subject"]
            $useSsl = -not $pipeworksManifest.Mail.DoNotUseSsl
            $smtpServer = $pipeworksManifest.Mail.SmtpServer
            $smtpUser = Get-WebConfigurationSetting -Setting $pipeworksManifest.Mail.SmtpUserSetting
            $smtpPassword =  Get-WebConfigurationSetting -Setting $pipeworksManifest.Mail.SmtpPasswordSetting
            
            if (-not $pipeworksManifest.Mail.CanSendTo) {
                throw "Must add a CanSendTo list to the mail section" 
                
            }
            
            $canSend = $false
            foreach ($couldSendTo in $pipeworksManifest.Mail.CanSendTo) {
                if ($to -like $couldSendto) {
                    $canSend = $true
                }
                
            }
            
            if (-not $canSend) {
                throw "Cannot send mail to $to"
            }
            
            $smtpCred = New-Object Management.Automation.PSCredential ".\$smtpUser",
                (ConvertTo-SecureString -String $smtpPassword -AsPlainText -Force)
                
            $emailParams = @{
                From=$from
                To=$To
                Body=$body+"
----
Reply To:$replyTo 
"                 
                             
                Subject=$subject
                UseSsl=$useSsl
                SmtpServer=$smtpServer
                Credential=$smtpCred            
            }
            Send-MailMessage @emailParams
            
            
            $redirectto = $Request["RedirectTo"]
            if ($redirectTo){
                New-WebPage -RedirectTo $redirectTo | Out-HTML -WriteResponse
            }
        }
        #endregion MailHandler
        
        $tableItemProcess = {
            $BeginTableItem = {
                $itemsToShow = @()
            }
            $endTableItem = {
                $itemsToShow | Out-HTML -WriteResponse
            } 
            
            $ProcessEachTableItem = {
                # If there's a content type, set the response's content type to match                
                
                if ($_.RequireSessionHandShake -and 
                    -not $session[$_.RequireSessionHandShake]) {
                    throw "Required Session Handshake is not present $($_.RequireSessionHandShake)"
                    return
                }
                
                if ($_.ExpirationDate -and (
                    [DateTime]::Now -gt $_.ExpirationDate)) {
                    throw "Content is Expired"
                    return
                }
                
                # Unpack any properties on the item without spaces (or try)
                . $unpackItem
                
                if ($Request['LinkOnly']) {
                    $item = Write-Link -Caption Name -Url $item.Url
                }
                if ($_.ContentType) {
                    $response.ContentType = 'ContentType'
                }
                if ($_.Bytes) {                    
                    $response.BufferOutput = $true
                    $response.BinaryWrite([Convert]::FromBase64String($_.Bytes))
                    $response.Flush()                        
                } elseif ($_.Xml) {
                    $strWrite = New-Object IO.StringWriter
                    ([xml]($_.Xml)).Save($strWrite)
                    $resultToOutput  = "$strWrite" -replace "encoding=`"utf-16`"", "encoding=`"utf-8`""
                    if (-not $cmdOptions.ContentType) {
                        $response.ContentType ="text/xml"
                    }
                    $response.Write("$resultToOutput")    
                } elseif ($_.Html) {                    
                    $itemsToShow += $_.Html
                } else {
                    $itemsToShow += $_                    
                }                                                
                
                if ($_.TimesViewed) {
                    $timesViewed = [int]$_.TimesViewed + 1
                    $putItBack = $_
                    $rowKey = $_.psobject.properties['RowKey']
                    $_.psobject.properties.Remove('RowKey')
                    $partitionKey = $_.psobject.properties['PartitionKey']                    
                    $_.psobject.properties.Remove('PartitionKey')
                    $tableName= $_.psobject.properties['TableName']
                    $_.psobject.properties.Remove('TableName')
                    $putItBack | Add-Member NoteProperty TimesViewed $timesViewed -Force
                    $putItBack | Update-AzureTable -TableName $tableName -PartitionKey $partitionKey -RowKey $rowKey
                }
            }
        }
        
        
        #region SearchHandler                        
        $SearchHandler = $embedUnpackItem + $tableItemProcess.ToString() + {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)
            
            $lastSearchTime = $application["KeywordSearchTime_$($request['Search'])"]
            $lastResults = $application["SearchResults_$($request['Search'])"]
            
            # If the PipeworksManifest is going to index table data, then load this up rather than query                        
            if ($pipeworksManifest.Table.IndexBy) {
                if (-not $pipeworksManifest.Table.SqlAzureConnectionSetting) {
                    Write-Error "Modules that index tables must also declare a SqlAzureConnectionString within the table"
                    return
                }
                            
                $connectionString = Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.SqlAzureConnectionSetting
                $sqlConnection = New-Object Data.SqlClient.SqlConnection "$connectionString"
                $sqlConnection.Open()
                
                $matchSql = @(foreach ($indexTerm in $pipeworksManifest.Table.IndexBy) {
                    "$indexTerm like '%$($request['search'].Replace("'","''"))%'" 
                }) -join ' or ' 
                                                
                $searchSql = "select id from $($pipeworksManifest.Table.Name) where $matchSql"
                
                
                $sqlAdapter= new-object "Data.SqlClient.SqlDataAdapter" ($searchSql, $sqlConnection)
                $sqlAdapter.SelectCommand.CommandTimeout = 0
                $dataSet = New-Object Data.DataSet 
                $null = $sqlAdapter.Fill($dataSet)
                $allIds = @($dataSet.Tables | Select-Object -ExpandProperty Rows | Select-Object -ExpandProperty Id)
                foreach ($id in $allIds) {
                    if (-not $id) { 
                        continue 
                    } 
                    $part,$row = $id -split ":"
                    
                    Get-AzureTable -TableName $pipeworksManifest.Table.Name -Row $row.Trim() -Partition $part.Trim() -StorageAccount $storageAccount -StorageKey $storageKey| 
                        ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
                }
                
            
            } else {
                Search-AzureTable -TableName $pipeworksManifest.Table.Name -Select Name, Description, Keyword, PartitionKey, RowKey -StorageAccount $storageAccount -StorageKey $storageKey |
                ForEach-Object $UnpackItem |
                Where-Object {                    
                    ($_.Name -ilike "*$($request['Search'])*") -or
                    ($_.Description -ilike "*$($request['Search'])*") -or
                    ($_.Keyword -ilike "*$($request['Search'])*") -or
                    ($_.Keywords -ilike "*$($request['Search'])*")                                      
                } |
                
                Get-AzureTable -TableName $pipeworksManifest.Table.Name | 
                    ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
                
            }
            
            if (-not $lastResults) {                      
                if (-not $application['TableIndex'] -or (-not $pipeworksManifest.Table.IndexBy)) {
                    # If theres' not an index, or the manifest does not build one, search the table
                    $application['TableIndex'] = 
                        Search-AzureTable -TableName $pipeworksManifest.Table.Name -Select Name, Description, Keyword, PartitionKey, RowKey -StorageAccount $storageAccount -StorageKey $storageKey
                }
                                                                
            } else {
                $lastResults | 
                    ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
            }
        }
        #endregion
        
        #region NameHandler
        $nameHandler = $tableItemProcess.ToString() + $embedUnpackItem + {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)
            $nameMatch  =([ScriptBLock]::Create("`$_.Name -eq '$($request['name'])'"))
            Search-AzureTable -Where $nameMatch -TableName $pipeworksManifest.Table.Name -StorageAccount $storageAccount -StorageKey $storageKey | 
                ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
        }
        #endregion
        
               
        #region LatestHandler
        $latestHandler = $tableItemProcess.ToString() + $embedUnpackItem +  {
            $PartitionKey = $request['Latest']
        } + $refreshLatest + {
            $latest |                 
                ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
        } 
        #endregion LatestHandler 
        
        #region RssHandler
        $rssHandler = $embedUnpackItem + {
            $PartitionKey = $request['Rss']
        } + $refreshLatest.ToString() + {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)            
            $finalSite = $finalUrl.ToString().Substring(0,$finalUrl.ToString().LastIndexOf("/"))

            $blogName = 
                if ($pipeworksManifest.Blog.Name) {
                    $pipeworksManifest.Blog.Name
                } else {
                    $module.Name
                }
                
            $blogDescription = 
                if ($pipeworksManifest.Blog.Description) {
                    $pipeworksManifest.Blog.Description
                } else {
                    $module.Description
                }
                
            $syncTime = [Datetime]::Now - [Timespan]"0:20:0"
            if (-not ($session["RssFeed$($blogName)LastSyncTime"] -ge $syncTime)) {
                $session["RssFeed$($blogName)"] = $null
            }
           

            if (-not $session["RssFeed$($blogName)"]) {
            
                $feedlength = if ($pipeworksManifest.Blog.FeedLength -as [int]) {
                    $pipeworksManifest.Blog.FeedLength -as [int]
                } else {
                    25
                }
                
                if ($feedLength -eq -1 ) { $feedLength = [int]::Max } 
                
                $getDateScript = {
                    if ($_.DatePublished) {
                        [DateTime]$_.DatePublished
                    } elseif ($_.TimeCreated) {
                        [DateTime]$_.TimeCreated
                    } elseif ($_.TimeGenerated) {
                        [DateTime]$_.TimeGenerated
                    } elseif ($_.Timestamp) {
                        [DateTime]$_.Timestamp
                    } else {
                        Get-Date
                    }
                }
                
                $rssFeed = 
                    Search-AzureTable -TableName $pipeworksManifest.Table.Name -Filter "PartitionKey eq '$PartitionKey'" -Select Timestamp, DatePublished, PartitionKey, RowKey -StorageAccount $storageAccount -StorageKey $storageKey |
                    Sort-Object $getDateScript -Descending  |
                    Select-Object -First $feedlength | 
                    Get-AzureTable -TableName $pipeworksManifest.Table.Name |
                    ForEach-Object $UnpackItem |
                    New-RssItem -Title  {
                        if ($_.Name) {                    
                            $_.Name
                        } else {
                            ' '
                        }
                    } -DatePublished $getDateScript -Author { 
                        if ($_.Author) { $_.Author} else { ' '  } 
                    } -Url {
                        if ($_.Url) {
                            $_.Url
                        } else {
                            "$($finalSite.TrimEnd('/') + '/')?post=$($_.Name)"
                        }
                    } |                 
                    Out-RssFeed -Title $blogName -Description $blogDescription -ErrorAction SilentlyContinue -Link $finalSite                 
                $session["RssFeed$($blogName)"] = $rssFeed
                $session["RssFeed$($blogName)LastSyncTime"]  = Get-Date
            } else {
                $rssFeed = $session["RssFeed$($blogName)"]
            }
            
            $response.ContentType = 'text/xml'
            $response.Write($rssFeed)
        }
        #endregion RssHandler
        
        #region TypeHandler
        $typeHandler = $tableItemProcess.ToString() + $embedUnpackItem +{
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)
            $nameMatch  =([ScriptBLock]::Create("`$_.psTypeName -eq '$($request['Type'])'"))
            Search-AzureTable -Where $nameMatch -TableName $pipeworksManifest.Table.Name -StorageAccount $storageAccount -StorageKey $storageKey | 
                ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
        }
        #endregion TypeHandler
                
        


        #region IdHandler
        $idHandler = $tableItemProcess.ToString() + $embedUnpackItem + {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            
            $partition, $row = $request['id'] -split ':'       
                             
            <#$rowMatch= [ScriptBLock]::Create("`$_.RowKey -eq '$row'")
            $partitionMatch = [ScriptBLock]::Create("`$_.PartitionKey -eq '$partition'")
            #>
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)
            Search-AzureTable -TableName $pipeworksManifest.Table.Name -StorageAccount $storageAccount -StorageKey $storageKey -Filter "RowKey eq '$row' and PartitionKey eq '$partition'" |
                ForEach-Object -Begin $BeginTableItem -Process $ProcessEachTableItem -End $EndTableItem
            
             
            
        }
        #endregion              

                
        #region PrivacyPolicyHandler

        $privacyPolicyHandler = {
$siteUrl = $finalUrl.ToString().Substring(0, $finalUrl.LastIndexOf("/")) + "/"
$OrgInfo = if ($module.CompanyName) {
    $module.CompanyName
} elseif ($pipeworksManifest.Organization.Name) {
    $pipeworksManifest.Organization.Name
} else {
    " THE COMPANY"
}

$policy = if ($pipeworksManifest.PrivacyPolicy) {
    $pipeworksManifest.PrivacyPolicy    
} else {

@"
<!-- START PRIVACY POLICY CODE -->
<div style="font-family:arial">
  <strong>What information do we collect?</strong>
  <br />
  <br />
We ( $OrgInfo ) collect information from you when you register on our site ( $siteUrl ) or place an order.  <br /><br />
When ordering or registering on our site, as appropriate, you may be asked to enter your: name, e-mail address or phone number. You may, however, visit our site anonymously.<br /><br />
Google, as a third party vendor, uses cookies to serve ads on your site.
Google's use of the DART cookie enables it to serve ads to your users based on their visit to your sites and other sites on the Internet.
Users may opt out of the use of the DART cookie by visiting the Google ad and content network privacy policy..<br /><br /><strong>What do we use your information for?</strong><br /><br />
Any of the information we collect from you may be used in one of the following ways: <br /><br />
<br/>
 To personalize your experience<br />
(your information helps us to better respond to your individual needs)<br /><br />
<br/>
To improve our website<br />
(we continually strive to improve our website offerings based on the information and feedback we receive from you)<br /><br />
<br/>
To improve customer service<br />
(your information helps us to more effectively respond to your customer service requests and support needs)<br /><br />
<br/>
To process transactions<br /><blockquote>Your information, whether public or private, will not be sold, exchanged, transferred, or given to any other company for any reason whatsoever, without your consent, other than for the express purpose of delivering the purchased product or service requested.</blockquote><br />
<br/>To send periodic emails<br /><blockquote>The email address you provide for order processing, may be used to send you information and updates pertaining to your order, in addition to receiving occasional company news, updates, related product or service information, etc.</blockquote><br /><br /><strong>How do we protect your information?</strong><br /><br />
We offer the use of a secure server. All supplied sensitive/credit information is transmitted via Secure Socket Layer (SSL) technology and then encrypted into our Payment gateway providers database only to be accessible by those authorized with special access rights to such systems, and are required to?keep the information confidential.<br /><br />
After a transaction, your private information (credit cards, social security numbers, financials, etc.) will not be stored on our servers.<br /><br /><strong>Do we use cookies?</strong><br /><br />
Yes (Cookies are small files that a site or its service provider transfers to your computers hard drive through your Web browser (if you allow) that enables the sites or service providers systems to recognize your browser and capture and remember certain information<br /><br />
 We use cookies to help us remember and process the items in your shopping cart, understand and save your preferences for future visits and keep track of advertisements and .<br /><br /><strong>Do we disclose any information to outside parties?</strong><br /><br />
We do not sell, trade, or otherwise transfer to outside parties your personally identifiable information. This does not include trusted third parties who assist us in operating our website, conducting our business, or servicing you, so long as those parties agree to keep this information confidential. We may also release your information when we believe release is appropriate to comply with the law, enforce our site policies, or protect ours or others rights, property, or safety. However, non-personally identifiable visitor information may be provided to other parties for marketing, advertising, or other uses.<br /><br /><strong>Third party links</strong><br /><br />
 Occasionally, at our discretion, we may include or offer third party products or services on our website. These third party sites have separate and independent privacy policies. We therefore have no responsibility or liability for the content and activities of these linked sites. Nonetheless, we seek to protect the integrity of our site and welcome any feedback about these sites.<br /><br /><strong>California Online Privacy Protection Act Compliance</strong><br /><br />
Because we value your privacy we have taken the necessary precautions to be in compliance with the California Online Privacy Protection Act. We therefore will not distribute your personal information to outside parties without your consent.<br /><br /><strong>Online Privacy Policy Only</strong><br /><br />
This online privacy policy applies only to information collected through our website and not to information collected offline.<br /><br /><strong>Your Consent</strong><br /><br />
By using our site, you consent to our web site privacy policy.<br /><br /><strong>Changes to our Privacy Policy</strong><br /><br />
If we decide to change our privacy policy, we will post those changes on this page.


Hope this Helps,

$OrgInfo
"@        
}

            $response.Write("$policy")    
            return
        }
        #endregion 

        #region Anything Handler
        $anythingHandler = $tableItemProcess.ToString() + $embedUnpackItem + {        
            
            
            # Determine the Relative Path, Full URL, and Depth
                        
            # First, parse and chunk the full path, so we can see what to do with it
            if ($request -and 
                $request.Params -and 
                $request.Params["HTTP_X_ORIGINAL_URL"]) {
                
                
                $originalUrl = $context.Request.ServerVariables["HTTP_X_ORIGINAL_URL"]
                $urlString = $request.Url.ToString().TrimEnd("/")
                $pathInfoUrl = $urlString.Substring(0, 
                    $urlString.LastIndexOf("/"))
                                                                
                $protocol = ($request['Server_Protocol'].Split("/", 
                    [StringSplitOptions]"RemoveEmptyEntries"))[0] 
                $serverName= $request['Server_Name']                     
                
                $port=  $request.Url.Port
                if (($Protocol -eq 'http' -and $port -eq 80) -or
                    ($Protocol -eq 'https' -and $port -eq 443)) {
                    $fullOriginalUrl = $protocol+ "://" + $serverName + $originalUrl 
                } else {
                    $fullOriginalUrl = $protocol+ "://" + $serverName + ':' + $port + $originalUrl 
                }
                                                                
                $rindex = $fullOriginalUrl.IndexOf($pathInfoUrl, [StringComparison]"InvariantCultureIgnoreCase")
                $relativeUrl = $fullOriginalUrl.Substring(($rindex + $pathInfoUrl.Length))
                if ($relativeUrl -like "*/*") {
                    $depth = @($relativeUrl -split "/" -ne "").Count - 1                    
                    if ($fullOriginalUrl.EndsWith("/")) { 
                        $depth++
                    }                                        
                } else {
                    $depth  = 0
                }
                
            }   
                                
                                


            # Create a Social Row (Facebook Likes, Google +1, Twitter)
            $socialRow = "
                <div style='padding:20px'>
            "

            if (-not $antiSocial) {
                if ($pipeworksManifest -and $pipeworksManifest.Facebook.AppId) {
                    $socialRow +=  
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "facebook:like" ) + 
                        "</span>"
                }
                if ($pipeworksManifest -and ($pipeworksManifest.GoogleSiteVerification -or $pipeworksManifest.AddPlusOne)) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "google:plusone" ) +
                        "</span>"
                }
                if ($pipeworksManifest -and $pipeworksManifest.ShowTweet) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:tweet" ) +
                        "</span>"
                } elseif ($pipeworksManifest -and ($pipeworksManifest.TwitterId)) {
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:tweet" ) +
                        "</span>"
                    $socialRow += 
                        "<span style='padding:5px;width:10%'>" +
                        (Write-Link "twitter:follow@$($pipeworksManifest.TwitterId.TrimStart('@'))" ) +
                        "</span>"
                }
            }
                     
            $socialRow  += "</div>"        
            $socialRow = ($socialRow  |
                New-Region -LayerID 'SocialRow' -Style @{
                    "Float" = "Right"        
                })


            $relativeUrlParts = @($relativeUrl.Split("/", [StringSplitOptions]"RemoveEmptyEntries"))

            $titleArea = 
                if ($PipeworksManifest -and $pipeworksManifest.Logo) {
                    "<a href='$FinalUrl'><img src='$($pipeworksManifest.Logo)' style='border:0' /></a>"
                } else {
                    "<a href='$FinalUrl'>" + $Module.Name + "</a>"
                }

            $TitleAlignment = if ($pipeworksManifest.Alignment) {
                $pipeworksManifest.Alignment
            } else {
                'center'
            }
            $titleArea = "<div style='text-align:$TitleAlignment'><h1 style='text-align:$TitleAlignment'>$titleArea</h1></div>"

            
             

            $descriptionArea = 
"<h2 style='text-align:$TitleAlignment' >
            $($module.Description -ireplace "`n", "<br/>")
            </h2>
            <br/>"    


            if ($relativeUrlParts.Count -ge 1) {
                # If it's a command, invoke the command
                $found = $false
                $part = $RelativeUrlParts[0]
                if ($module.ExportedFunctions.$part -or 
                    $module.ExportedAliases.$part -or 
                    $module.ExportedCmdlets.$part) {
                    
                    $found = $true
                    if ($module.ExportedAliases.$part) {
                        $command = $module.ExportedAliases.$part
                    } elseif ($module.ExportedFunctions.$part) {
                        $command = $module.ExportedFunctions.$part
                    } elseif ($module.ExportedCmdlets.$part) {
                        $command = $module.ExportedCmdlets.$part
                    }
                    
                    if ($command.ResolvedCommand) {
                        $command = $command.ResolvedCommand
                    }
                    
                        
                    $commandDescription  = ""                        
                    $commandHelp = Get-Help $command -ErrorAction SilentlyContinue | Select-Object -First 1 
                    if ($commandHelp.Description) {
                        $commandDescription = $commandHelp.Description[0].text
                        $commandDescription = $commandDescription -replace "`n", ([Environment]::NewLine) 
                    }
                    
                    $descriptionArea = "<h2 style='text-align:$TitleAlignment' >
            <div style='margin-left:30px;margin-top:15px;margin-bottom:15px'>
            $(ConvertFrom-Markdown -Markdown "$commandDescription ")
            </div>
            </h2>
            <br/>"
                    $extraParams = if ($pipeworksManifest -and $pipeworksManifest.WebCommand.($Command.Name)) {                
                        $pipeworksManifest.WebCommand.($Command.Name)
                    } elseif ($pipeworksManifest -and $pipeworksManifest.WebAlias.($Command.Name) -and
                        $pipeworksManifest.WebCommand.($pipeworksManifest.WebAlias.($Command.Name).Command)) { 
                
                        $webAlias = $pipeworksManifest.WebAlias.($Command.Name)
                        $paramBase = $pipeworksManifest.WebCommand.($pipeworksManifest.WebAlias.($Command.Name).Command)
                        foreach ($kv in $webAlias.GetEnumerator()) {
                            if (-not $kv) { continue }
                            if ($kv.Key -eq 'Command') { continue }
                            $paramBase[$kv.Key] = $kv.Value
                        }

                        $paramBase
                    } else { @{
                        ShowHelp = $true
                    } }             
                    
                    if ($pipeworksManifest -and $pipeworksManifest.Style -and (-not $extraParams.Style)) {
                        $extraParams.Style = $pipeworksManifest.Style 
                    }
                    if ($extraParams.Count -gt 1) {
                        # Very explicitly make sure it's there, and not explicitly false
                        if (-not $extra.RunOnline -or 
                            $extraParams.Contains("RunOnline") -and $extaParams.RunOnline -ne $false) {
                            $extraParams.RunOnline = $true                     
                        }                
                    } 
                    
                    if ($extaParams.PipeInto) {
                        $extaParams.RunInSandbox = $true
                    }
                    
                    if (-not $extraParams.AllowDownload) {
                        $extraParams.AllowDownload = $allowDownload
                    }
                    
                    if ($extraParams.RunOnline) {
                        # Commands that can be run online
                        $webCmds += $command.Name
                    }
                    
                    if ($extraParams.RequireAppKey -or 
                        $extraParams.RequireLogin -or 
                        $extraParams.IfLoggedAs -or 
                        $extraParams.ValidUserPartition -or 
                        $extraParams.Cost -or 
                        $extraParams.CostFactor) {

                        $extraParams.UserTable = $pipeworksManifest.UserTable.Name
                        $extraParams.UserPartition = $pipeworksManifest.UserTable.Partition
                        $extraParams.StorageAccountSetting = $pipeworksManifest.Usertable.StorageAccountSetting
                        $extraParams.StorageKeySetting = $pipeworksManifest.Usertable.StorageKeySetting 

                    }
                    
                    if ($extraParams.AllowDownload) {
                        # Downloadable Commands
                        $downloadableCommands += $command.Name                
                    }
                                
                    
                    
                    
                    
                    if ($MarginPercentLeftString -and (-not $extraParams.MarginPercentLeft)) {
                        $extraParams.MarginPercentLeft = $MarginPercentLeftString.TrimEnd("%")
                    }
                    
                    if ($MarginPercentRightString-and -not $extraParams.MarginPercentRight) {
                        $extraParams.MarginPercentRight = $MarginPercentRightString.TrimEnd("%")
                    }
                                            
        
                    if ($relativeUrlParts.Count -gt 1 ) {
                        $commandMetaData = $command -as [Management.Automation.CommandMetadata]
                        
                        $hideParameter = if ($extraParams.HideParameter) {
                            @($extraParams.HideParameter )
                        } else {
                            @()
                        }
                        
                        $allowedParameter  = $CommandMetaData.Parameters.Keys 
            
                        # Remove the denied parameters    
                        $allParameters = foreach ($param in $allowedParameter) {
                            if ($hideParameter -notcontains $param) {
                                $param
                            }
                        }
            
                        $order = 
                             @($allParameters| 
                                Select-Object @{
                                    Name = "Name"
                                    Expression = { $_ }
                                },@{
                                    Name= "NaturalPosition"
                                    Expression = { 
                                        $p = @($commandMetaData.Parameters[$_].ParameterSets.Values)[0].Position
                                        if ($p -ge 0) {
                                            $p
                                        } else { 1gb }                                              
                                    }
                                } |
                                Where-Object {                                   
                                    $_.NaturalPosition -ne 1gb                                     
                                } |
                                Sort-Object NaturalPosition| 
                                Select-Object -ExpandProperty Name)
                        $cmdPart, $orderedParams = @($relativeUrlParts |
                            Where-Object {
                                -not $_.Contains("?")
                            })
                        
                        if ($orderedParams) {
                            $orderedParams = @($orderedParams)
                            $lastParameter = $null
                            for ($n =0 ;$n -lt $orderedParams.Count;$n++) {
                                
                                if (-not $extraParams.ParameterDefaultValue) {
                                    $extraParams.ParameterDefaultValue = @{}
                                }

                                $ParameterValue = [Web.HttpUtility]::UrlDecode($orderedParams[$n])
                                
                                if ($n -ge $order.Count) {
                                    $acceptsRemainingArguments = $command.Parameters.$($order[$order.Count -1]).Attributes | 
                                        Where-Object {$_.ValueFromRemainingArguments } 
                                    if ($acceptsRemainingArguments) {
                                        if ($command.Parameters.$($order[$order.Count -1]).ParameterType.IsSubclassOf([Array])) {
                                            $extraParams.ParameterDefaultValue.($order[$order.Count -1]) = @($extraParams.ParameterDefaultValue.($order[$order.Count -1])) + $parameterValue
                                        } elseif ($command.Parameters.$($order[$order.Count -1]).ParameterType -is [ScriptBlock]) {
                                            $extraParams.ParameterDefaultValue.($order[$order.Count -1]) = [ScriptBlock]::Create(($extraParams.ParameterDefaultValue.($order[$order.Count -1])).ToString() + $parameterValue)
                                        } else {
                                            $extraParams.ParameterDefaultValue.($order[$order.Count -1]) += $ParameterValue
                                        }
                                        
                                    }
                                    $command.Parameter.$($order[$n])
                                } else {
                                    $extraParams.ParameterDefaultValue.($order[$n]) = $ParameterValue
                                    
                                    if ($command.Parameters.($order[$n]).ParameterType -eq 
                                        [ScriptBlock]) {
                                        $extraParams.ParameterDefaultValue.($order[$n]) =
                                            [ScriptBlock]::Create($extraParams.ParameterDefaultValue.($order[$n]))
                                    }
                                }

                                if ($extraParams.ParameterDefaultValue.Count) {
                                    $extraParams.RunWithoutInput = $true
                                }                                
                            }
                        }
                        
                        
                    }
                    

                    if ($extraParams.DefaultParameter -and $extraParams.ParameterDefaultValue) {
                        # Reconcile aliases


                        $combinedTable = @{}
                        foreach ($kv in $extraParams.ParameterDefaultValue.GetEnumerator()) {
                            $combinedTable[$kv.Key] = $kv.Value
                        }
                        foreach ($kv in $extraParams.DefaultParameter.GetEnumerator()) {
                            $combinedTable[$kv.Key] = $kv.Value                            
                        }

                        $null = $extraParams.Remove('DefaultParameter')
                        $extraParams['ParameterDefaultValue'] = $combinedTable
                    }
                                        


                                            

                    $result = 
                        try {
                            Invoke-Webcommand -Command $command @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1
                        } catch {
                            $_        
                        }
                    
                    
                    if ($result) {
                        if ($Request.params["AsRss"] -or 
                            $Request.params["AsCsv"] -or
                            $Request.params["AsXml"] -or
                            $Request.Params["bare"] -or 
                            $extraParams.ContentType -or
                            $extraParams.PlainOutput) {
                            
                            
                            if ((-not $extraParams.ContentType) -and
                                $result -like "*<*>*" -and 
                                $result -like '*`$(*)*') {
                                # If it's not HTML or XML, but contains tags, then render it in a page with JQueryUI
                                $outputPage = $socialRow, $spacingDiv, $descriptionArea, $spacingDiv, $result |
                                    New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                                $response.Write($outputPage)
                            } else {
                                $response.Write($result)
                                
                                
                            }
                            
                        } else {
                            if (($result -is [Collections.IEnumerable]) -and ($result -isnot [string])) {
                                $Result = $result | Out-HTML                                
                            }

                            if ($request["Snug"]) {
                                $outputPage = $socialRow +"<div style='clear:both;margin-top:1%'> </div>" +  "<div style='float:left'>$(ConvertFrom-Markdown -Markdown "$commandDescription ")</div>" + "<div style='clear:both;margin-top:1%'></div>" + $result |
                                    New-Region -Style @{
                                        "Margin-Left" = "1%"
                                        "Margin-Right" = "1%"
                                    }|
                                    New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                                $response.Write($outputPage)
                            } else {
                                $outputPage = $socialRow + $titleArea + "<div style='clear:both;margin-top:1%'></div>" + "<div style='float:left'>$(ConvertFrom-Markdown -Markdown "$commandDescription ")</div>" +  $spacingDiv + $result |
                                New-Region -Style @{
                                    "Margin-Left" = $marginPercentLeftString
                                    "Margin-Right" = $marginPercentLeftString
                                }|
                                New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI
                                $response.Write($outputPage)
                            }
                            
                        }                
                    }                    
                } elseif (($relativeUrlParts[0].EndsWith("-?")) -or 
                    ($relativeUrlParts[1] -eq '-?')) {
                    $CommandNameGuess = $RelativeUrlParts[0].TrimEnd("?").TrimEnd("-")
                    
                    
                    $command = $module.ExportedCommands[$commandNameGuess]
                    if ($command) {
                        $extraParams = if ($pipeworksManifest -and $pipeworksManifest.WebCommand.($Command.Name)) {                
                            $pipeworksManifest.WebCommand.($Command.Name)
                        } else { @{} }             
                        $extraParams.ShowHelp = $true
                        $result =Invoke-WebCommand -Command $command @extraParams -ServiceUrl $finalUrl 2>&1

                    }

                    
                    if ($result) {
                        
                        $result |
                            New-Region -Style @{
                                "Margin-Left" = $marginPercentLeftString
                                "Margin-Right" = $marginPercentLeftString
                            }|
                            New-WebPage -Title "$($module.Name) | $command" -UseJQueryUI |
                            Out-HTML -WriteResponse 
                        
                    }
                    return
                }
                
                
                
                $potentialTopicName = $relativeUrlParts[0].Replace("+"," ").Replace("%20", " ")
                $potentialTopicName =  [Regex]::Replace($potentialTopicName , 
                        "\b(\w)", 
                        { param($a) $a.Value.ToUpper() })                                                 
                # If it's a topic, display the topic
                $theTopic = $aboutTopics | 
                    Where-Object { 
                        $_.Name -eq $potentialTopicName 
                    }
                    
                    

                if ($theTopic) {
                    $found = $true
                    $descriptionArea = "<h2 style='text-align:$TitleAlignment' >
            $potentialTopicName 
            </h2>
            <br/>"
                    $topicHtml = ConvertFrom-Markdown -Markdown $theTopic.Topic -ScriptAsPowerShell

                    if ($request["Snug"]) {
                        $socialRow +  "<div style='clear:both;margin-top:1%'></div>" +  $spacingDiv +  $topicHtml |                            
                            New-WebPage -Title "$($module.Name) | $potentialTopicName" -UseJQueryUI |
                            Out-HTML -WriteResponse 

                    } else {                    
                        
                        $titleArea + $socialRow +  "<div style='clear:both;margin-top:1%'></div>" +  $descriptionArea +  ($spacingDiv * 4) + $topicHtml |
                            New-Region -Style @{
                                "Margin-Left" = $marginPercentLeftString
                                "Margin-Right" = $marginPercentLeftString
                            }|
                            New-WebPage -Title "$($module.Name) | $potentialTopicName" -UseJQueryUI |
                            Out-HTML -WriteResponse 

                    }
                } 
                
                $theWalkthru = if ($walkthrus) {
                    $walkthrus.GetEnumerator() | 
                        Where-Object { 
                            $_.Key -eq $potentialTopicName 
                        }
                } 

                if ($theWalkthru) {
                    $found = $true
                    $descriptionArea = "<h2 style='text-align:$TitleAlignment' >
            $potentialTopicName 
            </h2>
            <br/>"


                    
                    $params = @{}
                    if ($pipeworksManifest.TrustedWalkthrus -contains $theWalkThru.Key) {
                        $params['RunDemo'] = $true
                    }
                    if ($pipeworksManifest.WebWalkthrus -contains $theWalkThru.Key) {
                        $params['OutputAsHtml'] = $true
                    }
                    
                    if ($request["Snug"]) {
                        $socialRow + "<div style='clear:both;margin-top:1%'></div>" + $descriptionArea + ($spacingDiv * 4) + (Write-WalkthruHTML -WalkthruName $theWalkthru.Key -WalkThru $theWalkthru.Value -StepByStep @params) |
                            New-Region -Style @{
                                "Margin-Left" = $marginPercentLeftString
                                "Margin-Right" = $marginPercentLeftString
                            }|
                            New-WebPage -Title "$($module.Name) | $potentialTopicName" -UseJQueryUI |
                            Out-HTML -WriteResponse 
                    } else {
                        $titleArea + $socialRow + "<div style='clear:both;margin-top:1%'></div>" + $descriptionArea + ($spacingDiv * 4) + (Write-WalkthruHTML -WalkthruName $theWalkthru.Key -WalkThru $theWalkthru.Value -StepByStep @params) |
                            New-Region -Style @{
                                "Margin-Left" = $marginPercentLeftString
                                "Margin-Right" = $marginPercentLeftString
                            }|
                            New-WebPage -Title "$($module.Name) | $potentialTopicName" -UseJQueryUI |
                            Out-HTML -WriteResponse 
                    }

                } 
                               

                
                
                if (-not $found) {
                    
                    $response.StatusCode = 404
                    
                    $response.Write("Not Found")
                    return
                }
                
            } else {
            
            }
        
        
        }                                
        #endregion Anything Handler
        
        #region ObjectHandler
        $objectHandler = {
            if (-not ($pipeworksManifest.Table -and $pipeworksManifest.Table.StorageAccountSetting -and $pipeworksManifest.Table.StorageKeySetting)) {
                throw 'The Pipeworks manifest must include three settings in order to retrieve items from table storage: Table, TableStorageAccountSetting, and TableStorageKeySetting'
                return
            }
            
            $partition, $row = $request['Object'] -split ':'       
                             
            $rowMatch= [ScriptBLock]::Create("`$_.RowKey -eq '$row'")
            $partitionMatch = [ScriptBLock]::Create("`$_.PartitionKey -eq '$partition'")
            $storageAccount = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageAccountSetting)
            $storageKey = (Get-WebConfigurationSetting -Setting $pipeworksManifest.Table.StorageKeySetting)
            Show-WebObject -Table $pipeworksManifest.Table.Name -Row $row -Part $partition |
                New-Region -Style @{
                    'margin-left' = '7.5%'
                    'margin-right' = '7.5%'
                    'margin-top' = '2%'                
                } -layerid objectHolder |
                New-WebPage -Title $row -UseJQueryUI |
                Out-HTML -WriteResponse
            
             
            
        }
        #endregion ObjectHandler             

        # The Import Handler 
        $importHandler = {



$returnedScript = {

}.ToString() + @"
    `$moduleName = '$($module.Name)'
    if (Get-Module `$moduleName) { 
        Write-Warning '$($module.Name) Already Exists'
        return
    }
    `$xhttp = New-Object -ComObject Microsoft.XmlHttp
    `$xhttp.open('GET', '${finalUrl}?-GetManifest', 1)
    `$xhttp.Send()
    do {
        Write-Progress "Downloading Manifest" '${finalUrl}?-GetManifest'    
    } while (`$xHttp.ReadyState -ne 4)

    `$manifest = `$xHttp.ResponseText
    if (-not `$toDirectory) {    
        `$targetModuleDirectory =Join-Path `$home '\Documents\WindowsPowerShell\Modules\$($module.Name)'
    } else {
        `$targetModuleDirectory = `$toDirectory
    }

Write-Progress "Downloading Commands" "${finalUrl}?-GetManifest"
"@ + {



$importScript = $manifest | 
        Select-Xml //AllCommands | 
        ForEach-Object {
            $_.Node.Command 
        } |
        ForEach-Object -Begin {
            $stringBuilder = New-Object Text.StringBuilder
        } {        
            $cmdName = $_.Name
            Write-Progress "Downloading Metadata" "$cmdName"
            $xhttp.open('GET', "$($_.Url.Trim('/'))/?-GetMetaData", 1)
            $xhttp.Send()
            do {
                Write-Progress "Downloading Metadata" "$cmdName"    
            } while ($xHttp.ReadyState -ne 4)

            $commandMetaData = $xHttp.responseText
            $cxml = $commandMetaData -as [xml]
            if ($cxml.CommandManifest.AllowDownload -eq 'true') {
                # Download it
                $xhttp.open('GET', "$($_.Url.TrimEnd('/'))/?-Download", 1)
                $xhttp.Send()
                do {
                    Write-Progress "Downloading" "$cmdName"    
                } while ($xHttp.ReadyState -ne 4 )

                try {
                    $sb = $xHttp.responseText
                    $null = ([ScriptBlock]::Create($sb))
                    $null = $stringBuilder.Append("$sb
")
                } catch {
                    Write-Debug $xHttp.ResponseText
                    $_ | Write-Error
  
                } 
            } elseif ($cxml.CommandManifest.RunOnline -eq 'true') {
                # Download the proxy
                $xhttp.open('GET', "$($_.Url.TrimEnd('/'))/?-DownloadProxy", 1)
                $xhttp.Send()
                do {
                    Write-Debug "Downloading" "$cmdName"    
                } while ($xHttp.ReadyState -ne 4)
                
                $sb = $xHttp.responseText
                . ([ScriptBlock]::Create($sb))
                if ($?) {  
                    $null = $stringBuilder.Append("$sb
")
}
            }
                     
        } -End {
            [ScriptBLock]::Create($stringBuilder)
        }

New-Module -ScriptBlock $importScript -Name $moduleName

}
$response.ContentType = 'text/plain'
$response.Write("$returnedScript")
$response.Flush()
}
        
        # The Self-Install Handler
        $installMeHandler = {
        
$returnedScript = {

param([string]$toDirectory)
    $webClient = New-Object Net.WebClient 
    
}.ToString() + @"
    Write-Progress "Downloading Manifest" '${finalUrl}?-GetManifest'
    `$manifest = `$webClient.DownloadString('${finalUrl}?-GetManifest')
    if (-not `$toDirectory) {    
        `$targetModuleDirectory =Join-Path `$home '\Documents\WindowsPowerShell\Modules\$($module.Name)'
    } else {
        `$targetModuleDirectory = `$toDirectory
    }
"@ + {

Write-Progress "Downloading Commands" '${finalUrl}?-GetManifest'
if ((Test-Path $targetModuleDirectory) -and (-not $toDirectory)) {
    Write-Warning "$targetModuleDirectory Exists, Creating ${targetModuleDirectory}Proxy"    
    $targetModuleDirectory = "${targetModuleDirectory}Proxy"
} 

$null = New-Item -ItemType Directory -Path $targetModuleDirectory

$directoryName = Split-Path $targetModuleDirectory -Leaf

$xmlMan = $manifest -as [xml]
$moduleVersion = $xmlMan.ModuleManifest.Version -as [Version]
if (-not $moduleVersion) { 
    $moduleVersion = "0.0"
}

$guidLine = if ($xmlMan.ModuleManifest.Guid) {
    "Guid = '$($xmlMan.ModuleManifest.Guid)'"
} else { ""} 

$companyLine = if ($xmlMan.ModuleManifest.Company) {
    "CompanyName = '$($xmlMan.ModuleManifest.Company)'"
} else { ""} 


$authorLine = if ($xmlMan.ModuleManifest.Author) {
    "Author = '$($xmlMan.ModuleManifest.Author)'"
} else { ""} 

$CopyrightLine = if ($xmlMan.ModuleManifest.Copyright) {
    "Copyright = '$($xmlMan.ModuleManifest.Copyright)'"
} else { ""} 


$descriptionLine= if ($xmlMan.ModuleManifest.Description) {
    "Description = @'
$($xmlMan.ModuleManifest.Description)
'@"
} else { ""} 



$psd1 = @"
@{
    ModuleVersion = '$($moduleVersion)'
    
    ModuleToProcess = '${directoryName}.psm1'
    
    $descriptionLine
    
    $guidLine
    
    $companyLine 
    
    $authorLine
    
    $CopyrightLine
    
    PrivateData = @{
        Url = '$($xmlMan.ModuleManifest.Url)'
        XmlManifest = @'
$(
$strWrite = New-Object IO.StringWriter
$xmlMan.Save($strWrite)
$strWrite 
)
'@        
    }   
}
"@

        

$psm1 = $manifest | 
    Select-Xml //AllCommands | 
    ForEach-Object {
        $_.Node.Command 
    } |
    ForEach-Object -Begin {
        $psm1 = ""
    } {        
        $targetPath = Join-Path $targetModuleDirectory "$($_.Name).ps1"
        Write-Progress "Downloading $($_.Name)" "From $($_.Url) to $targetPath"
        $commandMetaData = $webClient.DownloadString("$($_.Url.Trim('/'))/?-GetMetaData")
        $cxml = $commandMetaData -as [xml]
        if ($cxml.CommandManifest.AllowDownload -eq 'true') {
            # Download it
            $webClient.DownloadString("$($_.Url.Trim('/'))/?-AllowDownload") | 
                Set-Content $targetPath
        } elseif ($cxml.CommandManifest.RunOnline -eq 'true') {
            # Download the proxy
            $webClient.DownloadString("$($_.Url.Trim('/'))/?-DownloadProxy") | 
                Set-Content $targetPath
            
        } else {
            # Download the stub
            $webClient.DownloadString("$($_.Url.Trim('/'))/?-Stub") | 
                Set-Content $targetPath
        }
        
        $psm1 += '. $psScriptRoot\' + $_.Name + '.ps1' + ([Environment]::NewLine) 
    } -End {
        $psm1 
    }
    
    $psm1 | 
        Set-Content "$targetModuleDirectory\$directoryName.psm1" 
        
    $psd1 | 
        Set-Content "$targetModuleDirectory\$directoryName.psd1"

}



$response.ContentType = 'text/plain'
$response.Write("$returnedScript")
$response.Flush()
}
        # all Commands page
        $allCommandsPage = {


$commandUrlList=  Get-Command | Where-Object { $_.Module.Name -eq $module.Name } | Sort-Object | Select-Object -ExpandProperty Name | Write-Link -List
$order = @()
$layerTitle = "$($module.Name) | All Commands" 
$order += $layerTitle
$layers = @{
    $layerTitle = '<div style=''margin-left:15px''>' + $commandUrlList+ '</div>'
}

# Group by Verb
Get-Command | Where-Object { $_.Module.Name -eq $module.Name }  | 
    Group-Object {$_.Name.Substring(0,$_.Name.IndexOf("-")) } |
    ForEach-Object {
        $order += $_.Name
        $layers[$_.Name] = '<div style=''margin-left:15px''>'  + ($_.Group | Select-Object -ExpandProperty Name | Write-Link) + '</div>'
    }

$region = 
    New-Region -AutoSwitch '0:0:15' -HorizontalRuleUnderTitle -DefaultToFirst -Order $order -Container 'CommandList' -Layer $layers
$page = New-WebPage -Css $cssStyle -Title $layerTitle -AnalyticsID '$analyticsId' -PageBody $region
$response.ContentType = 'text/html'
$response.Write("     $page                ")        

        } 
        
        # -GetCommand list
        $getCommandList = {
$baseUrl = $request.URL
    $commandUrlList = foreach ($cmd in $moduleCommands) {
        $cmd.Name
    }
    $commandUrlList = $commandUrlList | Sort-Object
    $response.ContentType = 'text/plain'
    $commandList = ($commandUrlList -join ([Environment]::NewLine))
    $response.Write([string]"
$commandList
")
        
        }

        $NewSiteMap = {
    param($RemoteCommandUrl)

$aboutFiles  =  @(Get-ChildItem -Filter *.help.txt -Path "$moduleRoot\en-us" -ErrorAction SilentlyContinue)

if ($requestCulture -and ($requestCulture -ine 'en-us')) {
    $aboutFiles  +=  @(Get-ChildItem -Filter *.help.txt -Path "$moduleRoot\$requestCulture" -ErrorAction SilentlyContinue)
}


$walkThrus = @{}
$aboutTopics = @()
$namedTopics = @{}


if ($aboutFiles) {
    foreach ($topic in $aboutFiles) {        
        if ($topic.fullname -like "*.walkthru.help.txt") {
            $topicName = $topic.Name.Replace('_',' ').Replace('.walkthru.help.txt','')
            $walkthruContent = Get-Walkthru -File $topic.Fullname            
            $walkThruName = $topicName             
            $walkThrus[$walkThruName] = $walkthruContent                                     
        } else {
            $topicName = $topic.Name.Replace(".help.txt","")
            $aboutTopics += 

                New-Object PSObject -Property @{

                    Name = $topicName.Replace("_", " ")
                    SystemName = $topicName
                    Topic = Get-Help $topicName
                    LastWriteTime = $topic.LastWriteTime
                } 
        }
    }
}

$blogChunk = if ($pipeworksManifest.Blog -and $pipeworksManifest.Blog.Link -and $pipeworksManifest.Blog.Name) {
    $blogLink = if ($pipeworksManifest.Blog.Link -like "http*" -and $pipeworksManifest.Blog.Name -and $pipeworksManifest.Blog.Description) {
        # Absolute link to module base, 
        $pipeworksManifest.Blog.Link.TrimEnd("/") + "/Module.ashx?rss=$($pipeworksManifest.Blog.Name)"
    } else {
        $pipeworksManifest.Blog.Link
    }
    "<url>        
        <loc>$([Security.Securityelement]::Escape($BlogLink))</loc>        
    </url>"
} else {
    ""
}
$aboutChunk = ""
$aboutChunk = foreach ($topic in $aboutTopics) {
    if (-not $topic) { continue }
    $isInGroup = $false

    if (($pipeworksManifest.TopicGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq ($Topic.Name) }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq ($Topic.Name) }
            })) {

        $isInGroup = $true
    }

    "<url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($topic.Name)/</loc>
        <changefreq>weekly</changefreq>
        $(if ($isInGroup) {
            "<priority>0.8</priority>"
        })
    </url>"
}

$walkthruChunk = ""
$walkthruChunk = foreach ($walkthruName in ($walkthrus.Keys | Sort-Object)) {
    $isInGroup = $false
    if (($pipeworksManifest.TopicGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $walkthruName }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $walkthruName }
            })) {

        $isInGroup = $true
    }


    "<url>
        
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($walkthruName)/</loc>
        <changefreq>weekly</changefreq>
        $(if ($isInGroup) {
            "<priority>0.8</priority>"
        })
    </url>"
}

$CommandChunk = ""
$CommandChunk = foreach ($cmd in ($pipeworksManifest.WebCommand.Keys | Sort-Object)) {
    if ($pipeworksManifest.WebCommand[$Cmd].Hidden -or
        $pipeworksManifest.WebCommand[$Cmd].IfLoggedInAs -or
        $pipeworksManifest.WebCommand[$Cmd].ValidUserPartition -or 
        $pipeworksManifest.WebCommand[$Cmd].RequireLogin -or 
        $pipeworksManifest.WebCommand[$Cmd].RequireAppKey) {
        continue
    }

    $aliased = Get-Command -Module Gruvity -CommandType Alias | Where-Object { $_.ResolvedCommand.Name -eq $cmd } 
    $isInGroup = $false
    if (($pipeworksManifest.CommandGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $cmd }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $cmd }
            })) {

        $isInGroup = $true
    }
    if ($aliased) {
        foreach ($a in $aliased) {
            "
    <url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($a.Name)/</loc>        
        $(if ($isInGroup) {
            "<priority>1</priority>"
        } else {
            "<priority>0.7</priority>"
        })
    </url>
        "
        }
    }
    "<url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($cmd)/</loc>        
        $(if ($isInGroup) {
            "<priority>0.9</priority>"
        } else {
            "<priority>0.6</priority>"
        })
    </url>"
}

$siteMapXml = [xml]"<urlset xmlns=`"http://www.sitemaps.org/schemas/sitemap/0.9`">
    <url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/</loc>
        <priority>1.0</priority>
    </url>
    $aboutChunk
    $WalkThruChunk
    $CommandChunk 
</urlset>"

return $siteMapXml        
        }


        $getSiteMap = {
if ($application -and $application["SitemapFor_$($module.Name)"]) {
    $manifestXml = $application["SitemapFor_$($module.Name)"]
    $strWrite = New-Object IO.StringWriter
    $manifestXml.Save($strWrite)
    $response.ContentType = 'text/xml'
    $response.Write("$strWrite")
    return
}        



$blogChunk = if ($pipeworksManifest.Blog -and $pipeworksManifest.Blog.Link -and $pipeworksManifest.Blog.Name) {
    $blogLink = if ($pipeworksManifest.Blog.Link -like "http*" -and $pipeworksManifest.Blog.Name -and $pipeworksManifest.Blog.Description) {
        # Absolute link to module base, 
        $pipeworksManifest.Blog.Link.TrimEnd("/") + "/Module.ashx?rss=$($pipeworksManifest.Blog.Name)"
    } else {
        $pipeworksManifest.Blog.Link
    }
    "<url>        
        <loc>$([Security.Securityelement]::Escape($BlogLink))</loc>        
    </url>"
} else {
    ""
}
$aboutChunk = ""
$aboutChunk = foreach ($topic in $aboutTopics) {
    if (-not $topic) { continue }
    $isInGroup = $false

    if (($pipeworksManifest.TopicGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq ($Topic.Name) }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq ($Topic.Name) }
            })) {

        $isInGroup = $true
    }

    "<url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($topic.Name)</loc>
        <changefreq>weekly</changefreq>
        $(if ($isInGroup) {
            "<priority>0.8</priority>"
        })
    </url>"
}

$walkthruChunk = ""
$walkthruChunk = foreach ($walkthruName in ($walkthrus.Keys | Sort-Object)) {
    $isInGroup = $false
    if (($pipeworksManifest.TopicGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $walkthruName }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $walkthruName }
            })) {

        $isInGroup = $true
    }


    "<url>
        
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($walkthruName)</loc>
        <changefreq>weekly</changefreq>
        $(if ($isInGroup) {
            "<priority>0.8</priority>"
        })
    </url>"
}

$CommandChunk = ""
$CommandChunk = foreach ($cmd in ($pipeworksManifest.WebCommand.Keys | Sort-Object)) {
    if ($pipeworksManifest.WebCommand[$Cmd].Hidden -or
        $pipeworksManifest.WebCommand[$Cmd].IfLoggedInAs -or
        $pipeworksManifest.WebCommand[$Cmd].ValidUserPartition -or 
        $pipeworksManifest.WebCommand[$Cmd].RequireLogin -or 
        $pipeworksManifest.WebCommand[$Cmd].RequireAppKey) {
        continue
    }

    $aliased = Get-Command -Module Gruvity -CommandType Alias | Where-Object { $_.ResolvedCommand.Name -eq $cmd } 
    $isInGroup = $false
    if (($pipeworksManifest.CommandGroup | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $cmd }
            }) -or
            ($pipeworksManifest.Group | 
            Where-Object { $_.Values | 
                Where-Object { $_ -eq $cmd }
            })) {

        $isInGroup = $true
    }
    if ($aliased) {
        foreach ($a in $aliased) {
            "
    <url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($a.Name)</loc>        
        $(if ($isInGroup) {
            "<priority>1</priority>"
        } else {
            "<priority>0.7</priority>"
        })
    </url>
        "
        }
    }
    "<url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/$($cmd)</loc>        
        $(if ($isInGroup) {
            "<priority>0.9</priority>"
        } else {
            "<priority>0.6</priority>"
        })
    </url>"
}

$siteMapXml = [xml]"<urlset xmlns=`"http://www.sitemaps.org/schemas/sitemap/0.9`">
    <url>
        <loc>$($remoteCommandUrl.TrimEnd('/'))/</loc>
        <priority>1.0</priority>
    </url>
    $aboutChunk
    $WalkThruChunk
    $CommandChunk 
</urlset>"



$application["SitemapFor_$($module.Name)"] = $siteMapXml;
$strWrite = New-Object IO.StringWriter
$siteMapXml.Save($strWrite)
$response.ContentType = 'text/xml'
$response.Write("$strWrite")





        }


                
        $getManifestXml = {

if ($application -and $application["ManifestXmlFor_$($module.Name)"]) {
    $manifestXml = $application["ManifestXmlFor_$($module.Name)"]
    $strWrite = New-Object IO.StringWriter
    $manifestXml.Save($strWrite)
    $response.ContentType = 'text/xml'
    $response.Write("$strWrite")
    return
}



# The Manifest XML is used to help interact with a module from a remote service.  
# It contains module metadata and discovery information that will be used by most clients.
$commandGroupChunk = ""
$commandGroupChunk = foreach ($commandGroup in $pipeworksmanifest.CommandGroup) {
    if (-not $commandGroup) { continue } 
    if ($commandGroup -isnot [Hashtable]) { continue } 

    foreach ($kv in $commandGroup.GetEnumerator()) {
        $groupItems= foreach ($cmd in $kv.Value) {
            "<Command>$cmd</Command>"
        }
        "<CommandGroup>
            <Name>
                $($kv.Key)
            </Name>
            $groupItems
        </CommandGroup>"
    }

    
        $cmdGroups
    
}
if ($commandGroupChunk) {
    $commandGroupChunk = "<CommandGroups>
$commandGroupChunk
</CommandGroups>"

}

$topicGroupChunk = ""
$topicGroupChunk  = foreach ($topicGroup in $pipeworksmanifest.TopicGroup) {
    if (-not $topicGroup) { continue } 
    if ($topicGroup -isnot [Hashtable]) { continue } 
    
    foreach ($kv in $topicGroup.GetEnumerator()) {
        $groupItems= foreach ($cmd in $kv.Value) {
            "<Topic>$cmd</Topic>"
        }
        "<TopicGroup>
            <Name>
$($kv.Key)
            </Name>
            $groupItems
        </TopicGroup>"
    }

}

if ($topicGroupChunk  ) {
    $topicGroupChunk  = "<TopicGroups>
$topicGroupChunk  
</TopicGroups>"

}


$blogChunk = if ($pipeworksManifest.Blog -and $pipeworksManifest.Blog.Link -and $pipeworksManifest.Blog.Name) {
    $blogLink = if ($pipeworksManifest.Blog.Link -like "http*" -and $pipeworksManifest.Blog.Name -and $pipeworksManifest.Blog.Description) {
        # Absolute link to module base, 
        $pipeworksManifest.Blog.Link.TrimEnd("/") + "/Module.ashx?rss=$($pipeworksManifest.Blog.Name)"
    } else {
        $pipeworksManifest.Blog.Link
    }
    "<Blog>
        <Name>$([Security.Securityelement]::Escape($pipeworksManifest.Blog.Name))</Name>
        <Feed>$([Security.Securityelement]::Escape($BlogLink))</Feed>        
    </Blog>"
} else {
    ""
}

$aboutChunk = foreach ($topic in $aboutTopics) {
    if (-not $topic) { continue }

    "<Topic>
        <Name>
$([Security.Securityelement]::Escape($topic.Name))
        </Name>
        <Content>
$([Security.Securityelement]::Escape((ConvertFrom-Markdown -Markdown $topic.Topic -ScriptAsPowerShell)))
        </Content>
    </Topic>"
}


$styleChunk = if ($pipeworksmanifest.Style) {
    $styleXml = "<Style>"
    if ($pipeworksmanifest.Style.Body."font-family") {
        $fonts = foreach ($fontName in ($pipeworksmanifest.Style.Body."font-family" -split ",")) {
            "<Font>$([Security.SecurityElement]::Escape($FontName))</Font>"
        }
        $styleXml += "<Fonts>$Fonts</Fonts>"
    }
    if ($pipeworksmanifest.Style.Body.color) { 
        $styleXml += "<Foreground>$([Security.SecurityElement]::Escape($pipeworksmanifest.Style.Body.color))</Foreground>"
    }
    if ($pipeworksmanifest.Style.Body.'background-color') { 
        $styleXml += "<Background>$([Security.SecurityElement]::Escape($pipeworksmanifest.Style.Body.'background-color'))</Background>"
    }
    $styleXml += "</Style>"
    $styleXml 
} else {
    ""
}

$walkthruChunk = foreach ($walkthruName in ($walkthrus.Keys | Sort-Object)) {
    $steps = foreach ($step in $walkthrus[$walkthruName]) {
        $videoChunk = if ($step.videoFile) {
            "<Video>$($step.videoFile)</Video>"
        } else {
            ""
        }
        "<Step>
            <Explanation>
$([Security.SecurityElement]::Escape($step.Explanation))
            </Explanation>
            <Script>

$(
if ($Step.Script -ne '$null') {
    [Security.SecurityElement]::Escape((Write-ScriptHTML -Text $step.Script))
})
            </Script>                        
            $videoChunk
        </Step>"
    }
    "<Walkthru>
        <Name>$([Security.SecurityElement]::Escape($WalkthruName))</Name>
        $steps
    </Walkthru>"
}


if ($aboutChunk -or $walkthruChunk) {
    $aboutChunk = "
<About>
$aboutChunk
$WalkthruChunk
</About>
"
}




# This handler creates a Manifest XML.  
$psd1Content = (Get-Content $psd1Path -ReadCount 0 -ErrorAction SilentlyContinue)
$psd1Content = $psd1Content -join ([Environment]::NewLine)
$manifestObject=  New-Object PSObject (& ([ScriptBlock]::Create(
     $psd1Content
)))
$protocol = ($request['Server_Protocol'] -split '/')[0]
$serverName= $request['Server_Name']
$shortPath = Split-Path $request['PATH_INFO']

$remoteCommandUrl= $Protocol + '://' + $ServerName.Replace('\', '/').TrimEnd('/') + '/' + $shortPath.Replace('\','/').TrimStart('/')
$remoteCommandUrl = ($finalUrl -replace 'Module\.ashx', "" -replace 'Default.ashx', "").TrimEnd("/")


$pipeworksManifestPath = Join-Path (Split-Path $module.Path) "$($module.Name).Pipeworks.psd1"
$pipeworksManifest = if (Test-Path $pipeworksManifestPath) {
    try {                     
        & ([ScriptBlock]::Create(
            "data -SupportedCommand Add-Member, New-WebPage, New-Region, Write-CSS, Write-Ajax, Out-Html, Write-Link { $(
                [ScriptBlock]::Create([IO.File]::ReadAllText($pipeworksManifestPath))                    
            )}"))            
    } catch {
        Write-Error "Could not read pipeworks manifest: ($_ | Out-String)" 
    }                                                
} else { $null } 

$allCommandChunks = New-Object Text.StringBuilder
$cmdsInModule = Get-Command | Where-Object { $_.Module.Name -eq $module.Name }
foreach ($cmd in  $cmdsInModule) {
    $help = Get-Help $cmd.Name
    if ($help.Synopsis) {
        $description = $help.Synopsis
        $null = $allCommandChunks.Append("<Command Name='$($cmd.Name)' Url='$($remoteCommandUrl.TrimEnd('/') + '/' + $cmd.Name + '/')'>$([Security.SecurityElement]::Escape($description))</Command>")    
    } else {
        $null  = $allCommandChunks.Append("<Command Name='$($cmd.Name)' Url='$($remoteCommandUrl.TrimEnd('/') + '/' + $cmd.Name + '/')'/>")
    }    
}
$allCommandChunks = "$allCommandChunks"

$defaultCommmandChunk  = if ($pipeworksManifest.DefaultCommand) {
    $defaultParams =  if ($pipeworksManifest.DefaultCommand.Parameter) {
        foreach ($kv in ($pipeworksManifest.DefaultCommand.Parameter | Sort-Object Key)) {
        "        
        <Parameter>
            <Name>$([Security.SecurityElement]::Escape($kv.Key))</Name>
            <Value>$([Security.SecurityElement]::Escape($kv.Value))</Value>
        </Parameter>
        "
        }
        
    } else {
        ""
    }
   "<DefaultCommand>
        <Name>$($pipeworksManifest.DefaultCommand.Name)</Name>
        $defaultParams
   </DefaultCommand>"
} else {
    ""
}

if ($pipeworksManifest.WebCommand) {
    $webCommandsChunk = "<WebCommand>"    
    $webcommandOrder = if ($pipeworksManifest.CommandOrder) {
        $pipeworksManifest.CommandOrder
    } else {
        $pipeworksManifest.WebCommand.Keys | Sort-Object
    }


    foreach ($wc in $webcommandOrder) {
        $LoginRequired= 
            $pipeworksManifest.WebCommand.$($wc).RequireLogin -or
            $pipeworksManifest.WebCommand.$($wc).RequiresLogin -or
            $pipeworksManifest.WebCommand.$($wc).RequireAppKey -or 
            $pipeworksManifest.WebCommand.$($wc).RequiresAppKey -or 
            $pipeworksManifest.WebCommand.$($wc).IfLoggedInAs -or
            $pipeworksManifest.WebCommand.$($wc).ValidUserPartition
        

        $LoginRequiredChunk = 
            if ($loginRequired) {
                " RequireLogin='true'"
            } else {
                ""
            }

        $isHiddenChunk = 
            if ($pipeworksManifest.WebCommand.$($wc).IfLoggedInAs -or
                $pipeworksManifest.WebCommand.$($wc).ValidUserPartition -or
                $pipeworksManifest.WebCommand.$($wc).Hidden) 
            {
                " Hidden='true'"
            } else {
                " "
            }

        $cmdFriendlyName = if ($pipeworksManifest.WebCommand.$wc.FriendlyName) {
            $pipeworksManifest.WebCommand.$wc.FriendlyName
        } else {
            $wc
        }

        $runWithoutInputChunk = if ($pipeworksManifest.WebCommand.$($wc).RunWithoutInput) {
            " RunWithoutInput='true'"
        } else {
            ""
        }

        $help = Get-Help $wc
        if ($help.Synopsis) {
            $description = $help.Synopsis
            $webCommandsChunk += "<Command Name='$([Security.SecurityElement]::Escape($cmdFriendlyName))' RealName='$wc' ${LoginRequiredChunk}${isHiddenChunk}${runWithoutInputChunk} Url='$($remoteCommandUrl.TrimEnd('/') + '/' + $wc + '/')'>$([Security.SecurityElement]::Escape($description))</Command>"    
        } else {
            $webCommandsChunk += "<Command Name='$([Security.SecurityElement]::Escape($cmdFriendlyName))' RealName='$wc' ${LoginRequiredChunk}${isHiddenChunk}${runWithoutInputChunk} Url='$($remoteCommandUrl.TrimEnd('/') + '/' + $wc + '/')'/>"
        }   
    }
    $webCommandsChunk += "</WebCommand>"
}

if ($pipeworksManifest.ModuleUrl) {
    $remoteCommandUrl = $pipeworksManifest.ModuleUrl
}




$moduleUrl = if ($request['Url'] -like "*.ashx*" -and $request['Url'] -notlike "*Default.ashx*") {
    $u = $request['Url'].ToString()
    $u = $u.Substring($u.LastIndexOf('/'))
    $remoteCommandUrl + $u
} elseif ($request['Url'] -like "*.ashx*" -and$moduleUrl -like "*Default.ashx") {
    
    $remoteCommandUrl.Substring(0,$remoteCommandUrl.Length - "Default.ashx".Length - 1)
} else {
    $remoteCommandUrl + "/"
}



$zipDownloadUrl  = if ($allowDownload) {
    
    "<DirectDownload>$($moduleUrl.Substring(0,$moduleUrl.LastIndexOf("/")) + '/' + $module.Name + '.' + $module.Version + '.zip')</DirectDownload>"
} else {
    ""
}




$facebookChunk = 
if ($pipeworksManifest.Facebook.AppId) {
    $scopeString = 
        if ($pipeworksManifest.Facebook.Scope) {
            $pipeworksManifest.Facebook.Scope -join ", "
        } else {
            "email, user_birthday"
        }
    "<Facebook>
        <AppId>$($pipeworksManifest.Facebook.AppId)</AppId>
        <Scope>$scopeString</Scope>
    </Facebook>"
} else {
    ""
}


$LogoChunk = if ($pipeworksManifest.Logo) {
    "<Logo>$([Security.SecurityElement]::Escape($pipeworksManifest.Logo))</Logo>"
} else {
    ""
}

$pubCenterChunk =if ($pipeworksManifest.PubCenter) {
    $pubCenterId = if ($pipeworksmanifest.PubCenter.ApplicationId) {
        $pipeworksmanifest.PubCenter.ApplicationId
    } elseif ($pipeworksmanifest.PubCenter.Id) {
        $pipeworksmanifest.PubCenter.Id
    }
    if (-not $pubCenterId) {
        ""
    } else {
        "
<PubCenter>
    <ApplicationID>$($pubCenterId)</ApplicationID>
    <TopAdUnit>$($pipeworksmanifest.PubCenter.TopAdUnit)</TopAdUnit>
    <BottomAdUnit>$($pipeworksmanifest.PubCenter.BottomAdUnit)</BottomAdUnit>    
</PubCenter>"
    }

} else {
    ""
}


$adSenseChunk = if ($pipeworksManifest.AdSense) {
    $theAdSenseId =  if ($pipeworksmanifest.AdSense.AdSenseId) {
        $pipeworksmanifest.AdSense.AdSenseId
    } elseif ($pipeworksmanifest.AdSense.Id) {
        $pipeworksmanifest.AdSense.Id
    }

"<AdSense>
    <ApplicationID>$($TheAdSenseId)</ApplicationID>
    <TopSlot>$($pipeworksmanifest.AdSense.TopSlot)</TopSlot>
    <BottomSlot>$($pipeworksmanifest.AdSense.BottomAdSlot)</BottomSlot>
</AdSense>
"
} else {
    ""
}



$commandTriggerChunk = if ($pipeworksmanifest.CommandTrigger) {
    $sortedTriggers = $pipeworksmanifest.CommandTrigger.GetEnumerator() | Sort-Object Key
   
    $commandTriggerXml = foreach ($trigger in $sortedTriggers) {
        "
        <CommandTrigger>
            <Trigger>$([Security.SecurityElement]::Escape($Trigger.Key))</Trigger>
            <Command>$([Security.SecurityElement]::Escape($Trigger.Value))</Command>
        </CommandTrigger>"        
    }
    "<CommandTriggers>
    $($commandTriggerXml)
    </CommandTriggers>"
} else {
    ""
}


$manifestXml = [xml]"<ModuleManifest>
    <Name>$($module.Name)</Name>
    <Url>$($moduleUrl)</Url>
    <Version>$($module.Version)</Version>
    <Description>$([Security.SecurityElement]::Escape($module.Description))</Description>
    $LogoChunk
    $styleChunk
    <Company>$($manifestObject.CompanyName)</Company>
    <Author>$($manifestObject.Author)</Author>
    <Copyright>$($manifestObject.Copyright)</Copyright>    
    <Guid>$($manifestObject.Guid)</Guid> 
    $zipDownloadUrl   
    
    $facebookChunk 
    $blogChunk
    $aboutChunk
    $topicGroupChunk
    $defaultCommmandChunk  
    <AllCommands>
        $allCommandChunks
    </AllCommands>
    
    $webCommandsChunk
    
    $commandGroupChunk 
    $commandTriggerChunk
    $pubCenterChunk
    $AdSenseChunk
</ModuleManifest>"

$application["ManifestXmlFor_$($module.Name)"] = $manifestXml;
$strWrite = New-Object IO.StringWriter
$manifestXml.Save($strWrite)
$response.ContentType = 'text/xml'
$response.Write("$strWrite")
        }
               
               
        $mailHandlers =  if ($pipeworksManifest.Mail) {
@"
elseif (`$request['SendMail']) {
    $($mailHandler.ToString().Replace('"','""'))
}
"@        
        } else {
""
        }

        $checkoutHandlers = 
@"
elseif (`$request['AddItemToCart']) {
    $($addCartHandler.ToString().Replace('"','""'))
} elseif (`$request['ShowCart']) {
    $($ShowCartHandler.ToString().Replace('"','""'))
} elseif (`$request['Checkout']) {
    $($checkoutCartHandler.ToString().Replace('"','""'))    
}
"@
        
        $TableHandlers = if ($pipeworksManifest.Table) { @"
elseif (`$request['id']) {
    $($idHandler.ToString().Replace('"','""'))
} elseif (`$request['object']) {
    $($objectHandler.ToString().Replace('"','""'))
} elseif (`$request['Name']) {
    $($nameHandler.ToString().Replace('"','""'))
} elseif (`$request['Latest']) {
    $($latestHandler.ToString().Replace('"','""'))
} elseif (`$request['Rss']) {
    $($RssHandler.ToString().Replace('"','""'))
} elseif (`$request['Type']) {
    $($typeHandler.ToString().Replace('"','""'))
} elseif (`$request['Search']) {
    $($searchHandler.ToString().Replace('"','""'))
} 
"@.TrimEnd()
} else {
    ""
}
        
    $userTableHandlers = if ($pipeworksManifest.UserTable) {
@" 
elseif (`$request['Join']) {
    `$session['ProfileEditMode'] = `$true    
    $($JoinHandler.ToString().Replace('"','""'))
} elseif (`$request['EditProfile']) {
    `$editMode = `$true
    $($JoinHandler.ToString().Replace('"','""'))
} elseif (`$request['ConfirmUser']) {
    $($ConfirmUserHandler.ToString().Replace('"','""'))
} elseif (`$request['Login']) {
    $($LoginUserHandler.ToString().Replace('"','""'))
} elseif (`$request['Logout']) {
    $($LogoutUserHandler.ToString().Replace('"','""'))
} elseif (`$request['ShowApiKey']) {
    $($ShowApiKeyHandler.ToString().Replace('"','""'))
} elseif (`$request['FacebookConfirmed']) {
    $($facebookConfirmUser.ToString().Replace('"','""'))
} elseif (`$request['LiveIDConfirmed']) {
    $($liveIdConfirmUser.ToString().Replace('"','""'))
} elseif (`$request['FacebookLogin']) {
    $($facebookLoginDisplay.ToString().Replace('"','""'))
} elseif (`$request['Purchase'] -or `$request['Rent']) {
    $($addPurchaseHandler.ToString().Replace('"','""'))
} elseif (`$request['Settle']) {
    $($settleHandler.ToString().Replace('"','""'))
} 
"@        
        } else {
            ""
        }
        
        
        #region GetExtraCommandInfo
        $getCommandExtraInfo = {
            param([string]$RequestedCommand) 

            $command = 
                if ($module.ExportedAliases[$RequestedCommand]) {
                    $module.ExportedAliases[$RequestedCommand]
                } elseif ($module.ExportedFunctions[$requestedCommand]) {
                    $module.ExportedFunctions[$RequestedCommand]
                } elseif ($module.ExportedCmdlets[$requestedCommand]) {
                    $module.ExportedCmdlets[$RequestedCommand]
                }
            
            if ($command.ResolvedCommand) {
                $command = $command.Resolvedcommand
            }
            
            if (-not $command)  {
                throw "$requestedCommand not found in module $module"
            }
            
            
            # Generate individual handlers
            $extraParams = if ($pipeworksManifest -and $pipeworksManifest.WebCommand.($Command.Name)) {                
                $pipeworksManifest.WebCommand.($Command.Name)
            } elseif ($pipeworksManifest -and $pipeworksManifest.WebAlias.($Command.Name) -and
                $pipeworksManifest.WebCommand.($pipeworksManifest.WebAlias.($Command.Name).Command)) { 
                
                $webAlias = $pipeworksManifest.WebAlias.($Command.Name)
                $paramBase = $pipeworksManifest.WebCommand.($pipeworksManifest.WebAlias.($Command.Name).Command)
                foreach ($kv in $webAlias.GetEnumerator()) {
                    if (-not $kv) { continue }
                    if ($kv.Key -eq 'Command') { continue }
                    $paramBase[$kv.Key] = $kv.Value
                }

                $paramBase
            } else { @{
                    ShowHelp=$true

            } }             
            
            if ($pipeworksManifest -and $pipeworksManifest.Style -and (-not $extraParams.Style)) {
                $extraParams.Style = $pipeworksManifest.Style 
            }
            if ($extraParams.Count -gt 1) {
                # Very explicitly make sure it's there, and not explicitly false
                if (-not $extra.RunOnline -or 
                    $extraParams.Contains("RunOnline") -and $extaParams.RunOnline -ne $false) {
                    $extraParams.RunOnline = $true                     
                }                
            } 
            
            if ($extaParams.PipeInto) {
                $extaParams.RunInSandbox = $true
            }
            
            if (-not $extraParams.AllowDownload) {
                $extraParams.AllowDownload = $allowDownload
            }
            
                
            
            if ($extraParams.RequireAppKey -or 
                $extraParams.RequireLogin -or 
                $extraParams.IfLoggedAs -or 
                $extraParams.ValidUserPartition -or 
                $extraParams.Cost -or 
                $extraParams.CostFactor) {

                $extraParams.UserTable = $pipeworksManifest.Usertable.Name
                $extraParams.UserPartition = $pipeworksManifest.Usertable.Partition
                $extraParams.StorageAccountSetting = $pipeworksManifest.Usertable.StorageAccountSetting
                $extraParams.StorageKeySetting = $pipeworksManifest.Usertable.StorageKeySetting 

            }
            
            if ($extraParams.AllowDownload) {
                # Downloadable Commands
                $downloadableCommands += $command.Name                
            }
                        
            
            
            
            
            if ($MarginPercentLeftString -and (-not $extraParams.MarginPercentLeft)) {
                $extraParams.MarginPercentLeft = $MarginPercentLeftString.TrimEnd("%")
            }
            
            if ($MarginPercentRightString-and -not $extraParams.MarginPercentRight) {
                $extraParams.MarginPercentRight = $MarginPercentRightString.TrimEnd("%")
            }
        }        
        #endregion
               
        $moduleHandler = @"
WebCommandSequence.InvokeScript(@"

$($embedCommand.Replace('"','""'))
$($getModuleMetaData.ToString().Replace('"', '""'))
`$getCommandExtraInfo = { $($getCommandExtraInfo.ToString().Replace('"', '""'))
}
`$cssStyle = $((Write-PowerShellHashtable $Style).Replace('"','""'))
`$MarginPercentLeftString = '$MarginPercentLeftString'
`$MarginPercentRightString  = '$MarginPercentRightString'
`$DownloadUrl = '$DownloadUrl'
`$analyticsId = '$analyticsId'

`$allowDownload = $(if ($allowDownload) { '$true'} else {'$false'}) 
`$antiSocial= $(if ($antiSocial) { '$true'} else {'$false'}) 
`$highlightedModuleCommands = '$($CommandOrder -join "','")'



$($resolveFinalUrl.ToString().Replace('"', '""'))

`if (`$request['about']) {
    $($aboutHandler.ToString().Replace('"','""'))
} elseif (`$request['ShowPrivacyPolicy']) {
    $($privacyPolicyHandler.ToString().Replace('"','""').Replace('THE COMPANY', $module.CompanyName))
} elseif (`$request['AnythingGoes']) {
    $($anythingHandler.ToString().Replace('"','""'))
} elseif  (`$request['walkthru']){
    $($walkthruHandler.ToString().Replace('"','""'))
} elseif (`$request.QueryString.ToString() -ieq '-TopicRSS' -or `$request['TopicRSS']) {
    $($topicRssHandler.ToString().Replace('"','""')) 
} elseif (`$request.QueryString.ToString() -ieq '-WalkthruRSS' -or `$request['WalkthruRSS']) {
    $($walkthruRssHandler.ToString().Replace('"','""')) 
} elseif (`$Request['GetHelp']) {
    $($helpHandler.ToString().Replace('"','""'))
} elseif (`$Request['Command']) {
    $($commandHandler.ToString().Replace('"','""'))
} $tableHandlers $checkoutHandlers $userTableHandlers $mailHandlers  elseif  (`$request.QueryString.ToString() -eq '-Download') {
    `$page = New-WebPage -Css `$cssStyle -Title ""`$(`$module.Name) | Download"" -AnalyticsID '$analyticsId' -RedirectTo '?-DownloadNow'
    `$response.Write(`$page )
} elseif (`$request.QueryString.ToString() -eq '-Me' -or `$request['ShowMe']) {
    $($meHandler.ToString().Replace('"', '""'))
} elseif (`$request.QueryString.Tostring() -eq '-GetPSD1' -or `$request['PSD1']) {
    `$baseUrl = `$request.URL
    `$response.ContentType = 'text/plain'  
    `$response.Write([string]""
`$((Get-Content `$psd1Path -ErrorAction SilentlyContinue) -join ([Environment]::NewLine))
"")

} elseif (`$request.QueryString.Tostring() -eq '-GetManifest' -or `$request['GetManifest']) {
    $($getManifestXml.ToString().Replace('"','""'))
} elseif (`$request.QueryString.Tostring() -eq '-Sitemap' -or `$request['GetSitemap']) {
    $($getSitemap.ToString().Replace('"','""'))
} elseif (`$request.QueryString.Tostring() -eq '-Css' -or `$request.QueryString.Tostring() -eq '-Style') {
    if (`$pipeworksManifest -and `$pipeworksManifest.Style) {
        `$outcss = Write-CSS -NoStyleTag -Css `$pipeworksManifest.Style
        `$response.ContentType = 'text/css'
        `$response.Write([string]`$outCss)      
    } else {
        `$response.ContentType = 'text/plain'
        `$response.Write([string]'')      
    }
} elseif  (`$request.QueryString.ToString() -eq '-DownloadNow' -or `$request['DownloadNow']) {         
    if (`$downloadUrl) {
        `$page = New-WebPage -Title ""Download `$(`$module.Name)"" -RedirectTo ""`$downloadUrl""
        `$response.Write([string]`$page)
    } elseif (`$allowDownload) {                  

        `$modulezip = `$module.name + '.' + `$module.Version + '.zip'
         `$page = (New-object PSObject -Property @{RedirectTo=`$modulezip;RedirectIn='0:0:0.50'}),(New-object PSObject -Property @{RedirectTo=""/"";RedirectIn='0:0:5'}) | New-WebPage
        `$response.Write([string]`$page)
        `$response.Flush()                
    }
} elseif (`$request.QueryString.Tostring() -eq '-PaypalIPN' -or `$request['PayPalIPN']) {
    $($payPalIpnHandler.ToString().Replace('"','""'))
} else {
`

"@ + {




# Default Module Experience

# Currently going for:

# A row along the top with module name and social engagement
# A floating right description of the current activity
# A grid of buttons (with potential subgrids) containing things to do


$titleArea = 
    if ($PipeworksManifest -and $pipeworksManifest.Logo) {
        "<a href='$FinalUrl'><img src='$($pipeworksManifest.Logo)' style='border:0' /></a>"
    } else {
        "<a href='$FinalUrl'>$($Module.Name)</a>"
    }

$TitleAlignment = if ($pipeworksManifest.Alignment) {
    $pipeworksManifest.Alignment
} else {
    'center'
}
$titleArea = "<div style='text-align:$TitleAlignment'><h1 style='text-align:$TitleAlignment'>$titleArea</h1></div>"


$descriptionArea = "<h2 style='text-align:$TitleAlignment'>
$($module.Description -ireplace "`n", "<br/>")
</h2>
<br/>"    


$cmdTabs = @{}
$cmdUrls = @{}
$cmdLinks = @{}


$socialRow = "<div style='padding:20px'>
"


$loginRequired = ($pipeworksManifest -and @(
    $pipeworksManifest.WebCommand.Values  |
        Where-Object {
            $_.RequireLogin -or $_.RequireAppKey -or $_.IfLoggedInAs -or $_.ValidUserPartition
        })) -as [bool]


if (-not $antiSocial) {
    if ($pipeworksManifest -and $pipeworksManifest.Facebook.AppId) {
        $socialRow +=  "<span style='padding:5px;width:10%'>" +
            (Write-Link "facebook:like" ) + 
            "</span>"
    }
    if ($pipeworksManifest -and ($pipeworksManifest.GoogleSiteVerification -or $pipeworksManifest.AddPlusOne)) {
        $socialRow += "<span style='padding:5px;width:10%'>" +
            (Write-Link "google:plusone" ) +
            "</span>"
    }
    if ($pipeworksManifest -and $pipeworksManifest.ShowTweet) {
        $socialRow += 
            "<span style='padding:5px;width:10%'>" +
            (Write-Link "twitter:tweet" ) +
            "</span>"
    } elseif ($pipeworksManifest -and ($pipeworksManifest.TwitterId)) {
        $socialRow += 
            "<span style='padding:5px;width:10%'>" +
            (Write-Link "twitter:tweet" ) +
            "</span>"
        $socialRow += 
            "<span style='padding:5px;width:10%'>" +
            (Write-Link "twitter:follow@$($pipeworksManifest.TwitterId.TrimStart('@'))" ) +
            "</span>"
    }

}



if ($loginRequired) {
    $confirmPersonHtml = . Confirm-Person -WebsiteUrl $finalUrl
    
    if ($confirmPersonHtml) {
        $socialRow += $confirmPersonHtml
        $socialRow += "<BR/>"       
    }
    
    
}


$socialRow += "</div>"

$topicHtml  = ""

$subtopics = @{
    LayerId = 'MoreInfo'
    Layer = @{}
}

$webPageRss = @{}

if ($PipeworksManifest.Blog -and $PipeworksManifest.Blog.Name -and $PipeworksManifest.Blog.Link) {    
    $blogLink = if ($pipeworksManifest.Blog.link -like "http*" -and $pipeworksManifest.Blog.Description) {
        $PipeworksManifest.Blog.Link.TrimEnd("/") + "/Module.ashx?rss=$($PipeworksManifest.Blog.Name)"
    } else {
        $PipeworksManifest.Blog.Link
    }
    $webPageRss += @{
        $PipeworksManifest.Blog.Name=$blogLink 
    }
} 


$topicsByName = @{}


if ($aboutTopics) {
    $coreAboutTopic = $null
    $otherAboutTopics = 
        @(foreach ($_ in $aboutTopics) {
            if (-not $_) {continue } 
            if ($_.Name -ne "About $($Module.Name)") {
                $_
            } else {
                $coreAboutTopic = $_
            }
        })
        
    
    if ($coreAboutTopic) {
        $topicHtml = ConvertFrom-Markdown -Markdown "$($coreAboutTopic.Topic) "  -ScriptAsPowerShell
    }         
    
    if ($otherAboutTopics) {               
        $aboutItems = @()
        $tutorialItems = @()
        
        foreach ($oat in $otherAboutTopics) {
            if ($oat.Name -like "about*") {
                
                $aboutItems += 
                    if ($customAnyHandler) {
                        New-Object PSObject -Property @{
                            Caption = $oat.Name.Substring(6)
                            Url = "?About=" + $oat.Name
                        }
                    } else {
                        New-Object PSObject -Property @{
                            Caption = $oat.Name.Substring(6)
                            Url = $oat.Name + "/"
                        }
                    }
                
                
            } else {
                $tutorialItems += 
                    if ($customAnyHandler) {
                        New-Object PSObject -Property @{
                            Caption = $oat.Name
                            Url = "?About=" + $oat.Name
                        }
                    } else {
                        New-Object PSObject -Property @{
                            Caption = $oat.Name
                            Url = $oat.Name + "/"
                        }
                    }
                
            }
            
        }                
        

        $webPageRss["Topics"] = "?-TopicRSS"        
        if ($tutorialLayer.Count) {
            
        } 
        if ($aboutLayer.Count) {
        
        }    
    }
    
}


    
if ($walkthrus) {
    $screenCasts = @()
    $onlineWalkthrus = @()
    $codeWalkThrus = @()
    $webPageRss["Walkthrus"] = "?-WalkthruRSS"        
    foreach ($walkthruName in $walkThrus.Keys) {
        if ($walkThruName -like "*Video*" -or 
            $walkThruName -like "*Screencasts*") {
            $screenCasts +=
                if ($customAnyHandler) {
                    New-Object PSObject -Property @{
                        Caption = $walkThruName.Replace('.walkthru.help.txt', '').Replace('_', ' ')
                        Url = "?Walkthru=" + $walkThruName.Replace('.walkthru.help.txt', '').Replace('_', ' ')
                    }
                } else {
                    New-Object PSObject -Property @{
                        Caption = $walkThruName.Replace('.walkthru.help.txt', '').Replace('_', ' ')
                        Url = $walkThruName.Replace('.walkthru.help.txt', '').Replace('_', ' ') + "/"
                    }
                }
                
        } elseif ($pipeworksManifest.TrustedWalkthrus -contains $walkThruName) {
            $onlineWalkThrus += 
                if ($customAnyHandler) { 
                    New-Object PSObject -Property @{
                        Caption = $walkThruName
                        Url = "?Walkthru=" + $walkThruName
                    }
                } else {
                    New-Object PSObject -Property @{
                        Caption = $walkThruName
                        Url = $walkThruName + "/"
                    }
                }
        } else {
            $codeWalkThrus += 
                if ($customAnyHandler) { 
                    New-Object PSObject -Property @{
                        Caption = $walkThruName
                        Url = "?Walkthru=" + $walkThruName
                    }
                } else {
                    New-Object PSObject -Property @{
                        Caption = $walkThruName
                        Url = $walkThruName + "/"
                    }
                }
        }
        
        
    }

    $realOrder=  @()        
    
    # Topics that have been explicitly called out within a group do not get shown within the sublists
    
    if ($pipeworksManifest.TopicGroup -or $PipeworksManifest.TopicGroups) {
        $topicGroup = if ($pipeworksManifest.TopicGroups) {
            $pipeworksManifest.TopicGroups
        } else {
            $pipeworksManifest.TopicGroup
        }


        $topicGroups = @()

        
        foreach ($tGroup in $topicGroup) {
            if (-not $tGroup) { continue }
            if ($tGroup -isnot [hashtable]) { continue } 
                
            foreach ($key in ($tGroup.Keys | Sort-Object)) {
                
                
                $innerLayers = @{}
                $values = @($tGroup[$key])
                $innerOrder = @()
                foreach ($top in $values) {
                    $tab = if ($walkthrus[$top]) {                                               
                        $params = @{}
                        if ($pipeworksManifest.TrustedWalkthrus -contains $top) {
                            $params['RunDemo'] = $true
                        }
                        if ($pipeworksManifest.WebWalkthrus -contains $top) {
                            $params['OutputAsHtml'] = $true
                        }
                        Write-WalkthruHTML -StepByStep -WalkthruName $top -WalkThru $walkthrus[$top] @params
                    } elseif ($aboutTopics | Where-Object { $_.Name -eq $top })  {
                        $topicMatch = $aboutTopics | Where-Object { $_.Name -eq $top } 
                        ConvertFrom-Markdown -Markdown $topicMatch.Topic -ScriptAsPowerShell
                    }
                        
                    if ($tab) {
                        $innerLayers[$top] = $tab       
                        $innerOrder += $top
                        $namedTopics[$top] = $top
                    }
                }
                    
                $regionLayoutParams = 
                    if ($pipeworksManifest.InnerRegion -as [Hashtable]) {
                        $pipeworksManifest.InnerRegion
                    } else {
                        #The UserAgent based check is to make sure that the default view looks less ugly in Compatibility mode in IE
                        @{
                            AsGrid = $true
                            GridItemWidth = 150
                            GridItemHeight = 96
                            Style = @{
                                "font-size" = if ($request.UserAgent -like "*MSIE 7.0*") { "small"} else {"1.0em"}
                            }
                        }
                    }
                $cmdTabs[$key] = New-Region @regionLayoutParams -LayerID $Key -Layer $innerLayers -Order $innerOrder
                $topicGroups += "$key"
            }
    
        }
        
    
        $realOrder += $topicGroups  
        
        
        # Filter out anything displayed elsewhere
        $screencasts = @($screenCasts | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] }) 
        $onlineWalkthrus = @($onlineWalkthrus | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
        $codeWalkThrus = @($codeWalkThrus | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
        $aboutItems  = @($aboutItems | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
        $tutorialItems = @($tutorialItems  | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
    }


            
        
        
                   
    
}        
#endregion Walkthrus Tab
    

$descriptionArea = 
    "<div style='float:left;width:100%'>$descriptionArea
    </div>
    "


        
if ($request["Snug"]) {
    $MarginPercentLeftString = $MarginPercentRightString = "1%"
}

$socialRow = ($socialRow  |
    New-Region -LayerID 'SocialRow' -Style @{
        "Float" = "Right"        
    }) + $spacingDiv
    


#region Services Tab
    if ($pipeworksManifest -and 
        $pipeworksManifest.WebCommand -and
        $pipeworksManifest.WebCommand -is [Hashtable]) {
        
        $getCommandTab = {
            param($cmd)

            # If the command is Marked Hidden, then it will not be displayed on a web interface.

            if ($pipeworksManifest.WebCommand.$cmd.Hidden) {
                return
            }


            $realCmd = $cmd


            if ($pipeworksManifest.WebAlias.$Cmd) {
                $realCmd = $pipeworksManifest.WebAlias.$cmd.Command
            }




            $resolvedCommand = (Get-Command $realcmd -Module "$($module.Name)" -ErrorAction SilentlyContinue)
            
            if (-not $resolvedCommand) { return }        






            $commandHelp = Get-Help $realCmd -ErrorAction SilentlyContinue | Select-Object -First 1 
            if ($commandHelp.Description) {
                $commandDescription = $commandHelp.Description[0].text
                $commandDescription = $commandDescription -replace "`n", "
<BR/>
"       
            }
            $cmdUrl = "${cmd}/?-widget"
            $hideParameter =@($pipeworksManifest.WebCommand.$realcmd.HideParameter)
            $cmdOptions = $pipeworksManifest.WebCommand.$realcmd


            if ($pipeworksManifest.WebAlias.$cmd) {
                foreach ($kv in ($pipeworksManifest.WebAlias.$cmd).GetEnumerator()) {
                    if (-not $kv) {
                        continue
                    }
                    if ($kv.Key -eq 'Command') { continue } 
                    $cmdOptions[$kv.Key] = $kv.Value
                }
            }




            
            $cmdFriendlyName = if ($pipeworksManifest.WebCommand.$realcmd.FriendlyName) {
                $pipeworksManifest.WebCommand.$realcmd.FriendlyName
            } else {
                $realCmd
            }   
            $cmdIsVisible = $true
            if ($pipeworksManifest.WebCommand.$realcmd.IfLoggedInAs -or $pipeworksManifest.WebCommand.$realcmd.ValidUserPartition) {
                $confirmParams = @{
                    IfLoggedInAs = $pipeworksManifest.WebCommand.$realcmd.IfLoggedInAs
                    ValidUserPartition = $pipeworksManifest.WebCommand.$realcmd.ValidUserPartition
                    CheckId = $true
                    WebsiteUrl = $finalUrl
                }
                $cmdIsVisible = . Confirm-Person @confirmParams
            }
            if ($cmdIsVisible) {

                    $commandaction = 
                        if ($customAnyHandler) {
                            "?Command=$realcmd"
                        } else {
                            "$realcmd/"
                        }

            "
<div style='padding:20px'>
<div style='text-align:right'>
$(Write-Link -CssClass 'ui-icon-help' -Button -Caption '<span class="ui-icon ui-icon-help"></span>' -Url "${realcmd}/-?")
</div>

<p>
$(ConvertFrom-markdown -markdown "$commandDescription ")
</p>
</div>

<div id='${cmd}_container' style='padding:20px'>
$(
if ($cmdOptions.RequireLogin -and (-not $session['User'])) {    
    $confirmHtml = . Confirm-Person -WebsiteUrl $finalUrl
    # Localize Content Here
    '<span style="margin-top:%" class=''ui-state-error''>You have to log in first </span>'  + $confirmHtml   
} elseif ($cmdOptions.RunWithoutInput) {
    $extraParams = @{} + $cmdOptions
    if ($pipeworksManifest -and $pipeworksManifest.Style -and (-not $extraParams.Style)) {
        $extraParams.Style = $pipeworksManifest.Style 
    }
    if ($extraParams.Count -gt 1) {
        # Very explicitly make sure it's there, and not explicitly false
        if (-not $extra.RunOnline -or 
            $extraParams.Contains("RunOnline") -and $extaParams.RunOnline -ne $false) {
            $extraParams.RunOnline = $true                     
        }                
    } 
            
    if ($extaParams.PipeInto) {
        $extaParams.RunInSandbox = $true
    }
            
    if (-not $extraParams.AllowDownload) {
        $extraParams.AllowDownload = $allowDownload
    }
            
    if ($extraParams.RunOnline) {
        # Commands that can be run online
        $webCmds += $command.Name
    }
            
    if ($extraParams.RequireAppKey -or $extraParams.RequireLogin -or $extraParams.IfLoggedAs -or $extraParams.ValidUserPartition) {
        $extraParams.UserTable = $pipeworksManifest.Usertable.Name
        $extraParams.UserPartition = $pipeworksManifest.Usertable.Partition
        $extraParams.StorageAccountSetting = $pipeworksManifest.Usertable.StorageAccountSetting
        $extraParams.StorageKeySetting = $pipeworksManifest.Usertable.StorageKeySetting 
    }
    
    
    
    Invoke-Webcommand -Command $resolvedCommand @extraParams -AnalyticsId "$AnalyticsId" -AdSlot "$AdSlot" -AdSenseID "$AdSenseId" -ServiceUrl $finalUrl 2>&1
    
} else {
    $useAjax = 
        if ($pipeworksManifest.NoAjax -or $cmdOptions.ContentType -or $cmdOptions.RedirectTo -or $cmdOptions.PlainOutput) {
            $false
        } else {
            $true
        }
    Request-CommandInput -Action "$commandaction" -CommandMetaData (Get-Command $realcmd -Module "$($module.Name)") -DenyParameter $hideParameter -Ajax:$useAjax 
})            
</div>" 
            }            
        }

        
        

        if ($pipeworksManifest.Group -or $pipeworksManifest.Groups) {
            $groups = @()

            $groupInfo = if ($pipeworksManifest.Group) {
                $pipeworksManifest.Group
            } else {
                $pipeworksManifest.Groups
            }

            foreach ($grp in $groupInfo ) {
                if (-not $grp) { continue } 
                if ($grp -isnot [hashtable]) { continue } 
                foreach ($key in ($grp.Keys | Sort-Object)) {
                    $innerLayers = @{}
                    $values = @($grp[$key])
                    $innerOrder = @()
                    foreach ($cmd in $values) {
                        $top = $cmd                    
                        $tab = 
                            if ($walkthrus[$top]) {                                               
                                $cmdFriendlyName = $top
                                $namedtopics[$top] = $top
                                $params = @{}
                                if ($pipeworksManifest.TrustedWalkthrus -contains $top) {
                                    $params['RunDemo'] = $true
                                }
                                if ($pipeworksManifest.WebWalkthrus -contains $top) {
                                    $params['OutputAsHtml'] = $true
                                }
                                Write-WalkthruHTML -StepByStep -WalkthruName $top -WalkThru $walkthrus[$top] @params
                            } elseif ($aboutTopics | Where-Object { $_.Name -eq $top })  {
                                $cmdFriendlyName= $top
                                $namedtopics[$top] = $top
                                $topicMatch = $aboutTopics | Where-Object { $_.Name -eq $top } 
                                ConvertFrom-Markdown -Markdown $topicMatch.Topic -ScriptAsPowerShell
                            } else {
                                . $getCommandTab $cmd 
                            }
                        
                        if ($tab) {
                            $innerLayers[$cmdFriendlyName] = $tab       
                            $innerOrder += $cmdFriendlyName
                        }
                    }
                    
                    $regionLayoutParams = 
                        if ($pipeworksManifest.InnerRegion -as [Hashtable]) {
                            $pipeworksManifest.InnerRegion
                        } else {
                            @{
                                AsGrid = $true
                                GridItemWidth = 150
                                GridItemHeight = 96
                                Style = @{
                                "font-size" = if ($request.UserAgent -like "*MSIE 7.0*") { "small"} else {"1.0em"}
                                }
                            }
                        }

                    $cmdTabs[$key] = New-Region @regionLayoutParams  -LayerID $Key -Layer $innerLayers -Order $innerOrder
                    $groups += "$key"                                        
                }
                
            }
            $realOrder += $groups
            # Filter out anything displayed elsewhere
            $screencasts = @($screenCasts | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] }) 
            $onlineWalkthrus = @($onlineWalkthrus | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
            $codeWalkThrus = @($codeWalkThrus | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
            $aboutItems  = @($aboutItems | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )
            $tutorialItems = @($tutorialItems  | Where-Object { $_.Caption -and -not $namedtopics[$_.Caption] } )


        } elseif ($pipeworksManifest.CommandGroup) {
            $commandGroup = $pipeworksManifest.CommandGroup

            $cmdGroups = @()
            foreach ($cmdgroup in $commandGroup) {
                if (-not $cmdgroup) { continue }
                if ($cmdgroup -isnot [hashtable]) { continue } 

                
                foreach ($key in ($cmdgroup.Keys | Sort-Object)) {
                    
                    $innerLayers = @{}
                    $values = @($cmdGroup[$key])
                    $innerOrder = @()
                    foreach ($cmd in $values) {
                        $tab = . $getCommandTab $cmd

                        
                        if ($tab) {
                            $innerLayers[$cmdFriendlyName] = $tab       
                            $innerOrder += $cmdFriendlyName
                        }
                    }
                    
                    $regionLayoutParams = 
                        if ($pipeworksManifest.InnerRegion -as [Hashtable]) {
                            $pipeworksManifest.InnerRegion
                        } else {
                            @{
                                AsGrid = $true
                                GridItemWidth = 150
                                GridItemHeight = 96
                                Style = @{
                                "font-size" = if ($request.UserAgent -like "*MSIE 7.0*") { "small"} else {"1.0em"}
                                }
                            }
                        }

                    $cmdTabs[$key] = New-Region @regionLayoutParams  -LayerID $Key -Layer $innerLayers -Order $innerOrder
                    $cmdGroups += "$key"
                }
            }
            
            $realOrder += $cmdGroups  
        } else { 
            $commandOrder = if ($pipeworksManifest.CommandOrder) {
                $pipeworksManifest.CommandOrder
            } else {
                $pipeworksManifest.WebCommand.Keys | Sort-Object
            }

        
        

            
            foreach ($cmd in $commandOrder) {            
            
                $tab = . $getCommandTab $cmd
                if ($tab) {
                    $cmdTabs[$cmdFriendlyName] = $tab 
                    $realOrder += $cmdFriendlyName
                }
                
        
            }
            
        }                
    }
    
    

    $screenCastSection = if ($screenCasts) {
        $subTopics.Layer."Videos"  = @"
<p class='ModuleWalkthruExplanation'>
        
Watch these videos to get started:

$($ScreenCasts |
    Sort-Object Caption | 
    Write-Link -AsList)
</p>
"@
    } else {
        ""
    }
    
    $onlineWalkthruSection = if ($onlineWalkthrus) {
        $subTopics.Layer."Demos" = @"
<p class='ModuleWalkthruExplanation'>
        
See each step, and see each step's results.

$($OnlineWalkthrus| 
    Write-Link -AsList |
    Sort-Object Caption)
</p>
"@
    } else {
        ""
    }
    
    $codeWalkthruSection = if ($codeWalkThrus) {
        
        $subTopics.Layer."Walkthrus" = @"
<p class='ModuleWalkthruExplanation'>
        
See the code step by step.

$($CodeWalkthrus |  
    Sort-Object Caption |
    Write-Link -AsList)
</p>
"@
    } else {
        ""
    } 
    
    if ($aboutItems -or $tutorialItems) {
        $subTopics.Layer."More About $Module" = @"
<p class='ModuleWalkthruExplanation'>
        


$($aboutItems + $tutorialItems |  
    Sort-Object Caption |
    Write-Link -AsList)
</p>

"@                
    }
    
    $learnMore = if ($subtopics.Layer.Count) {
        foreach ($layerName in "More About $module", "Videos", "Walkthrus", "Demos") {
            if( $subtopics.Layer.$layerName) {
                $realOrder += $layerName
                if (-not $cmdTabs) {
                    $cmdTabs = @{}
                }
                $cmdTabs[$layerName] = $subtopics.Layer.$layerName
            }
        } 
        
        
        
        
        
        ""
    } else {
        ""
    }
    


    
    if ($AllowDownload) {
        $layerName = "Download"
        $cmdTabs[$layerName] = " "

        if ($request.Url.ToString() -like "*Module.ashx") {
            $cmdLinks += @{Download="?-DownloadNow"}
        } else {
            $cmdLinks += @{Download="Module.ashx?-DownloadNow"}
        }
        


        $realOrder += "Download"
    }
    
    $regionLayoutParams = if ($pipeworksManifest.MainRegion -as [hashtable]) {
        $pipeworksManifest.MainRegion
    } else {
        @{AsGrid=$true}
    }
    $rest = New-Region -LayerID Items -Layer $cmdTabs -order $realOrder @regionLayoutParams -LayerUrl $cmdUrls -layerLink $cmdLinks

    #endregion Services Tab
    

$defaultCommandSection  = if ($pipeworksManifest.DefaultCommand) {
    $defaultCmd = @($ExecutionContext.InvokeCommand.GetCommand($pipeworksManifest.DefaultCommand.Name, "All"))[0]
    
    $defaultCmdParameter = if ($pipeworksManifest.DefaultCommand.Parameter) {
        $pipeworksManifest.DefaultCommand.Parameter
    } else {
        @{}
    }
    
    $cmdOutput = & $defaultcmd @defaultCmdParameter
    
    if ($pipeworksManifest.DefaultCommand.GroupBy) {
        $defaulItem  =""
        $CmdOutputGrouped = $cmdOutput | 
            Group-Object $pipeworksManifest.DefaultCommand.GroupBy |
            Foreach-Object -Begin {
                $groupedLayers = @{}
                $asStyle = if ($pipeworksManifest.DefaultCommand.DisplayAs) {
                    "As$($pipeworksManifest.DefaultCommand.DisplayAs)"
                } else {
                    "AsSlideshow"
                }
            } {
                if (-not $defaulItem ) {
                    $defaultItem = $_.Name
                } 
                
                $groupedLayers[$_.Name] = $_.Group | Out-HTML
            } -End {
                $asStyleParam = @{
                    $AsStyle = $true
                }
                New-Region  -Default $defaultItem -Layer $groupedLayers -LayerID DefaultcommandSection @asStyleParam 
            }
        $cmdOutputGrouped
    } else {
        $cmdOutput | Out-Html
    }
} else {
    ""
}

$bottomBannerSlot = 
    if ($pipeworksManifest.Advertising -and $pipeworksManifest.Advertising.BottomAdSlot) {    "
        <p style='text-align:center'>
        <script type='text/javascript'>
        <!--
        google_ad_client = 'ca-pub-$($pipeworksManifest.Advertising.AdSenseId)';
        /* AdSense Banner */
        google_ad_slot = '$($pipeworksManifest.Advertising.BottomAdSlot)';
        google_ad_width = 728;
        google_ad_height = 90;
        //-->
        </script>
        <script type='text/javascript'
        src='http://pagead2.googlesyndication.com/pagead/show_ads.js'>
        </script>
        </p>"   
    } elseif ($pipeworksManifest.AdSense -and $PipeworksManifest.AdSense.BottomAdSlot) {
    
        if ($PipeworksManifest.AdSense.BottomAdSlot -like "*/*") {
            $slotAdSenseId = $pipeworksManifest.AdSense.BottomAdSlot.Split("/")[0]
            $slotAdSlot =  $pipeworksManifest.AdSense.BottomAdSlot.Split("/")[1]
        } elseif ($pipeworksManifest.AdSense.Id) {
            $slotAdSenseId = $pipeworksManifest.AdSense.Id
            $slotAdSlot = $PipeworksManifest.AdSense.BottomAdSlot
        }
        
        "<p style='text-align:center'>
        <script type='text/javascript'>
        <!--
        google_ad_client = 'ca-pub-$($slotAdSenseId)';
        /* AdSense Banner */
        google_ad_slot = '$($slotAdSlot)';
        google_ad_width = 728;
        google_ad_height = 90;
        //-->
        </script>
        <script type='text/javascript'
        src='http://pagead2.googlesyndication.com/pagead/show_ads.js'>
        </script>
        </p>"    
    } else {
        ""
    }


$upperBannerSlot = 
    if ($pipeworksManifest.Advertising -and $pipeworksManifest.Advertising.UpperAdSlot) {
        "<p style='text-align:center'>
<script type='text/javascript'>
<!--
google_ad_client = 'ca-pub-$($pipeworksManifest.Advertising.AdSenseId)';
/* AdSense Banner */
google_ad_slot = '$($pipeworksManifest.Advertising.UpperAdSlot)';
google_ad_width = 728;
google_ad_height = 90;
//-->
</script>
<script type='text/javascript'
src='http://pagead2.googlesyndication.com/pagead/show_ads.js'>
</script>
</p>"
    } elseif ($pipeworksManifest.AdSense -and $PipeworksManifest.AdSense.TopAdSlot) {
        if ($PipeworksManifest.AdSense.TopAdSlot -like "*/*") {
            $slotAdSenseId = $pipeworksManifest.AdSense.TopAdSlot.Split("/")[0]
            $slotAdSlot =  $pipeworksManifest.AdSense.TopAdSlot.Split("/")[1]
        } elseif ($pipeworksManifest.AdSense.Id) {
            $slotAdSenseId = $pipeworksManifest.AdSense.Id
            $slotAdSlot = $PipeworksManifest.AdSense.TopAdSlot 
        }
        "<p style='text-align:center'>
<script type='text/javascript'>
<!--
google_ad_client = 'ca-pub-$($slotAdSenseId)';
/* AdSense Banner */
google_ad_slot = '$($slotAdSlot)';
google_ad_width = 728;
google_ad_height = 90;
//-->
</script>
<script type='text/javascript'
src='http://pagead2.googlesyndication.com/pagead/show_ads.js'>
</script>
</p>"  
    
    
} else {
    ""
}

$brandingSlot = 
    if ($pipeworksManifest.Branding) {
        if ($pipeworksManifest.Branding) {
            
            ConvertFrom-Markdown $pipeworksManifest.Branding
                      
        } else {
            ""
        }
    } else {
@"
<div style='font-size:.75em;text-align:right'>
Powered With 
<a href='http://powershellpipeworks.com'>
<img src='http://powershellpipeworks.com/assets/powershellpipeworks_tile.png' align='middle' width='60' height='60' border='0' />
</a>
</div>
"@        

    
    }
    

$OrgInfoSlot = if ($pipeworksManifest.Organization) {
    $orgText = ""
    if ($pipeworksManifest.Organization.Telephone) {
        $orgText  += ($pipeworksManifest.Organization.Telephone -join ' | ') + "<BR/>"        
    }
    $orgText
} else {
    ""
}

$socialRow + $titleArea + $descriptionArea + 
    "<div style='clear:both;margin-top:1%'></div>" +
    "<div style='clear:both;'></div>" + 
    "<div style='float:right;'>$OrgInfoSlot</div>" +
    "<div style='clear:both;margin-top:1%'></div>" +
    ($spacingDiv * 4) +
    "<div style='margin-top:1%'>$topicHtml</div>" +   
    "<div style='clear:both;margin-top:1%'>$upperBannerSlot</div>" +
    "<div style='clear:both;margin-top:1%'>$defaultCommandSection</div>" +
    "<div style='clear:both;margin-top:3%'></div>" +
    $rest +
    "<div style='clear:both;margin-top:1%'>$bottomBannerSlot</div>" +
    "<div style='float:right;margin-top:15%'>$brandingSlot</div>" |
    
    New-Region -Style @{
        "Margin-Left" = $MarginPercentLeftString
        "Margin-Right" = $MarginPercentRightString
    } |
    New-WebPage -NoCache -UseJQueryUI -Title $module.Name -Description $module.Description -Rss $webPageRss|
    Out-HTML -WriteResponse 
    return
    

}.ToString().Replace('"', '""') + @"
}
", context, null, false, $((-not $IsolateRunspace).ToString().ToLower()));
"@
        
        $moduleAshxInsteadOfDefault = $psBoundParameters.StartOnCommand -or $psBoundParameters.AsBlog
        
        if ($pipeworksManifest.AcceptanyUrl) {
            $AcceptAnyUrl= $true
        } 

        if ($pipeworksManifest.DomainSchematics -and -not $PipeworksManifest.Stealth) {
            $firstdomain  = $pipeworksManifest.DomainSchematics.GetEnumerator() | Sort-Object Key | Select-Object -First 1 -ExpandProperty Key
            $firstdomain  = $firstdomain  -split "\|" | ForEach-Object { $_.Trim() } | Select-Object -First 1

            $x = & $NewSiteMap "http://$firstdomain"
            $x.Save("$outputDirectory\sitemap.xml")
        }
        

        #region Module Output
        $newDefaultExtensions  = Get-ChildItem $outputDirectory -Filter default.* | Select-Object -ExpandProperty Extension
        $defaultFile = if ($newDefaultExtensions -contains '.aspx') {
            $null
            
            & $writeSimpleHandler -PoolSize:$PoolSize -sharerunspace:(-not $isolateRunspace) -csharp $moduleHandler | 
                Set-Content "$outputDirectory\Module.ashx"
        } elseif ($newDefaultExtensions -contains '.html') { 
            "default.html"
            if (-not $psBoundParameters.StartOnCommand) {
                & $writeSimpleHandler -csharp $moduleHandler | 
                    Set-Content "$outputDirectory\Default.ashx" -PassThru |
                    Set-Content "$outputDirectory\Module.ashx" 
            }
        } elseif ($newDefaultExtensions -contains '.ashx') {
            "default.ashx"
            if (-not $psBoundParameters.StartOnCommand) {
                & $writeSimpleHandler -PoolSize:$PoolSize -sharerunspace:(-not $isolateRunspace) -csharp $moduleHandler | 
                    Set-Content "$outputDirectory\Default.ashx" -PassThru |
                    Set-Content "$outputDirectory\Module.ashx" 
            }
        } else {
        
            if ($AcceptAnyUrl) {
                $null
            } else {
                "default.ashx"
            }
            if (-not $psBoundParameters.StartOnCommand) {
                & $writeSimpleHandler -PoolSize:$PoolSize -sharerunspace:(-not $isolateRunspace) -csharp $moduleHandler | 
                    Set-Content "$outputDirectory\Default.ashx" -PassThru |
                    Set-Content "$outputDirectory\Module.ashx" 
            }
        }
        
        if ($moduleAshxInsteadOfDefault) {
            if ($psBoundParameters.StartOnCommand) {
                Copy-Item "$outputDirectory\$StartOnCommand\Default.ashx" "$outputDirectory\Default.ashx"
            } elseif ($psBoundParameters.AsBlog) {
                Copy-Item "$outputDirectory\Blog.html" "$outputDirectory\Default.htm"
            }
            & $writeSimpleHandler -PoolSize:$PoolSize -sharerunspace:(-not $isolateRunspace) -csharp $moduleHandler | 
                Set-Content "$outputDirectory\Module.ashx"
        }
                
        #endregion Module Output
        
        #region Configuration Settings          
        $configSettingsChunk = ''
                
        if ($ConfigSetting.Count) {
             $configSettingsChunk = "<appSettings>" + (@(foreach ($kv in $configSetting.GetEnumerator()) {"
        <add key='$($kv.Key)' value='$($kv.Value)'/>"                
             }) -join ('')) + "</appSettings>"
        }
        
        $acceptAnyUrl = $true                   
        
        $runTimeChunk  ="
<httpRuntime 
executionTimeout='90' 
maxRequestLength='16384' 
useFullyQualifiedRedirectUrl='false'
appRequestQueueLimit='100'
enableVersionHeader='true' />"                           
        
        $rewriteUrlChunk = "<rewrite>
            <rules>
                <rule name='RewriteAll_For$($psBoundParameters.Name)'>
                    <match url='.*' />
                    <conditions logicalGrouping='MatchAll'>
                        <add input='{URL}' pattern='^.*\.(ashx|axd|css|gif|png|ico|jpg|jpeg|js|flv|f4v|zip|xlsx|docx|mp3|mp4|xml|html|htm|aspx|php)$' negate='true' />
                        <add input='{REQUEST_FILENAME}' matchType='IsDirectory' negate='true' />
                    </conditions>

                    <action type='Rewrite' url='AnyUrl.aspx' />
                </rule>
            </rules>
        </rewrite>"
       
        if (-not $AcceptAnyUrl) {

            $rewriteUrlChunk = ""
        } else {
            if (-not (Test-Path "$outputDirectory\AnyUrl.aspx")) {
                $rewriteUrlChunk = $rewriteUrlChunk.Replace("AnyUrl.aspx", "Module.ashx?AnythingGoes=true")
            }
        }
        # $rewriteUrlChunk= ""

        $defaultFound = (
            (Join-Path (Split-Path $OutputDirectory) "web.config") | 
                Get-Content -path  { $_ } -ErrorAction SilentlyContinue | 
                Select-String defaultDocument
            ) -as [bool]

        
        $defaultDocumentChunk = if ((-not ($defaultFile))) {
@"    
    <system.webServer>
        $(if (-not $defaultFound) { @"
<defaultDocument>
            <files>
                <add value="default.ashx" />
            </files>
        </defaultDocument>
"@})
        $rewriteUrlChunk
    </system.webServer>
        
"@        
        }  else {
@"
    <system.webServer>
        $(if (-not $defaultFound) { @"
        <defaultDocument>
            <files>
                <add value="${defaultFile}" />
            </files>
        </defaultDocument>
"@})
        $rewriteUrlChunk
        
    </system.webServer>
"@
        }
        
                           
    
@"
<configuration>
    $ConfigSettingsChunk
    $defaultDocumentChunk 
    $net4Compat
    <system.web>
        <customErrors mode='Off' />        
        
    </system.web>
</configuration>
"@ |
        Set-Content "$outputDirectory\web.config" 
        
        
    if ($AsIntranetSite) {
        Import-Module WebAdministration -Global -Force
        $allSites = Get-Website
        
        $AlreadyExists = $allSites |
            Where-Object {$_.Name -eq "$Name" } 
            
        if (-not $alreadyExists) {
            $targetPort = $Port
            $portIsOccupied  = $null
            do {
                if (-not $targetPort) {
                    $targetPort = 80
                } else {
                    $oldTargetPort = $targetPort
                    if ($portIsOccupied) {
                        $targetPort = Get-Random -Maximum 64kb
                        Write-Warning "Port $oldTargetPort occupied, trying Port $targetPort"
                    }
                }

                $portIsOccupied = Get-Website | 
                    Where-Object { 
                        $_.Bindings.Collection | 
                            Where-Object { 
                                $_-like "*:$targetPort*" 
                            }  
                        }                    
            }
            while ($portIsOccupied) 
           
            $w = New-Website -Name "$Name" -Port $targetPort -PhysicalPath $outputDirectory -Force
            
            $AlreadyExists = Get-Website |
                Where-Object {$_.Name -eq "$Name" } 

            
        }
        Set-WebConfigurationProperty -filter /system.webServer/security/authentication/anonymousAuthentication -name enabled -value false -PSPath IIS:\ -Location $Name
        Set-WebConfigurationProperty -filter /system.webServer/security/authentication/windowsAuthentication -name enabled -value true -PSPath IIS:\ -Location $Name
    
        if ($appPoolCredential) {
            $appPool = Get-Item "IIS:\AppPools\${name}AppPool" -ErrorAction SilentlyContinue 
            if (-not $appPool) {
                $pool = New-WebAppPool -Name "${name}AppPool" -Force
                $appPool = Get-Item "IIS:\AppPools\${name}AppPool" -ErrorAction SilentlyContinue 
           
            }
            $appPool.processModel.userName = $appPoolCredential.username
            $appPool.processModel.password = $appPoolCredential.GetNetworkCredential().password
            $appPool.processModel.identityType = 3
            $appPool | Set-Item
        
        }        
    }
#region Global.asax Session Cleanup
@'
<%@ Assembly Name="System.Management.Automation, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" %>
<script language="C#" runat="server">
public void Session_OnEnd()
{
    System.Management.Automation.Runspaces.Runspace rs = Session["User_Runspace"] as System.Management.Automation.Runspaces.Runspace;
    if (rs != null)
    {
        rs.Close();
        rs.Dispose();
    }
    System.GC.Collect();
}
</script>
'@ |         Set-Content "$outputDirectory\Global.asax" 

    
#endregion

        }
        Pop-Location       
        #endregion Configuration Settings               
    }
}
# SIG # Begin signature block
# MIINGAYJKoZIhvcNAQcCoIINCTCCDQUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUDnjPT+TA6zi9fWzK9hmCF9cb
# lCmgggpaMIIFIjCCBAqgAwIBAgIQAupQIxjzGlMFoE+9rHncOTANBgkqhkiG9w0B
# AQsFADByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFz
# c3VyZWQgSUQgQ29kZSBTaWduaW5nIENBMB4XDTE0MDcxNzAwMDAwMFoXDTE1MDcy
# MjEyMDAwMFowaTELMAkGA1UEBhMCQ0ExCzAJBgNVBAgTAk9OMREwDwYDVQQHEwhI
# YW1pbHRvbjEcMBoGA1UEChMTRGF2aWQgV2F5bmUgSm9obnNvbjEcMBoGA1UEAxMT
# RGF2aWQgV2F5bmUgSm9obnNvbjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
# ggEBAM3+T+61MoGxUHnoK0b2GgO17e0sW8ugwAH966Z1JIzQvXFa707SZvTJgmra
# ZsCn9fU+i9KhC0nUpA4hAv/b1MCeqGq1O0f3ffiwsxhTG3Z4J8mEl5eSdcRgeb+1
# jaKI3oHkbX+zxqOLSaRSQPn3XygMAfrcD/QI4vsx8o2lTUsPJEy2c0z57e1VzWlq
# KHqo18lVxDq/YF+fKCAJL57zjXSBPPmb/sNj8VgoxXS6EUAC5c3tb+CJfNP2U9vV
# oy5YeUP9bNwq2aXkW0+xZIipbJonZwN+bIsbgCC5eb2aqapBgJrgds8cw8WKiZvy
# Zx2qT7hy9HT+LUOI0l0K0w31dF8CAwEAAaOCAbswggG3MB8GA1UdIwQYMBaAFFrE
# uXsqCqOl6nEDwGD5LfZldQ5YMB0GA1UdDgQWBBTnMIKoGnZIswBx8nuJckJGsFDU
# lDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwdwYDVR0fBHAw
# bjA1oDOgMYYvaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL3NoYTItYXNzdXJlZC1j
# cy1nMS5jcmwwNaAzoDGGL2h0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9zaGEyLWFz
# c3VyZWQtY3MtZzEuY3JsMEIGA1UdIAQ7MDkwNwYJYIZIAYb9bAMBMCowKAYIKwYB
# BQUHAgEWHGh0dHBzOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwgYQGCCsGAQUFBwEB
# BHgwdjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tME4GCCsG
# AQUFBzAChkJodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRTSEEy
# QXNzdXJlZElEQ29kZVNpZ25pbmdDQS5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG
# 9w0BAQsFAAOCAQEAVlkBmOEKRw2O66aloy9tNoQNIWz3AduGBfnf9gvyRFvSuKm0
# Zq3A6lRej8FPxC5Kbwswxtl2L/pjyrlYzUs+XuYe9Ua9YMIdhbyjUol4Z46jhOrO
# TDl18txaoNpGE9JXo8SLZHibwz97H3+paRm16aygM5R3uQ0xSQ1NFqDJ53YRvOqT
# 60/tF9E8zNx4hOH1lw1CDPu0K3nL2PusLUVzCpwNunQzGoZfVtlnV2x4EgXyZ9G1
# x4odcYZwKpkWPKA4bWAG+Img5+dgGEOqoUHh4jm2IKijm1jz7BRcJUMAwa2Qcbc2
# ttQbSj/7xZXL470VG3WjLWNWkRaRQAkzOajhpTCCBTAwggQYoAMCAQICEAQJGBtf
# 1btmdVNDtW+VUAgwDQYJKoZIhvcNAQELBQAwZTELMAkGA1UEBhMCVVMxFTATBgNV
# BAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIG
# A1UEAxMbRGlnaUNlcnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTEzMTAyMjEyMDAw
# MFoXDTI4MTAyMjEyMDAwMFowcjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lD
# ZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTExMC8GA1UEAxMoRGln
# aUNlcnQgU0hBMiBBc3N1cmVkIElEIENvZGUgU2lnbmluZyBDQTCCASIwDQYJKoZI
# hvcNAQEBBQADggEPADCCAQoCggEBAPjTsxx/DhGvZ3cH0wsxSRnP0PtFmbE620T1
# f+Wondsy13Hqdp0FLreP+pJDwKX5idQ3Gde2qvCchqXYJawOeSg6funRZ9PG+ykn
# x9N7I5TkkSOWkHeC+aGEI2YSVDNQdLEoJrskacLCUvIUZ4qJRdQtoaPpiCwgla4c
# SocI3wz14k1gGL6qxLKucDFmM3E+rHCiq85/6XzLkqHlOzEcz+ryCuRXu0q16XTm
# K/5sy350OTYNkO/ktU6kqepqCquE86xnTrXE94zRICUj6whkPlKWwfIPEvTFjg/B
# ougsUfdzvL2FsWKDc0GCB+Q4i2pzINAPZHM8np+mM6n9Gd8lk9ECAwEAAaOCAc0w
# ggHJMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MIGBBgNVHR8E
# ejB4MDqgOKA2hjRodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1
# cmVkSURSb290Q0EuY3JsMDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsME8GA1UdIARIMEYwOAYKYIZIAYb9
# bAACBDAqMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BT
# MAoGCGCGSAGG/WwDMB0GA1UdDgQWBBRaxLl7KgqjpepxA8Bg+S32ZXUOWDAfBgNV
# HSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzANBgkqhkiG9w0BAQsFAAOCAQEA
# PuwNWiSz8yLRFcgsfCUpdqgdXRwtOhrE7zBh134LYP3DPQ/Er4v97yrfIFU3sOH2
# 0ZJ1D1G0bqWOWuJeJIFOEKTuP3GOYw4TS63XX0R58zYUBor3nEZOXP+QsRsHDpEV
# +7qvtVHCjSSuJMbHJyqhKSgaOnEoAjwukaPAJRHinBRHoXpoaK+bp1wgXNlxsQyP
# u6j4xRJon89Ay0BEpRPw5mQMJQhCMrI2iiQC/i9yfhzXSUWW6Fkd6fp0ZGuy62ZD
# 2rOwjNXpDd32ASDOmTFjPQgaGLOBm0/GkxAG/AeB+ova+YJJ92JuoVP6EpQYhS6S
# kepobEQysmah5xikmmRR7zGCAigwggIkAgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUw
# EwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20x
# MTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcg
# Q0ECEALqUCMY8xpTBaBPvax53DkwCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFBDPl65rCxt4901V
# gHL0FssStxjvMA0GCSqGSIb3DQEBAQUABIIBAAPZpO+Zpi2/rsP2QoDEsMDhHtZf
# y4qNuMnb7OmDLAfVHGIqxDguK8szu7hPvDpI7xraHqg6luWZSRwG1EmP+IfLDf1c
# jP884PkXgJmXiI3ZnuY8DsEtZRIF+SteXl+OrW/gue2F5HnzzofbYwccJfaVEvxg
# aVuJqZ9sHzuWyn7gykUg2OM5LFusQOyzNo511sWITbcZuK9ofTPWEpu41pHMBZf+
# Cuxw2g0Jq2Ya9TqFTNearLFjjvdrh6EhRLbdG0Fi86auNz77bXbHFAfm2WpY+Eq6
# SOkoD7S/B0aRN2a0s8r2LQJXS3iaPohwV+NGJKal4Hpcr0IKnS7rIXHZcEk=
# SIG # End signature block
