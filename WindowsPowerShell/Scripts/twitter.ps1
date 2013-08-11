[System.Reflection.Assembly]::LoadWithPartialName(”System.Web") `
| Out-Null


function Publish-Tweet([string] $TweetText, [string] $Username, [string] $Password)
{ 
[System.Net.ServicePointManager]::Expect100Continue = $false
  $request = [System.Net.WebRequest]::Create("http://twitter.com/statuses/update.xml")
  $request.Credentials = new-object System.Net.NetworkCredential($Username, $Password)
  $request.Method = "POST"
  $request.ContentType = "application/x-www-form-urlencoded" 
  write-progress "Tweeting" "Posting status update" -cu $tweetText

  $formdata = [System.Text.Encoding]::UTF8.GetBytes( "status="  + $tweetText  )
  $requestStream = $request.GetRequestStream()
    $requestStream.Write($formdata, 0, $formdata.Length)
  $requestStream.Close()
  $response = $request.GetResponse()

  write-host $response.statuscode 
  $reader = new-object System.IO.StreamReader($response.GetResponseStream())
     $reader.ReadToEnd()
  $reader.Close()
}


Function Get-TwitterSearch { 
 Param($searchTerm="PowerShell", [switch]$Deep) 
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $searchTerm="PowerShell" 
 $results=[xml]($webClient.DownloadString("http://search.twitter.com/search.rss?rpp=100&page=1&q=$SearchTerm").replace("item","RssItem"))
#lang:      restricts tweets to the given language, given by an ISO 639-1 code
#rpp:       Results per page, (max 100) 
#page:      the page number (starting at 1) to return, up to a max of roughly 1500 results (based on rpp * page)
#since_id:  returns tweets with status ids greater than the given id.
#geocode:   returns tweets by users located within a given radius of the given latitude/longitude, where the user's location is taken from their Twitter profile. The parameter value is specified by "latitide,longitude,radius", where radius units must be specified as either "mi" (miles) or "km" (kilometers). Ex: http://search.twitter.com/search.atom?geocode=40.757929%2C-73.985506%2C25km. Note that you cannot use the near operator via the API to geocode arbitrary locations; however you can use this geocode parameter to search near geocodes directly.
#show_user: when "true", adds "<user>:" to the beginning of the tweet. This is useful for readers that do not display Atom's author field. The default is "false".
 $Searchitems=$results.rss.channel.RssItem 
 if ($Deep) { $MaxID= $results.rss.channel.refresh_url.split("=")[-1]
              2..16 | foreach { $Searchitems += ([xml]($webClient.DownloadString("http://search.twitter.com/search.rss?rpp=100&max_id=$maxID;&page=$_&q=$SearchTerm").replace("item","RssItem"))).rss.channel.RssItem} }
 $SearchItems 
} 
 #Get-twitterSeach "PowerShell" -Deep | select @{Name="Author"; expression={$_.link.split("/")[3] }}, 
 #                                     @{name="Id"; expression={$_.link.split("/")[-1] }}, Title, pubdate #[date]::parseexact($_.pubdate,"formatString")


Function Get-TwitterFriend { 
 param ($username, $password, $ID)
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $WebClient.Credentials = (New-Object System.Net.NetworkCredential -argumentList $username, $password)
 $page = 1
 $Friends = @()
 if ($ID) {$URL="http://twitter.com/statuses/friends/$ID.xml?page="}
 else     {$URL="http://twitter.com/statuses/friends.xml?page="}
 do {  $Friends += (([xml]($WebClient.DownloadString($url+$Page))).users.user   )
                     # Returns the  user's friends, with current status inline, in the order they were added as friends. 
                     # If ID is specified, returns another user's friends
                     #id:    Optional.  The ID or screen name of the user for whom to request a list of friends.
                     #page:  Optional. Retrieves the next 100 friends. 

		$Page ++
	} while ($Friends.count -eq ($page * 100) )
 $Friends
}
#Get-TwitterFriend $userName $password | select name,screen_Name,url,id   


Function Get-TwitterFollower { 
 param ($username, $password, $ID)
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $WebClient.Credentials = (New-Object System.Net.NetworkCredential -argumentList $username, $password)
 $page = 1
 $followers = @()
 if ($ID) {$URL="http://twitter.com/statuses/followers/$ID.xml?page="}
 else     {$URL="http://twitter.com/statuses/followers.xml?page="}
 do {  $followers += (([xml]($WebClient.DownloadString($url+$Page))).users.user   )
                     # Returns the  user's followers, with current status inline, in the order they joined twitter
                     # If ID is specified, returns another user's followers
                     #id:    Optional.  The ID or screen name of the user for whom to request a list of friends.
                     #page:  Optional. Retrieves the next 100 friends. 

		$Page ++
	} while ($followers.count -eq ($page * 100) )
 $followers
}

Function Get-TwitterReply { 
 param ($username, $password, $Page=1)
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $WebClient.Credentials = (New-Object System.Net.NetworkCredential -argumentList $username, $password)
 ([xml]$webClient.DownloadString("http://twitter.com/statuses/replies.xml?page=$Page")  ).statuses.status 
 # Returns the 20 most recent @replies for the authenticating user.
 #page:  Optional. Retrieves the 20 next most recent replies
 #since.  Optional.  Narrows the returned results to just those replies created after the specified HTTP-formatted date, up to 24 hours old.
 #since_id.  Optional.  Returns only statuses with an ID greater than (that is, more recent than) the specified ID.  Ex: http://twitter.com/statuses/replies.xml?since_id=12345
}
#Get-TwitterReply | ft @{label="Screen_Name"; expression={$_.user.Screen_Name}}, Source, Created_at , in_reply_to_status_id, text  -a -wrap 


Function Get-TwitterTimeLine { 
 param ($username, $password, $Page=1)
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $WebClient.Credentials = (New-Object System.Net.NetworkCredential -argumentList $username, $password)
 ([xml]$WebClient.DownloadString("http://twitter.com/statuses/friends_timeline.xml?page=$Page")  ).statuses.status
 # Returns the 20 most recent statuses posted by the authenticating user and that user's friends. This is the equivalent of /home on the Web. 
 #count:    Optional.  Specifies the number of statuses to retrieve. (Max 200.) 
 #since:    Optional.  Narrows the returned results to just those statuses crea ted after the specified HTTP-formatted date, up to 24 hours old. 
 #since_id: Optional.  Returns only statuses with an ID greater than the specified ID.   
 #page.     Optional. 
}
# Get-TwitterTimeline $name $password  | ft @{label="Screen_Name"; expression={$_.user.Screen_Name}}, Source, Created_at , text  -a -wrap


Function Get-TwitterPublicTimeLine { 
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 [xml]($webclient.DownloadString("http://twitter.com/statuses/Public_timeline.xml")  ).statuses.status
 # Returns the 20 most recent statuses from non-protected users who have set a custom user icon.  Does not require authentication.  Note that the public timeline is cached for 60 seconds so requesting it more often than that is a waste of resources.
}
#Get-TwitterPublicTimeLine  | ft @{label="Screen_Name"; expression={$_.user.Screen_Name}}, Source, Created_at , in_reply_to_status_id, text  -a -wrap  
 
Function Get-TwitterUserTimeLine { 
 param ($ID)
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 ([xml]$webClient.DownloadString("http://twitter.com/statuses/user_timeline/$ID.xml")  ).statuses.status 
 # Returns the 20 most recent statuses posted from the authenticating user. It's also possible to request another user's timeline via the id parameter 
 #id:       Optional. 
 #count:    Optional.  Specifies the number of statuses to retrieve. Max 200.  
 #since:    Optional.  Narrows the returned results to just those statuses created after the specified HTTP-formatted date, up to 24 hours old. 
 #since_id: Optional.  Returns only statuses with an ID greater than (that is, more recent than) the specified ID.   
 #page:     Optional. 
}
#getTwittedUserTimeLine -ID jonhoneyball | ft @{label="Screen_Name"; expression={$_.user.Screen_Name}}, Source, Created_at , in_reply_to_status_id, text  -a -wrap 

# Returns a single status, specified by the id parameter below.  The status's author will be returned inline.
#id:  Required.  The numerical ID of the status you're trying to retrieve.  

#Get-Tweet 1196649130  | ft @{label="Screen_Name"; expression={$_.user.Screen_Name}}, Source, Created_at , in_reply_to_status_id, text  -a -wrap 


Function Get-TinyURL { 
 param ( $PostLink )
 if ($WebClient -eq $null) {$Global:WebClient=new-object System.Net.WebClient  }
 $webClient.DownloadString("http://tinyurl.com/api-create.php?url="  + [System.Web.HttpUtility]::UrlEncode($postlink)) 
}



Filter Add-TwitterFriend
{Param ([string] $ID, [string] $Username, [string] $Password)
 [System.Net.ServicePointManager]::Expect100Continue = $false
  if ($id -eq $null) {$id=$_}
  $request = [System.Net.WebRequest]::Create("http://twitter.com/friendships/create/$ID.xml")
  $request.Credentials = new-object System.Net.NetworkCredential($Username, $Password)
  $request.Method = "POST"
  $request.ContentType = "application/x-www-form-urlencoded" 
  write-progress "Tweeting" "Adding Friend" -cu $ID

  $formdata = [System.Text.Encoding]::UTF8.GetBytes( 'follow=true'  )
  $requestStream = $request.GetRequestStream()
    $requestStream.Write($formdata, 0, $formdata.Length)
  $requestStream.Close()
  $response = $request.GetResponse()

  write-host $response.statuscode 
  $reader = new-object System.IO.StreamReader($response.GetResponseStream())
     $reader.ReadToEnd()
  $reader.Close()
  $id=$null
}



#Pasted from <http://devcentral.f5.com/weblogs/Joe/archive/2008/12/30/introducing-poshtweet---the-powershell-twitter-script-library.aspx> 


function Get-TwitterList()
{   $wc = new-object system.net.webclient
    $site = $wc.DownloadString('http://www.mindofroot.com/powershell-twitterers/')
	
	$previous = @()
	$site =  $site.substring( $site.IndexOf('<div class="entrybody">'))
	$site = $site.substring($site.IndexOf('<ul>'))
	
	[xml]$doc = $site.substring(0,($site.IndexOf('</ul>') + 5))	
	$results = $doc.ul.li | select @{name='Name';Expression={$_.a.'#text'}},
                               @{name='TwitterURL';Expression={$_.a.href}},
                               @{name='UserName';Expression=
                                {$_.a.href -replace 'http://twitter.com/'}}
	$results[1..($results.count-1)]
}


