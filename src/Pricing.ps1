# Pricing.ps1 - API cost estimation (references $script:Prices from Config.ps1)

function Estimate-Cost([string]$name, $v) {
    if ($name -eq '<synthetic>') { return 0.0 }
    if (-not $script:Prices) { throw 'Estimate-Cost: $script:Prices not loaded - dot-source Config.ps1 first.' }
    if     ($name -match 'fable')  { $tier = 'fable'  }
    elseif ($name -match 'opus')   { $tier = 'opus'   }
    elseif ($name -match 'haiku')  { $tier = 'haiku'  }
    elseif ($name -match 'sonnet') { $tier = 'sonnet' }
    else {
        $tier = 'sonnet'
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Unknown model '$name' - falling back to sonnet pricing (verify prices)"
        }
    }
    $p = $script:Prices[$tier]
    return ([double]$v.inputTokens              / 1e6 * $p.in)  +
           ([double]$v.outputTokens             / 1e6 * $p.out) +
           ([double]$v.cacheCreationInputTokens / 1e6 * $p.cw)  +
           ([double]$v.cacheReadInputTokens      / 1e6 * $p.cr)
}
