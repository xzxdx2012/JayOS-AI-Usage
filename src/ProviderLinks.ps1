# ProviderLinks.ps1 - official per-provider usage + install/docs catalog
#
# One shared menu shape (provider → Usage + Docs). Labels and URLs vary by vendor
# on purpose. Hidden HUD tiles still keep their links here.

function Get-ProviderLinkCatalog {
    [ordered]@{
        claude = [ordered]@{
            Id    = 'claude'
            Label = 'Claude'
            Usage = [ordered]@{ Kind = 'Usage'; Label = 'Usage'; Url = 'https://claude.ai/settings/usage' }
            Docs  = [ordered]@{ Kind = 'Docs';  Label = 'Install Claude Code'; Url = 'https://docs.anthropic.com/en/docs/claude-code' }
        }
        codex = [ordered]@{
            Id    = 'codex'
            Label = 'Codex'
            Usage = [ordered]@{ Kind = 'Usage'; Label = 'ChatGPT Codex'; Url = 'https://chatgpt.com/codex' }
            Docs  = [ordered]@{ Kind = 'Docs';  Label = 'Install Codex CLI'; Url = 'https://developers.openai.com/codex/cli' }
        }
        cursor = [ordered]@{
            Id    = 'cursor'
            Label = 'Cursor'
            Usage = [ordered]@{ Kind = 'Usage'; Label = 'Dashboard'; Url = 'https://cursor.com/settings' }
            Docs  = [ordered]@{ Kind = 'Docs';  Label = 'Cursor docs'; Url = 'https://cursor.com/docs' }
        }
        grok = [ordered]@{
            Id    = 'grok'
            Label = 'Grok'
            Usage = [ordered]@{ Kind = 'Usage'; Label = 'Console / billing'; Url = 'https://console.x.ai' }
            Docs  = [ordered]@{ Kind = 'Docs';  Label = 'Install Grok CLI'; Url = 'https://x.ai/docs/build/overview' }
        }
    }
}

function Get-ProviderLinkUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][ValidateSet('Usage', 'Docs')][string]$Kind
    )

    $catalog = Get-ProviderLinkCatalog
    $id = $Provider.ToLowerInvariant()
    if (-not $catalog.Contains($id)) { return $null }

    $entry = $catalog[$id]
    if ($Kind -eq 'Usage') { return [string]$entry.Usage.Url }
    return [string]$entry.Docs.Url
}

function Get-ProviderLinkMenuShape {
    # Uniform tray shape: every provider contributes Usage then Docs, catalog order.
    $items = [System.Collections.Generic.List[object]]::new()
    $catalog = Get-ProviderLinkCatalog
    foreach ($id in @($catalog.Keys)) {
        $entry = $catalog[$id]
        foreach ($link in @($entry.Usage, $entry.Docs)) {
            $items.Add([pscustomobject]@{
                ProviderId    = [string]$entry.Id
                ProviderLabel = [string]$entry.Label
                Kind          = [string]$link.Kind
                Label         = [string]$link.Label
                Url           = [string]$link.Url
            })
        }
    }
    return @($items)
}

function Open-ProviderLink {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][ValidateSet('Usage', 'Docs')][string]$Kind
    )

    $url = Get-ProviderLinkUrl -Provider $Provider -Kind $Kind
    if ($url) { Start-Process $url }
}
