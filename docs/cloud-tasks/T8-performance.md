# T8 - Poll performance

The notch polls about every 300 ms (Invoke-RequestPoll in src/Requests.ps1, hover poll in src/UnifiedTray.ps1). Measure (with pwsh, stubbing WPF) how much work one idle poll does: file system calls, Get-Process calls, JSON parses. Reduce idle cost (e.g. skip work when the requests folder's LastWriteTime and file count are unchanged, cache Get-Process lookups for a few seconds) without delaying a new request card by more than one poll. Add tests for the caching. Push `cloud/t8-perf`, PR into `dev-0.0.3`, summary in Chinese with before/after numbers.
