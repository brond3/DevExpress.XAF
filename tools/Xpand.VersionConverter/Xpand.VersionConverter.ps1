using namespace System
using namespace System.IO
using namespace System.IO.Compression
using namespace System.Reflection
using namespace System.Text.RegularExpressions
using namespace Mono.Cecil
param(
    [parameter(Mandatory)]
    [string]$projectFile = $null,
    [parameter(Mandatory)]
    $targetPath = $null,
    $referenceFilter = "DevExpress*",
    $assemblyFilter = "Xpand.XAF.*"
)
$ErrorActionPreference = "Stop"
$projectFileInfo = Get-item $projectFile
[xml]$csproj = Get-Content $projectFileInfo.FullName
$references = $csproj.Project.ItemGroup.Reference
$dxReferences = $references|Where-Object {$_.Include -like "$referenceFilter"}
$root = $PSScriptRoot
"Loading Mono.Cecil"
$monoPath = "$root\mono.cecil.0.10.1\lib\net40\Mono.Cecil.dll"
if (!(Test-Path $monoPath)) {
    $client = New-Object System.Net.WebClient
    $client.DownloadFile("https://www.nuget.org/api/v2/package/Mono.Cecil/0.10.1", "$root\mono.cecil.0.10.1.zip")
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [ZipFile]::ExtractToDirectory("$root\mono.cecil.0.10.1.zip", "$root\mono.cecil.0.10.1")
}
$bytes = [File]::ReadAllBytes($monoPath)
[Assembly]::Load($bytes)|out-null
$sourceAssemblyName = Invoke-Command {

    "Finding DX assembly name"
    $dxAssemblyPath = (Get-ChildItem $targetPath "$referenceFilter*.dll" |Select-Object -First 1).FullName
    if ($dxAssemblyPath) {
        $dxAssembly = [AssemblyDefinition]::ReadAssembly($dxAssemblyPath)
        "$sourceAssemblyName found from $dxAssemblyPath"
        $dxAssembly.Name
    }
    else {
        $name = ($dxReferences|Where-Object {$_.Include -like "*Version*"}|Select-Object -First 1).Include
        new-object System.Reflection.AssemblyName($name)
    }
}|Select-Object -last 1
if (!$sourceAssemblyName) {
    throw "Cannot find $referenceFilter version in $($projectFileInfo.Name)"
}

$references|Where-Object {$_.Include -like $assemblyFilter}|ForEach-Object {
    "$targetPath\$([Path]::GetFileName($_.HintPath))", "$($projectFileInfo.DirectoryName)\$($_.HintPath)"|ForEach-Object {
        if (Test-path $_) {
            $modulePath = (Get-Item $_).FullName
            $readerParams = new-object ReaderParameters
            $readerParams.ReadWrite = $true
            $moduleAssembly = [AssemblyDefinition]::ReadAssembly($modulePath, $readerParams)
            Write-host "Checking $modulePath references.." -f "Blue"
            $moduleAssembly.MainModule.AssemblyReferences.ToArray()|Where-Object {$_.FullName -like $referenceFilter}|ForEach-Object {
                $nowReference = $_
                if ($nowReference.Version -ne $sourceAssemblyName.Version) {
                    $moduleAssembly.MainModule.AssemblyReferences.Remove($nowReference)
                    $newMinor = "$($sourceAssemblyName.Version.Major).$($sourceAssemblyName.Version.Minor)"
                    $newName = [Regex]::Replace($nowReference.Name, ".(v[\d]{2}\.\d)", ".v$newMinor")
                    $regex = New-Object Regex("PublicKeyToken=([\w]*)")
                    $token = $regex.Match($nowReference).Groups[1].Value
                    $regex = New-Object Regex("Culture=([\w]*)")
                    $culture = $regex.Match($nowReference).Groups[1].Value
                    $newReference = [AssemblyNameReference]::Parse("$newName, Version=$($sourceAssemblyName.Version), Culture=$culture, PublicKeyToken=$token")
                    $moduleAssembly.MainModule.AssemblyReferences.Add($newreference)
                    $moduleAssembly.MainModule.Types|
                        ForEach-Object {$moduleAssembly.MainModule.GetTypeReferences()| Where-Object {$_.Scope -eq $nowReference}|
                            ForEach-Object {$_.Scope = $newReference}}
                    Write-Host "$($_.Name) version changed from $($_.Version) to $($sourceAssemblyName.Version)" -f Green
                }
            }
            $writeParams=New-Object WriterParameters
            $f=New-Object FileStream("$root\Xpand.snk",[FileMode]::Open)
            $writeParams.StrongNameKeyPair=New-Object System.Reflection.StrongNameKeyPair ( $f)
            $moduleAssembly.Write($writeParams)
            $f.Dispose()
            $moduleAssembly.Dispose()   
        }
    }
}
