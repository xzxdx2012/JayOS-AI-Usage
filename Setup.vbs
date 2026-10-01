' JayOS AI Usage - setup wizard. Double-click to install.
' "Setup.vbs /uninstall" removes it (used by Windows "Installed apps").
Dim fso, dir, sh, psExe, extra, i

Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")

Function FindPowerShell()
    Dim candidates, j, p
    FindPowerShell = ""
    candidates = Array( _
        sh.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe"), _
        sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"), _
        sh.ExpandEnvironmentStrings("%LocalAppData%\Microsoft\WindowsApps\pwsh.exe"), _
        dir & "\runtime\pwsh\pwsh.exe")
    For j = 0 To UBound(candidates)
        p = candidates(j)
        If Len(p) > 0 And fso.FileExists(p) Then
            FindPowerShell = p
            Exit Function
        End If
    Next
End Function

psExe = FindPowerShell()
If Len(psExe) = 0 Then psExe = "powershell.exe"

extra = ""
For i = 0 To WScript.Arguments.Count - 1
    If LCase(WScript.Arguments(i)) = "/uninstall" Then extra = " -Uninstall"
Next

sh.Run "conhost.exe --headless """ & psExe & """ -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\Setup.ps1""" & extra, 0, False
