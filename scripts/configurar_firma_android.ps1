#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$KeystorePath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'interfonia-upload.jks'),
    [string]$KeyAlias = 'upload'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$propertiesPath = Join-Path $projectRoot 'android\key.properties'
if (Test-Path -LiteralPath $propertiesPath) {
    throw 'android/key.properties ya existe. Se conserva su configuracion; no se sobrescribio.'
}
$keystore = Get-Item -LiteralPath $KeystorePath -ErrorAction Stop
if ($keystore.PSIsContainer) {
    throw 'La ruta indicada debe ser un archivo de claves.'
}

$keytoolPath = Join-Path ${env:ProgramFiles} 'Android\Android Studio\jbr\bin\keytool.exe'
if (-not (Test-Path -LiteralPath $keytoolPath)) {
    $keytoolPath = (Get-Command keytool -ErrorAction Stop).Source
}

function ConvertFrom-SecureValue([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-JavaPropertyValue([string]$Value) {
    $escaped = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        switch ($code) {
            9  { [void]$escaped.Append('\t') }
            10 { [void]$escaped.Append('\n') }
            12 { [void]$escaped.Append('\f') }
            13 { [void]$escaped.Append('\r') }
            32 { [void]$escaped.Append('\ ') }
            33 { [void]$escaped.Append('\!') }
            35 { [void]$escaped.Append('\#') }
            58 { [void]$escaped.Append('\:') }
            61 { [void]$escaped.Append('\=') }
            92 { [void]$escaped.Append('\\') }
            default {
                if ($code -lt 32 -or $code -gt 126) {
                    [void]$escaped.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$escaped.Append($character)
                }
            }
        }
    }
    return $escaped.ToString()
}

Write-Host 'Configura la clave existente. Las contrasenas no se mostraran en pantalla.'
$storeSecret = Read-Host 'Contrasena del almacen de claves' -AsSecureString
if ($storeSecret.Length -eq 0) {
    throw 'La contrasena del almacen no puede estar vacia.'
}
$keySecret = Read-Host 'Contrasena de la clave upload (Enter si usaste la misma)' -AsSecureString

$storePassword = $null
$keyPassword = $null
$previousStorePassword = [Environment]::GetEnvironmentVariable('GLADIATOR_UPLOAD_STORE_PASS', 'Process')
$previousKeyPassword = [Environment]::GetEnvironmentVariable('GLADIATOR_UPLOAD_KEY_PASS', 'Process')
$certificateRequestPath = [IO.Path]::GetTempFileName()
try {
    $storePassword = ConvertFrom-SecureValue $storeSecret
    $keyPassword = if ($keySecret.Length -eq 0) {
        $storePassword
    }
    else {
        ConvertFrom-SecureValue $keySecret
    }
    [Environment]::SetEnvironmentVariable('GLADIATOR_UPLOAD_STORE_PASS', $storePassword, 'Process')
    [Environment]::SetEnvironmentVariable('GLADIATOR_UPLOAD_KEY_PASS', $keyPassword, 'Process')

    # Valida ambas contrasenas accediendo a la clave privada. No envia datos.
    & $keytoolPath -certreq -keystore $keystore.FullName -alias $KeyAlias `
        -storepass:env GLADIATOR_UPLOAD_STORE_PASS -keypass:env GLADIATOR_UPLOAD_KEY_PASS `
        -file $certificateRequestPath
    if ($LASTEXITCODE -ne 0) {
        throw 'No se pudo abrir la clave. Revisa las contrasenas y el alias; no se guardo configuracion.'
    }

    $values = [ordered]@{
        storeFile = $keystore.FullName.Replace('\', '/')
        storePassword = $storePassword
        keyAlias = $KeyAlias
        keyPassword = $keyPassword
    }
    $lines = @('# Configuracion local de firma. No compartir ni subir a Git.')
    foreach ($entry in $values.GetEnumerator()) {
        $lines += $entry.Key + '=' + (ConvertTo-JavaPropertyValue $entry.Value)
    }
    # Java Properties recibe solo ASCII; las tildes y otros caracteres van escapados.
    [IO.File]::WriteAllLines($propertiesPath, [string[]]$lines, [Text.Encoding]::ASCII)
    Write-Host 'Firma configurada en android/key.properties. No compartas ese archivo.'
    Write-Host 'Guarda un respaldo seguro del archivo JKS y las contrasenas.'
}
finally {
    [Environment]::SetEnvironmentVariable('GLADIATOR_UPLOAD_STORE_PASS', $previousStorePassword, 'Process')
    [Environment]::SetEnvironmentVariable('GLADIATOR_UPLOAD_KEY_PASS', $previousKeyPassword, 'Process')
    if (Test-Path -LiteralPath $certificateRequestPath) {
        Remove-Item -LiteralPath $certificateRequestPath
    }
    $storeSecret.Dispose()
    $keySecret.Dispose()
    $storePassword = $null
    $keyPassword = $null
    $values = $null
    $lines = $null
}
