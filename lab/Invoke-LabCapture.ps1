param(
  [Parameter(Mandatory)][string]$Technique,
  [Parameter(Mandatory)][int[]]$TestNumbers,
  [Parameter(Mandatory)][string[]]$ExpectedRules,
  [int]$Runs = 3,
  [hashtable]$InputArgs = @{},
  [string]$OutFile = "C:\Captures\manifest-entries.jsonl"
)
Import-Module "C:\AtomicRedTeam\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1" -Force
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -GetPrereqs -InputArgs $InputArgs | Out-Null

for ($i = 1; $i -le $Runs; $i++) {
  $start = (Get-Date).ToUniversalTime()
  Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -InputArgs $InputArgs
  Start-Sleep -Seconds 20
  $end = (Get-Date).ToUniversalTime()
  Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -Cleanup -InputArgs $InputArgs | Out-Null

  $entry = [ordered]@{
    id             = "lab-$($Technique.ToLower())-t$($TestNumbers -join '_')-r$i"
    technique      = $Technique
    tests          = $TestNumbers
    expected_rules = $ExpectedRules
    host           = $env:COMPUTERNAME
    start          = $start.ToString("o")
    end            = $end.ToString("o")
  }
  ($entry | ConvertTo-Json -Compress) | Add-Content -Path $OutFile
  Start-Sleep -Seconds 30
}
