[void]([System.Console]::TreatControlCAsInput)

$PSWebCmd                 = [Hashtable]::Synchronized(@{})
$PSWebCmd.Script          = $MyInvocation.MyCommand.Definition
$PSWebCmd.Directory       = Split-Path -Parent -Path $PSWebCmd.Script
$PSWebCmd.ScriptDirectory = "$($PSWebCmd.Directory)\lib" 
$PSWebCmd.ModuleDirectory = "$($PSWebCmd.ScriptDirectory)\Modules"

Get-ChildItem ("$($PSWebCmd.ScriptDirectory)\*.ps1") | 
    ForEach { . $_.FullName }

# Confirm Administrator
$Param = @{
    TypeName     = 'System.Security.Principal.WindowsPrincipal'
    ArgumentList = [Security.Principal.WindowsIdentity]::GetCurrent()
}
$PSWebCmd.RunAs = New-Object @Param

if ( -not ($PSWebCmd.RunAs.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator ))) 
    { Throw "This script must be executed from an elevated PowerShell session" }

Try
{
    $PSWebCmd.Listener = New-Object Net.HttpListener
    Invoke-WebServer
}
catch 
{ 
    Write-Error "An error occurred" 
    $_.Exception.Message    
}
finally 
{ 
    $PSWebCmd.Listener.Stop() 
}
