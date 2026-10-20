# T1 - GitHub Actions CI on Windows

Goal: every push runs all tests on **windows-latest** with both **Windows PowerShell 5.1** (`powershell`) and **PowerShell 7** (`pwsh`), plus `pwsh` on ubuntu-latest.

1. Add `.github/workflows/tests.yml`. Each test script exits non-zero on failure (they `throw`); make sure the job fails then.
2. Run the suite locally with pwsh first. Where a test only fails because of Windows-vs-Linux paths, leave that to T2 but mark the Linux job `continue-on-error: true` until T2 lands.
3. Fix real failures you find (keep 5.1 compatibility).
4. Push branch `cloud/t1-ci` and open a PR into `dev-0.0.3`. Summarise in Chinese what CI covers and what failed before your fixes.
