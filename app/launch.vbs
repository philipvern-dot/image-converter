Option Explicit
Dim shell, fso, appDir, root, ps, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(appDir)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -STA -ExecutionPolicy Bypass -File """ & appDir & "\ImageConverter.ps1"""
shell.CurrentDirectory = root
On Error Resume Next
' Style 1 starts the program normally. Style 0 hides this window and the program window with it.
shell.Run cmd, 1, False
If Err.Number <> 0 Then
  MsgBox "Image Converter could not start." & vbCrLf & vbCrLf & Err.Description, vbCritical, "Image Converter"
End If
