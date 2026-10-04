' Launches JayOS AI Usage with no console window.
' Prefers PowerShell 7 (pwsh), then falls back to Windows PowerShell 5.1.
Dim fso, dir, sh

Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")

Function FindPowerShell()
    Dim candidates, i, p
    FindPowerShell = ""
    candidates = Array( _
        sh.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe"), _
        sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"), _
        sh.ExpandEnvironmentStrings("%LocalAppData%\Microsoft\WindowsApps\pwsh.exe"), _
        dir & "\runtime\pwsh\pwsh.exe")
    For i = 0 To UBound(candidates)
        p = candidates(i)
        If Len(p) > 0 And fso.FileExists(p) Then
            FindPowerShell = p
            Exit Function
        End If
    Next
End Function

Dim psExe
psExe = FindPowerShell()
If Len(psExe) = 0 Then psExe = "powershell.exe"

Dim launchArgs
launchArgs = " -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File """ & dir & "\unified-overlay.ps1"" -Background"
If LCase(psExe) = "powershell.exe" Then
    sh.Run "powershell.exe" & launchArgs, 0, False
Else
    sh.Run "conhost.exe --headless """ & psExe & """" & launchArgs, 0, False
End If
