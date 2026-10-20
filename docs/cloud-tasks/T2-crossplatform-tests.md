# T2 - Tests run unchanged on Windows and Linux

Today RequestSafety, AgentHooks and ReviewRegressions need manual path edits on Linux (backslashes, `src\Requests.ps1`, a hard-coded claude.exe path).

1. Make every test in tests/ build paths with `[IO.Path]::Combine` / `Join-Path` on relative parts and use fixtures for executables, so `pwsh -File tests/X.Tests.ps1` passes on Linux and Windows without edits.
2. Do not weaken assertions. Do not change product code unless a path bug is real on Windows too.
3. Run all tests with pwsh on Linux; all must pass.
4. Push `cloud/t2-tests`, PR into `dev-0.0.3`, summary in Chinese.
