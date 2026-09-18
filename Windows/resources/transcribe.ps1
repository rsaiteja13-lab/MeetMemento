param(
    [switch]$Probe,
    [string]$InputPath,
    [string]$OutputPath,
    [string]$Language = "en-US"
)

$ErrorActionPreference = "Stop"

function Get-InstalledRecognizers {
    Add-Type -AssemblyName System.Speech
    return @([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers())
}

function Write-ResultFile {
    param([hashtable]$Value)
    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
}

try {
    $installed = Get-InstalledRecognizers

    if ($Probe) {
        $languages = @($installed | ForEach-Object { $_.Culture.Name } | Sort-Object -Unique)
        @{
            available = $languages.Count -gt 0
            languages = $languages
            message = if ($languages.Count -gt 0) { "Windows speech recognition is ready." } else { "Install a Speech language in Windows Settings to create local transcripts." }
        } | ConvertTo-Json -Compress -Depth 4
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($InputPath) -or -not [System.IO.File]::Exists($InputPath)) {
        throw "The transcription audio file was not found."
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw "A transcription output path is required."
    }
    if ($installed.Count -eq 0) {
        Write-ResultFile @{ status = "failed"; language = $Language; segments = @(); error = "No Windows speech language is installed." }
        exit 0
    }

    $selected = $installed | Where-Object { $_.Culture.Name -eq $Language } | Select-Object -First 1
    if ($null -eq $selected) {
        $selected = $installed | Select-Object -First 1
    }

    $recognizer = [System.Speech.Recognition.SpeechRecognitionEngine]::new($selected)
    try {
        $recognizer.InitialSilenceTimeout = [TimeSpan]::FromSeconds(20)
        $recognizer.BabbleTimeout = [TimeSpan]::FromSeconds(5)
        $recognizer.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(700)
        $recognizer.EndSilenceTimeoutAmbiguous = [TimeSpan]::FromMilliseconds(1200)
        $recognizer.LoadGrammar([System.Speech.Recognition.DictationGrammar]::new())
        $recognizer.SetInputToWaveFile([System.IO.Path]::GetFullPath($InputPath))

        $segments = [System.Collections.Generic.List[object]]::new()
        $stalled = 0
        while ($stalled -lt 3) {
            $before = $recognizer.RecognizerAudioPosition.TotalSeconds
            $result = $recognizer.Recognize([TimeSpan]::FromSeconds(20))
            $after = $recognizer.RecognizerAudioPosition.TotalSeconds

            if ($null -ne $result -and -not [string]::IsNullOrWhiteSpace($result.Text)) {
                $start = $before
                if ($null -ne $result.Audio) {
                    $start = $result.Audio.AudioPosition.TotalSeconds
                }
                $segments.Add([ordered]@{
                    start = [Math]::Max(0, [Math]::Round($start, 3))
                    duration = if ($null -ne $result.Audio) { [Math]::Round($result.Audio.Duration.TotalSeconds, 3) } else { 0 }
                    confidence = [Math]::Round($result.Confidence, 3)
                    text = $result.Text.Trim()
                })
            }

            if ($after -le ($before + 0.001)) { $stalled += 1 } else { $stalled = 0 }
        }

        Write-ResultFile @{
            status = if ($segments.Count -gt 0) { "complete" } else { "failed" }
            language = $selected.Culture.Name
            segments = @($segments)
            error = if ($segments.Count -gt 0) { $null } else { "Windows did not detect speech in the saved audio." }
        }
    }
    finally {
        if ($null -ne $recognizer) {
            $recognizer.Dispose()
        }
    }
}
catch {
    if ($Probe) {
        @{ available = $false; languages = @(); message = $_.Exception.Message } | ConvertTo-Json -Compress -Depth 4
        exit 0
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-ResultFile @{ status = "failed"; language = $Language; segments = @(); error = $_.Exception.Message }
        exit 0
    }
    throw
}
