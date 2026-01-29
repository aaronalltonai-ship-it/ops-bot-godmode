param(
  [string],
  [string],
  [string],
  [string]
)

 = Get-Content  -Raw
# TODO: replace with your actual Cody CLI command.
# Response must be written to the output file and exit code must reflect success.
 = & cody-cli --prompt   2>&1
if ( -ne 0) {
  Write-Host Cody dispatch failed: 
  exit 1
}
 | Out-File -FilePath  -Encoding ascii
exit 0
