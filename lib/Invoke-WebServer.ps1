Function Invoke-WebServer
{
    [CmdletBinding()]
    Param(
        [Parameter( Mandatory=$False )]
        [ValidateRange(1,65535)]
        [Int]$Port=80,
        
        [Parameter( Mandatory=$False )]
        [ValidateRange(1,65535)]
        [Int]$SSLPort=443,

        [Parameter( Mandatory=$False )]
        [switch]$UseSSL,

        [Parameter( Mandatory=$False )]
        [Int]$MaxThreads = (Get-WmiObject Win32_Processor | 
                                Measure-Object -Sum -Property NumberOfLogicalProcessors).Sum      
    )
    
    Begin
    {
        $SessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($Module in (Get-ChildItem $PSWebCmd.ModuleDirectory))
        {
            $SessionState.ImportPSModule($Module.FullName)
        }

        $Pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $SessionState, $Host)
        $Pool.ApartmentState  = 'STA'
        if ($PSVersionTable.PSVersion.Major -gt 2) 
            { $Pool.CleanupInterval = 2 * [timespan]::TicksPerMinute }
        $Pool.Open()

        $PSWebCmd.Listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::IntegratedWindowsAuthentication
        $PSWebCmd.Listener.Prefixes.Add("http://+:$Port/")       

        if ($UseSSL)
            { $PSWebCmd.Listener.Prefixes.Add("https://+:$SSLPort/") }

        $PSWebCmd.Listener.Start()

        if ($UseSSL)
        {
            try
            {
                $Certificate = (Get-ChildItem Cert:\LocalMachine\My | 
                                    Where { $_.Subject -like "*$env:COMPUTERNAME*" })
                If (-not $Certificate -is [Security.Cryptography.X509Certificates.X509Certificate2]) 
                    { throw 'Certifcate not found in certifcate store' }
                $CertificateThumbprint = $Certificate.Thumbprint

                [void](netsh http delete sslcert ipport="127.0.0.1:$SSLPort")
                [void](netsh http add sslcert ipport="127.0.0.1:$SSLPort" certhash="$CertificateThumbprint" appid="{$([guid]::NewGuid().Guid)}")
            }
            catch
            {
                Write-Warning "Error while configuring HTTPS`r`n$($_.Exception.Message)"
            }
        }

        $Jobs = New-Object Collections.Generic.List[PSCustomObject]

        #region RequestProcessing 
        $RequestCallback = { 
            Param ( $ThreadID, $PSWebCmd )

            $User           = ''
            $Format         = ''
            $Command        = ''
            $HadError       = $false
            $ShouldStop     = $false
            $StatusCode     = 202
            $ConsoleOutput  = ''
             
            $Context  = $PSWebCmd.Listener.GetContext()
            $Request  = $Context.Request
            $Response = $Context.Response
            $Response.Headers.Add('Server','PSWebCmd')
            $Response.Headers.Add('X-Powered-By','Microsoft PowerShell')
            $Response.Headers.Add('Vary', 'Accept-Encoding')
            
            if (-not $Request.IsAuthenticated)
            {
                $StatusCode    = 403
                $ResponseData  = 'UNAUTHORIZED'
                $ConsoleOutput = 'Unauthenticated user attempted to access server.'
                $HadError      = $true
                $User          = 'Unauthenticated User'
            }
            else
            {
                $User = $Context.User.Identity.Name
                if (-not $Context.User.IsInRole('PSWebCMD '))
                {
                    $StatusCode    = 403
                    $ResponseData  = 'UNAUTHORIZED - invalid access.'
                    $ConsoleOutput = 'Unauthorized user attempted to access server.'
                    $HadError      = $true
                }
                else
                {
                   if (-not $Request.QueryString.HasKeys()) 
                    {
                        $ResponseData  = "GET command Syntax: ?command=<command string>[&format=[TEXT|XML]]"
                        $Command       = "none"
                        $Format        = "TEXT"
                        $ConsoleOutput = "Unrecognized command entered."
                        $HadError      = $true
                    }
                    else
                    {
                        $Command = $Request.QueryString.Item("command")
                        $Format  = $Request.QueryString.Item("format")

                        if ($Format -eq $null) { $Format = "TEXT" }

                        if ($Command -eq 'stop')
                        {
                            $ShouldStop = $true
                        }
                        else 
                        {
                            try
                            {
                                $ResponseData  = &([ScriptBlock]::Create($Command))
                                $ConsoleOutput = "Command completed successfully."
                                $StatusCode    = 200
                            }
                            catch
                            {
                                $ErrorObject   = $_
                                $PropertyNames = $ErrorObject.psobject.Properties | Select -ExpandProperty Name
                                $Hash          = @{}

                                $PropertyNames | ForEach {
                                    if ($ErrorObject.$_ -ne $null -and ($ErrorObject.$_ -is [String] -or 
                                       (Get-Member -MemberType Properties -InputObject ($ErrorObject.$_)).Count -eq 0))
                                    {
                                        $Hash.Add($_, $ErrorObject.$_)
                                    }
                                }

                                $ResponseData  = $Hash
                                $StatusCode    = 500
                                $HadError      = $true
                                $ConsoleOutput = "An error occured while trying to execute the provided command"
                            }
                        }
                        $ResponseData = Switch ($Format.ToLower())
                        {
                            text    
                            { 
                                $Response.Headers.Add('Content-Type', 'text/plain')
                                $ResponseData | Out-String
                                break 
                            }
                            xml     
                            { 
                                $Response.Headers.Add('Content-Type', 'application/xml')
                                $ResponseData | ConvertTo-Xml -As String
                                break 
                            }
                            default 
                            { 
                                $ResponseData = 'Invalid format selected - acceptable formats: TEXT, XML'
                                $ConsoleOutput = $ResponseData
                                $StatusCode = 501
                                $HadError = $true
                                break 
                            }
                        }
                    }
                }
            }

            if (-not $ResponseData) { $ResponseData = "No output." }
            $Buffer = [Text.Encoding]::UTF8.GetBytes($ResponseData)

            #region Encoding
            $AcceptEncoding = $Request.Headers['Accept-Encoding'] -split ',' | ForEach { $_.Trim() }
            if ((-not [String]::IsNullOrEmpty($AcceptEncoding)) -and 
                ($AcceptEncoding -contains 'gzip')) 
                {
                    $Response.Headers.Add('Content-Encoding','gzip')                

                    try 
                    { 
                        $Response.StatusCode = $StatusCode
                        $Output = $Response.OutputStream

                        $Param = @{
                            TypeName     = 'System.IO.Compression.GzipStream'
                            ArgumentList = ($Output, [IO.Compression.CompressionMode]::Compress, $false)
                        }
                        $GzipStream = New-Object @Param
                        $GzipStream.Write($Buffer, 0, $Buffer.Length)
                        $GzipStream.Close()
                    }
                    catch
                    {
                        $ConsoleOutput = "An error occurred during Gzip compression`r`n$($_.Exception.Message)"
                        $StatusCode = 500
                        $HadError = $true
                    }
                    finally 
                    {
                        $Output.Close()
                    }
            } 
            else
            {
                $Response.StatusCode      = $StatusCode
                $Response.ContentLength64 = $Buffer.Length

                $Output = $Response.OutputStream
                $Output.Write($Buffer, 0, $Buffer.Length)
                $Output.Close()
            }
            #endregion

            # Return data to console
            New-Object -TypeName PSObject -Property @{
                ThreadID      = $ThreadID
                Stop          = $ShouldStop
                HadError      = $HadError
                StatusCode    = $StatusCode
                User          = $User
                Command       = $Command
                Format        = $Format
                ConsoleOutput = $ConsoleOutput
            }
        }
        #endregion
    }

    Process
    {
        # Build initial ThreadQueue
        for ($i = 0 ; $i -lt $MaxThreads ; $i++) 
        {
            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            [void]$Pipeline.AddScript($RequestCallback)

            $Params =   @{ 
                ThreadID  = $i
                PSWebCmd  = $PSWebCmd
            }
        
            [void]$Pipeline.AddParameters($Params)

            $Jobs.Add((New-Object PSObject -Property @{
                Pipeline = $Pipeline
                Job      = $Pipeline.BeginInvoke()
            }))
            
        }
        
        Write-Output "Starting Listener Threads: $($Jobs.Count)"
		
        while ($Jobs.Count -gt 0) 
        {   
            $AwaitingRequest = $true
		    while ($AwaitingRequest)
		    {                
		        if ([Console]::KeyAvailable) 
                {
                    $Key = [Console]::ReadKey($true)
                    if (($Key.Modifiers -band [ConsoleModifiers]'control') -and ($Key.Key -eq 'C'))
                    {                    
                        $PSWebCmd.Listener.Stop()
                        $PSWebCmd.Listener.Close()
                        $PSWebCmd.Clear()
                        
                        $Jobs | Foreach {
                            [void]$_.Pipeline.EndInvoke($_.Job)
                            $_.Pipeline.Dispose()
                            $_.Job = $null
                            $_.Pipeline = $null 
                        }
                        
                        $Jobs.Clear()
                        $Pool.Close()
                        $Pool.Dispose()
                        Remove-Variable -Name Jobs -Force
                        [GC]::Collect()
                        
                        exit
                    }
                } 	    
        
                $Jobs | Foreach {
                    if ($_.Job.IsCompleted)
				    {
                        $AwaitingRequest = $False
                        $JobIndex = $Jobs.IndexOf($_)
       
                        break
				    }
                }
		    }

            $Results = $Jobs.Item($JobIndex).Pipeline.EndInvoke($Jobs.Item($JobIndex).Job)

            if ($Pipeline.HadErrors)
            {
                $Pipeline.Streams.Error.ReadAll() | 
                    Foreach { Write-Error $_ }
            }
            else 
            {
                $Results | 
                    Foreach { 
                    Write-Output "Command: $($_.Command)`r`nOutput: $($_.ConsoleOutput)`r`n"
                }
            }
            
            $Jobs.Item($JobIndex).Pipeline.Dispose()
            $Jobs.RemoveAt($JobIndex)

            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            [void]$Pipeline.AddScript($RequestCallback)
 
            $Params =   @{ 
                ThreadID  = $JobIndex 
                PSWebCmd  = $PSWebCmd
            }
 
            [void]$Pipeline.AddParameters($Params)

            $Jobs.Insert($JobIndex, (New-Object PSObject -Property @{
                Pipeline = $Pipeline
                Job      = $Pipeline.BeginInvoke()
            }))
        }
    }

    End
    {
        if (-not $Pool.IsDisposed)
        {
            $Pool.Close()
            $Pool.Dispose()
        }
    }

}