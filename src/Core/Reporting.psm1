Set-StrictMode -Version 2.0

function Test-ReportSensitiveProperty { param([string]$Name);return ($Name -match '(?i)token|secret|password|passwd|credential|auth|private.?key|ssh|api.?key|access.?key') }
function Protect-ReportString {
    param([string]$Value)
    if($null -eq $Value){return $null}
    $safe=$Value -replace '(?i)(bearer\s+)[^\s;]+','$1[REDACTED]'
    $safe=$safe -replace '(?i)((?:token|secret|password|passwd|api[_-]?key|access[_-]?key)\s*[:=]\s*)[^\s,;]+','$1[REDACTED]'
    return $safe
}
function ConvertTo-SafeReportValue {
    param($Value,[string]$PropertyName='')
    if(Test-ReportSensitiveProperty $PropertyName){return '[REDACTED]'}
    if($null -eq $Value){return $null}
    if($Value -is [string]){return Protect-ReportString ([string]$Value)}
    if($Value -is [System.Collections.IDictionary]){$out=[ordered]@{};foreach($key in $Value.Keys){$out[$key]=ConvertTo-SafeReportValue $Value[$key] ([string]$key)};return [pscustomobject]$out}
    if($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Array] -and $Value.GetType().GetElementType().IsPrimitive)){$items=@();foreach($item in $Value){$items+=ConvertTo-SafeReportValue $item $PropertyName};return $items}
    if(@($Value.PSObject.Properties).Count -gt 0 -and -not ($Value -is [ValueType])){$out=[ordered]@{};foreach($property in $Value.PSObject.Properties){$out[$property.Name]=ConvertTo-SafeReportValue $property.Value $property.Name};return [pscustomobject]$out}
    return $Value
}
function ConvertTo-SafeReportObject { param($Configuration,$Discovery,$Findings,$Plan,$GeneratedAt)
    $raw=[pscustomobject][ordered]@{SchemaVersion=1;GeneratedAt=$GeneratedAt;ReadOnly=$true;Machine=$Discovery.Windows;Findings=@($Findings);Plan=@($Plan);Discovery=$Discovery}
    return ConvertTo-SafeReportValue $raw
}
function ConvertTo-MarkdownAuditReport { param($Report)
    $lines=@('# DevData Bootstrapper Audit Report','',("Generated: {0}" -f $Report.GeneratedAt),'','Read-only audit: no machine configuration was changed.','',"## Summary",'');
    $groups=@($Report.Findings | Group-Object Status | Sort-Object Name); foreach($g in $groups){$lines += ('- **{0}:** {1}' -f $g.Name,$g.Count)}; $lines += @('','## Findings','');
    foreach($finding in $Report.Findings){$lines += @('### {0} — {1}' -f $finding.Status,$finding.Component,'',('| Field | Value |','|---|---|',('| Classification | {0} |' -f ([string]$finding.Classification -replace '\|','\|')),('| Expected | {0} |' -f ([string]$finding.ExpectedState -replace '\|','\|')),('| Actual | {0} |' -f ([string]$finding.ActualState -replace '\|','\|')),('| Recommended action | {0} |' -f ([string]$finding.RecommendedAction -replace '\|','\|')),('| Safe to automate | {0} |' -f $finding.SafeToAutomate),'') )}
    return ($lines -join "`r`n")
}
function Write-AuditReports { param([Parameter(Mandatory=$true)]$Report,[Parameter(Mandatory=$true)][string]$OutputRoot)
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$json=Join-Path $OutputRoot ("audit-{0}.json" -f $stamp);$md=Join-Path $OutputRoot ("audit-{0}.md" -f $stamp)
    $Report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $json -Encoding UTF8
    ConvertTo-MarkdownAuditReport $Report | Set-Content -LiteralPath $md -Encoding UTF8
    [pscustomobject]@{JsonPath=$json;MarkdownPath=$md;Timestamp=$stamp}
}
Export-ModuleMember -Function ConvertTo-SafeReportObject,ConvertTo-MarkdownAuditReport,Write-AuditReports,ConvertTo-SafeReportValue,Protect-ReportString
