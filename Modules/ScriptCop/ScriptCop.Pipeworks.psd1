@{
    WebCommand = @{
        "Test-Command" = @{
            HideParameter = "Command"
            RunOnline=$true
            FriendlyName = "Test a Command"
        }
        "Get-ScriptCopRule" = @{
            RunWithoutInput = $true
            RunOnline=$true
            FriendlyName = "ScriptCop Rules"
        }
        "Get-ScriptCopPatrol" = @{
            RunWithoutInput = $true
            RunOnline=$true
            FriendlyName = "ScriptCop Patrols"
        }
    }
    JQueryUITheme = 'Smoothness'
    AnalyticsId = 'UA-24591838-3'
    CommandOrder = "Test-Command", 
        "Get-ScriptCopRule", 
        "Get-ScriptCopPatrol"    
        
    Style = @{
        Body = @{
            'Font' = "14px/2em 'Rockwell', 'Verdana', 'Tahoma'"                                    
            
        }        
    }
    Logo = '/ScriptCop_125_125.png'
    AddPlusOne = $true
    TwitterId = 'jamesbru'
    Facebook = @{
        AppId = '250363831747570'
    }
    
    DomainSchematics = @{
        "Test-Command.com | www.Test-Command.com | ScriptCop.Start-Automating.com | Scriptcop.StartAutomating.com" = 
            "Default"        
    }

    AdSense = @{
        Id = '7086915862223923'
        BottomAdSlot = '6352908833'
    }


    PubCenter = @{
        ApplicationId = "9be78ae9-fd79-428a-a325-966034e35715"
        BottomAdUnit = "10049443"
    }


    Win8 = @{
        Identity = @{
            Name="Start-Automating.ScriptCop"
            Publisher="CN=3B09501A-BEC0-4A17-8A3D-3DAACB2346F3"
            Version="1.0.0.0"
        }
        Assets = @{
            "splash.png" = "/ScriptCop_Splash.png"
            "smallTile.png" = "/ScriptCop_Small.png"
            "wideTile.png" = "/ScriptCop_Wide.png"
            "storeLogo.png" = "/ScriptCop_Store.png"
            "squaretile.png" = "/ScriptCop_Tile.png"
        }
        ServiceUrl = "http://ScriptCop.start-automating.com"

        Name = "ScriptCop"

    }
    
    AllowDownload = $true

    Branding = @'
<div style='font-size:.75em;text-align:right'>
Provided By 
<a href='http://start-automating.com' >
<img src='http://start-automating.com/Assets/StartAutomating_Tile.png' align='middle' width='60' height='60' border='0' />
</a> <br/>
Powered With 
<a href='http://powershellpipeworks.com'>
<img src='http://powershellpipeworks.com/assets/powershellpipeworks_tile.png' align='middle' width='60' height='60' border='0' />
</a>
</div>
'@
}