#
# Manage SSH keys for multiple Git hosts
#
# Execution examples:
#   gitid.ps1 -id llc
#   gitid.ps1 -id llc -user mattmccartyllc
#   gitid.ps1 -id llc -user mattmccartyllc -repo git@github.com:mattmccartyllc/gitid.git
#   gitid.ps1 -id llc -user mattmccartyllc -repo git@github.com:mattmccartyllc/gitid.git -prefix "gitid"
#
# git clone git@gitid-llc.github.com:mattmccartyllc/gitid.git
#
param(
  [Parameter(Mandatory=$true )][string] $id     = "",
  [Parameter(Mandatory=$false)][string] $user   = "git",
  [Parameter(Mandatory=$false)][string] $repo   = $null,
  [Parameter(Mandatory=$false)][string] $prefix = "gitid"
)

#
# Ensure the $prefix is not already in the $identity name
#
$identity = $id
if ($identity.Replace("-", "") -like "*$prefix*" -or
    $identity.Replace("-", "").length -le 0
) {
  Write-Error "Identity must be set and cannot contain the string '$prefix' because it's the prefix."
  return $false
}

#
# Ensure SSH key ($sshKey) file name and identity name ($identity) are formatted properly.
#
$sshKey   = "id_${prefix}_" + $identity.ToLower().Replace("-", "_")
$identity = "$prefix-"      + $identity.ToLower()
$user     = if ($user.length -le 0) {"git"} else {$user}

#
# Set the $env:HOME directory so we can use one variable between *nix and Windows.
#
$isRunningWindows = "$env:SystemRoot"
if ($isRunningWindows.length -gt 0 -and "$env:HOME" -le 0) {
  $env:HOME = "$env:USERPROFILE"
}

#
# Function to format a directory or file path based on operating system.
# It ensures the correct path separator is used (e.g., backslash or forwardslash)
#
function Get-PlatformPath {
  param (
    [Parameter(Mandatory=$true)][string] $path
  )

  if ($PSVersionTable.Platform -eq 'Unix') {
      # Replace '\' with '/'
      return $path.Replace('\', '/')
  } else {
      # Replace '/' with '\'
      return $path.Replace('/', '\')
  }
}

#
# Tests to see if a string is empty or not
#
function Test-NonEmptyString {
  param (
    [Parameter(Mandatory=$true)][string] $str
  )

  if ($str.GetType().Name -eq 'String' -and -not [String]::IsNullOrEmpty($str)) {
    return $true
  }

  return $false
}

#
# Returns the path to the SSH config file
#
function Get-SSHConfigPath {
  return Get-PlatformPath "$env:HOME/.ssh/config"
}

#
# Returns the full path to a SSH key based on the $keyName
#
function Get-SSHKeyPath {
  param (
    [Parameter(Mandatory=$false)][string] $keyName = $sshKey
  )

  return Get-PlatformPath "$env:HOME/.ssh/$keyName"
}

#
# Generates a new $sshKey if it doesn't already exist for $hostName for $identity
#
function New-SSHKey {
  param (
    [Parameter(Mandatory=$true)][string]  $hostName,
    [Parameter(Mandatory=$false)][string] $keyName = $sshKey
  )

  $sshKeyPath = Get-SSHKeyPath $keyName
  if (Test-Path -Path $sshKeyPath) {
    return $true
  }

  try {
    ssh-keygen -t ed25519 -C $hostName -f $sshKeyPath
    Write-Debug "SSH key created successfully."
    return $true
  } catch {
    Write-Error "An error has occured while creating the SSH key: '$env:HOME/.ssh/$keyName'"
  }

  return $false
}

#
# Determines how many spaces to use for indentation if the SSH config
# already exists on the filesystem. This will hopefully keep things
# consistent with manual entries. Defaults is two spaces.
#
function Get-HostConfigIndentationCount {
  $defaultIndentation = 2
  $indentationCount   = $defaultIndentation

  if (Test-Path -Path Get-SSHConfigPath) {
    $fileContent = Get-Content Get-SSHConfigPath

    if (![string]::IsNullOrWhiteSpace($fileContent)) {
      # Convert tabs to spaces
      $fileContent = $fileContent -replace "`t", "    "

      foreach ($line in $fileContent) {
        if (![string]::IsNullOrWhiteSpace($line)) {
          $leadingSpaces = $line -replace '^(\s*).*','$1'
          $indentationCount = $leadingSpaces.Length
          break
        }
      }
    }
  }

  return $indentationCount
}

#
# Generates a string with X [:space] characters based on the return value
# of Get-HostConfigIndentationCount(). The return string can be used to
# build a properly indented SSH config file.
#
function Get-HostConfigIndentationString {
  $indentationCount = Get-HostConfigIndentationCount
  return [String]::new(' ', $indentationCount)
}

#
# Generates the SSH config file contents. If the file is empty or does
# not exist, it will set additional config values like AddKeysToAgent
# and IdentitiesOnly.
#
function Get-HostConfigString {
  param (
    [Parameter(Mandatory=$true )][string] $hostName,
    [Parameter(Mandatory=$false)][string] $userName = "git",
    [Parameter(Mandatory=$false)][string] $keyName  = $sshKey
  )

  $indentation   = Get-HostConfigIndentationString
  $sshKeyPath    = Get-SSHKeyPath $keyName
  $sshConfig     = @()
  $sshConfigFile = Get-Item -Path $sshConfigPath

  if ($sshConfigFile.Length -eq 0) {
    $sshConfig += "Host *"
    $sshConfig += "${indentation}AddKeysToAgent yes"
    $sshConfig += "${indentation}IdentitiesOnly yes"
  }

  # Host string
  $sshConfig += ""
  $sshConfig += "Host $hostName"
  $sshConfig += "${indentation}User $userName"
  $sshConfig += "${indentation}HostName $($hostName.Replace($identity+'.', ''))"
  $sshConfig += "${indentation}PreferredAuthentications publickey"
  $sshConfig += "${indentation}IdentitiesOnly yes"
  $sshConfig += "${indentation}IdentityFile $sshKeyPath"

  return $sshConfig
}


#
# Determines if $hostName (based on $identity and the git repo in question)
# already exists in the SSH config file or not.
#
function Test-HostConfig {
  param (
    [Parameter(Mandatory=$true)][string] $hostName
  )

  $sshConfigPath = Get-SSHConfigPath
  if (!(Test-Path -path $sshConfigPath)) {
    return $true
  }

  $data = Get-Content $sshConfigPath
  if ($data -like "*$($hostName.ToLower())*") {
    return $false
  }

  return $true
}

#
# If the $hostName for $identity (and the git repo in question) does
# not already exist in the SSH config, this will generate an additional
# config from the return value of Get-HostConfigString and append it
# to the end of the SSH config file (and create it if it doesn't exist).
#
function Edit-HostConfig {
  param (
    [Parameter(Mandatory=$true )][string] $hostName,
    [Parameter(Mandatory=$false)][string] $userName = "git",
    [Parameter(Mandatory=$false)][string] $keyName  = $sshKey
  )

  $sshConfigPath = Get-SSHConfigPath
  if (!(Test-Path -path $sshConfigPath)) {
    New-Item -ItemType File -Path $sshConfigPath
  }

  $test = $(Test-HostConfig $hostName)
  if ($test -eq $false) {
    if ($userName -ne ".git") {
      Write-Debug "Changing username in existing SSH config file entry for the host '$hostName'."
      $sshConfigContent = Get-Content -Path $sshConfigPath -Raw
      $regex            = "(?<=Host\s$hostName\s+.+\sUser\s)\S*"
      if ($sshConfigContent -match $regex) {
        $sshConfigContent = $sshConfigContent -replace $regex, $userName
      } else {
        $regex        = "(Host\s$hostName)"
        $newUserEntry = "`$1`n  User $userName"
        $sshConfigContent = $sshConfigContent -replace $regex, $newUserEntry
      }

      $sshConfigContent | Out-File -FilePath $sshConfigPath -NoNewline -Encoding utf8
    } else {
      Write-Debug "The hostname '$hostName' already exists in the SSH config file '$sshConfigPath'. Skipping."
    }
  } else {
    Add-Content -Path $sshConfigPath -Value (
      Get-HostConfigString -hostName $hostName -username $userName -keyName $keyName
    )
    Write-Debug "New host '$hostName' successfully added to the SSH config file '$sshConfigPath'."
  }
}

#
# Tests to see if the current working directory is a Git repo or not
#
function Test-GitRepo {
  try {
    $output = git rev-parse --is-inside-work-tree
    return $output.Trim() -eq "true"
  } catch {
    return $false
  }
}

#
# Extracts the origin of the Git repo of the current working directory.
# This information is extracted from ./.git/config.
#
function Get-GitRepoUrl {
  return (git remote get-url origin).ToString()
}

#
# Reads the ./.git/config file using Get-GitRepoUrl and then returns
# the new repo origin hostname based on $identity and $prefix. If
# $testRepo is $true, then it will ensure the current working is a
# Git repo. If $baseName is $true, it will always return the $identity
# based hostname and will remove anything else from the value (git@, .git, etc).
# $baseName = $true, will only return the actual (new) name of the host.
#
function Get-GitRepoHostName {
  param (
    [Parameter(Mandatory=$false)][string] $identity = $identity,
    [Parameter(Mandatory=$false)][string] $prefix   = $prefix,
    [Parameter(Mandatory=$false)][bool]   $testRepo = $true,
    [Parameter(Mandatory=$false)][bool]   $baseName = $false,
    [Parameter(Mandatory=$false)][string] $repo     = $repo
  )

  $repoUrl = $repo
  if ($null -eq $repo -or $repo.length -le 0) {
    if ($testRepo -eq $true -and !(Test-GitRepo)) {
      return $null
    }

    $repoUrl = Get-GitRepoUrl
  }

  # Regex example patterns:
  #   git@PREFIX-RANDOMIDENTITY.github.com:USERNAME/REPONAME.git
  #   git@PREFIX-RANDOMIDENTITY.bitbucket.org:PROJECT/REPONAME.git
  $regex = "(.*)@(${prefix}-)([^.]+).(.+)?:(.*)/(.*).git"
  if ($repoUrl -match $regex) {
    if (($Matches[2] + $Matches[3]) -ne $identity) {
      if ($baseName -eq $false) {
        return "$($Matches[1])@${identity}.$($Matches[4]):$($Matches[5])/$($Matches[6]).git"
      } else {
        return "${identity}.$($Matches[4])"
      }
    } else {
      if ($baseName -eq $false) {
        Write-Debug "Identity '${identity}' is already in use."
        return $true
      } else {
        return "${identity}.$($Matches[4])"
      }
    }
  }

  # Regex example patterns:
  #   git@github.com:USERNAME/REPONAME.git
  #   git@bitbucket.org:PROJECT/REPONAME.git
  $regex = "(.*)@(.*):(.*)/(.*).git"
  if ($repoUrl -match $regex) {
    if (($Matches[2] -notlike "$identity.*")) {
      $Matches[2] = "${identity}." + $Matches[2]
      if ($baseName -eq $false) {
        return "$($Matches[1])@$($Matches[2]):$($Matches[3])/$($Matches[4]).git"
      } else {
        return "$($Matches[2])"
      }
    }
  }

  # Regex example patterns:
  #   https://github.com/USERNAME/REPONAME.git
  $regex = "https://(.*)/(.*)/(.*).git"
  if ($repoUrl -match $regex) {
    Write-Error "This script does not handle HTTPS Git repositories. SSH keys are not needed."
    return $false
  }

  # Regex example patterns:
  #   https://USERNAME@{IDENTITY?}.bitbucket.org/PROJECT/REPONAME.git
  $regex = "https://(.*)@(.*)/(.*)/(.*).git"
  if ($repoUrl -match $regex) {
    Write-Error "This script does not handle HTTPS Git repositories. SSH keys are not needed."
    return $false
  }

  # Regex example patterns:
  #   codecommit:?:REGION://REPONAME
  $regex = "codecommit:(.*)?:(.*)?:(.*)?//(.*)"
  if ($repoUrl -match $regex) {
    Write-Error "This script does not support AWS CodeCommit Git repositories. SSH keys are not needed."
    return $false
  }

  Write-Error "Could not match hostname format in repository config file."
  return $false
}

#
# If the current working directory is a Git repo, then update the ./.git/config file
# origin with the $identity hostname, generate a new SSH key for the $identity, and
# update the ~/.ssh/config file.
#
$hostName = Get-GitRepoHostName -repo $repo -testRepo $false
if ($hostName.GetType().Name -eq 'String' -and -not
    [String]::IsNullOrEmpty($hostName)
) {
  if ((Test-GitRepo) 2>$null) {
    git remote set-url origin $hostName
  }
}

$hostName     = Get-GitRepoHostName -repo $repo -testRepo $false -baseName $true
$sshKeyCreate = $(New-SSHKey -hostName $hostName -keyName $sshKey)
if ($sshKeyCreate -eq $false) {
  Exit 1
}

$editConfig = $(Edit-HostConfig -hostName $hostName -userName $user -keyName $sshKey)
if ($editConfig -eq $false) {
  Exit 1
}

Write-Output "Done."
