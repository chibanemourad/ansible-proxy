#!powershell
# This file is part of Ansible
#
# Copyright 2017, Daniele Lazzari <lazzari@mailup.com>
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

# win_psmodule (Powershell modules Additions/Removal)

$params = Parse-Args $args -supports_check_mode $true

$name = Get-AnsibleParam -obj $params "name" -type "str" -failifempty $true
$repo = Get-AnsibleParam -obj $params "repository" -type "str"
$url = Get-AnsibleParam -obj $params "url" -type "str"
$state = Get-AnsibleParam -obj $params "state" -type "str" -default "present" -validateset "present", "absent"
$allow_clobber = Get-AnsibleParam -obj $params "allow_clobber" -type "bool" -default $false
$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -default $false

$version = @{
    RequiredVersion = Get-AnsibleParam -obj $params -name "required_version" -type "str"
    MinimumVersion = Get-AnsibleParam -obj $params -name "minimum_version" -type "str"
    MaximumVersion = Get-AnsibleParam -obj $params -name "maximum_version" -type "str"
}

$result = @{"changed" = $false
            "output" = ""
            "nuget_changed" = $false
            "repository_changed" = $false}

Function Install-NugetProvider {
  param(
    [bool]$CheckMode
    )
  $PackageProvider = Get-PackageProvider -ListAvailable|?{($_.name -eq 'Nuget') -and ($_.version -ge "2.8.5.201")}
  if (!($PackageProvider)){
      try{
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop -WhatIf:$CheckMode | out-null
        $result.changed = $true
        $result.nuget_changed = $true
      }
      catch{
        $ErrorMessage = "Problems adding package provider: $($_.Exception.Message)"
        Fail-Json $result $ErrorMessage
      }
    }
}

Function Install-Repository {
    Param(
    [Parameter(Mandatory=$true)]
    [string]$Name,
    [Parameter(Mandatory=$true)]
    [string]$Url,
    [bool]$CheckMode
    )
    $Repo = (Get-PSRepository).SourceLocation

    # If repository isn't already present, try to register it as trusted.
    if ($Repo -notcontains $Url){
      try {
           if (!($CheckMode)) {
               Register-PSRepository -Name $Name -SourceLocation $Url -InstallationPolicy Trusted -ErrorAction Stop
           }
          $result.changed = $true
          $result.repository_changed = $true
      }
      catch {
        $ErrorMessage = "Problems adding $($Name) repository: $($_.Exception.Message)"
        Fail-Json $result $ErrorMessage
      }
    }
}

Function Remove-Repository{
    Param(
    [Parameter(Mandatory=$true)]
    [string]$Name,
    [bool]$CheckMode
    )

    $Repo = (Get-PSRepository).SourceLocation

    # Try to remove the repository
    if ($Repo -contains $Name){
        try {
            if (!($CheckMode)) {
                Unregister-PSRepository -Name $Name -ErrorAction Stop
            }
            $result.changed = $true
            $result.repository_changed = $true
        }
        catch {
            $ErrorMessage = "Problems removing $($Name)repository: $($_.Exception.Message)"
            Fail-Json $result $ErrorMessage
        }
    }
}

Function Need-Install-PsModule {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$RequiredVersion,
        [string]$MinimumVersion,
        [string]$MaximumVersion
    )

    $Installed = Get-Module -ListAvailable -Name $Name

    if ($RequiredVersion) {
        if($Installed|?{[System.Version]$_.Version -eq [System.Version]$RequiredVersion}) {
            $result.output = "Module $($Name) version present already is $($RequiredVersion)"
            return $false;
        }
        return $true;
    }

    if ($MinimumVersion -and $MaximumVersion) {
        if($Installed|?{[System.Version]$_.version -ge [System.Version]$MinimumVersion -and [System.Version]$_.version -le [System.Version]$MaximumVersion}) {
            $result.output = "Module $($Name) version present already less than or equal to $($MaximumVersion) and greater than or equal to $($MinimumVersion)"
            return $false;
        }
        return $true;
    }

    if ($MinimumVersion) {
        if($Installed|?{[System.Version]$_.version -ge [System.Version]$MinimumVersion}) {
            $result.output = "Module $($Name) version present already greater than or equal to $($MinimumVersion)"
            return $false;
        }
        return $true;
    }

    if ($MaximumVersion) {
        if($Installed|?{[System.Version]$_.version -le [System.Version]$MaximumVersion}) {
            $result.output = "Module $($Name) version present already less than or equal to $($MaximumVersion)"
            return $false;
        }
        return $true;
    }

    if ($Installed){
        $result.output = "Module $($Name) already present"
        return $false;
    }
    return $true;
}

Function Install-PsModule {
    param(
      [Parameter(Mandatory=$true)]
      [string]$Name,
      [string]$Repository,
      [bool]$AllowClobber,
      [string]$MinimumVersion,
      [string]$MaximumVersion,
      [string]$RequiredVersion,
      [bool]$CheckMode
    )
    try{
        # Install NuGet Provider if needed
        Install-NugetProvider -CheckMode $CheckMode;

        $ht = @{
            Name      = $Name;
            WhatIf    = $CheckMode;
            ErrorAction = "Stop";
            Force     = $true;
        };

        # If specified, use repository name to select module source
        if ($Repository) {
            $ht["Repository"] = "$Repository";
        }

        # If any version config is specified, use them
        if ($MinimumVersion) {
            $ht["MinimumVersion"] = "$MinimumVersion";
        }
        if ($MaximumVersion) {
            $ht["MaximumVersion"] = "$MaximumVersion";
        }
        if ($RequiredVersion) {
            $ht["RequiredVersion"] = "$RequiredVersion";
        }

        # Check Powershell Version (-AllowClobber was introduced in PowerShellGet 1.6.0)
        if ("AllowClobber" -in ((Get-Command PowerShellGet\Install-Module | Select -ExpandProperty Parameters).Keys)) {
            $ht['AllowClobber'] = $AllowClobber;
        }

        Install-Module @ht | out-null;

        $result.output = "Module $($Name) installed"
        $result.changed = $true
    }
    catch{
        $ErrorMessage = "Problems installing $($Name) module: $($_.Exception.Message)"
        Fail-Json $result $ErrorMessage
    }
}

Function Remove-PsModule {
    param(
      [Parameter(Mandatory=$true)]
      [string]$Name,
      [bool]$CheckMode
    )
    # If module is present, unistalls it.
    if (Get-Module -Listavailable|?{$_.name -eq $Name}){
      try{
        Uninstall-Module -Name $Name -Confirm:$false -Force -ErrorAction Stop -WhatIf:$CheckMode | out-null
        $result.output = "Module $($Name) removed"
        $result.changed = $true
      }
      catch{
        $ErrorMessage = "Problems removing $($Name) module: $($_.Exception.Message)"
        Fail-Json $result $ErrorMessage
      }

    }
    else{
      $result.output = "Module $($Name) not present"
    }
}

# Check powershell version, fail if < 5.0
$PsVersion = $PSVersionTable.PSVersion
if ($PsVersion.Major -lt 5){
  $ErrorMessage = "Powershell 5.0 or higher is needed"
  Fail-Json $result $ErrorMessage
}

if ($state -eq "present") {
    if (($version['RequiredVersion']) -and (($version['MinimumVersion']) -or ($version['MaximumVersion']))) {
        $ErrorMessage = "You must not use Required Version if you use either Minimum or Maximum Version"
        Fail-Json $result $ErrorMessage
    }

    if (($repo) -and ($url)) {
        Install-Repository -Name $repo -Url $url -CheckMode $check_mode
    }
    else {
        $ErrorMessage = "Repository Name and Url are mandatory if you want to add a new repository"
    }

    if((Need-Install-PsModule -Name $Name @version)) {
        Install-PsModule -Name $Name -Repository $repo -CheckMode $check_mode -AllowClobber $allow_clobber @version;
    }
}
else {
    if ($repo) {
        Remove-Repository -Name $repo -CheckMode $check_mode
    }
    Remove-PsModule -Name $Name -CheckMode $check_mode
}

Exit-Json $result
