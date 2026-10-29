; SPDX-License-Identifier: GPL-3.0-or-later
; PairDesk setup for Windows: per-user, no administrator rights needed.
;
;   makensis -DVERSION=0.8.0 -DAGENT=path\to\pairdesk-agent.exe -DOUTFILE=PairDesk-Setup.exe installer.nsi
;
; Installs to %LOCALAPPDATA%\Programs\PairDesk with a Start menu shortcut and
; an entry in Settings → Apps. Silent: /S. The agent's updater runs
; "/S /UPDATE", which restarts PairDesk quietly afterwards.

; PairDesk runs on 64-bit Windows only, so the setup is 64-bit too.
Target amd64-unicode
SetCompressor /SOLID lzma
RequestExecutionLevel user
ManifestDPIAware true

!ifndef VERSION
  !error "pass -DVERSION=x.y.z"
!endif
!ifndef AGENT
  !error "pass -DAGENT=path to pairdesk-agent.exe"
!endif
!ifndef OUTFILE
  !define OUTFILE "PairDesk-Setup-${VERSION}-x64.exe"
!endif

!define APP "PairDesk"
!define EXE "pairdesk-agent.exe"
!define UNINSTALLER "Uninstall PairDesk.exe"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\PairDesk"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define URL "https://pairdesk.madhushan.me"

Name "${APP}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\PairDesk"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
BrandingText "${APP} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "PairDesk setup"
VIAddVersionKey "CompanyName" "Sandun Madhushan"
VIAddVersionKey "LegalCopyright" "GPL-3.0-or-later"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define MUI_ICON "..\icons\pairdesk.ico"
!define MUI_UNICON "..\icons\pairdesk.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_WELCOMEPAGE_TITLE "Control this computer from your phone"
!define MUI_WELCOMEPAGE_TEXT "Setup will install PairDesk ${VERSION} for you (no administrator rights needed).$\r$\n$\r$\nAfterwards PairDesk opens a pairing code. Scan it with the PairDesk app on your phone, and you're done."
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Start PairDesk and pair my phone"
!define MUI_FINISHPAGE_LINK "pairdesk.madhushan.me: get the phone app"
!define MUI_FINISHPAGE_LINK_LOCATION "${URL}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var Update

; Stops a running PairDesk (any copy: installed or downloaded) and waits
; until it has let go of its files.
!macro StopPairDesk EXE_PATH
  DetailPrint "Stopping PairDesk if it is running…"
  nsExec::Exec '"${EXE_PATH}" --quit'
  Pop $0
!macroend

Function .onInit
  StrCpy $Update 0
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/UPDATE" $R1
  ${IfNot} ${Errors}
    StrCpy $Update 1
  ${EndIf}
FunctionEnd

Section "PairDesk" Main
  SectionIn RO
  ; The new program stops the old one through its settings page (works with
  ; every release since 0.2.0), from a temporary copy.
  InitPluginsDir
  File "/oname=$PLUGINSDIR\${EXE}" "${AGENT}"
  !insertmacro StopPairDesk "$PLUGINSDIR\${EXE}"

  SetOutPath "$INSTDIR"
  ; The old program may take a moment to exit and release its file.
  StrCpy $R2 0
  retry:
    ClearErrors
    File "/oname=${EXE}" "${AGENT}"
    ${If} ${Errors}
      IntOp $R2 $R2 + 1
      ${If} $R2 < 20
        Sleep 500
        Goto retry
      ${EndIf}
      ${IfNot} ${Silent}
        MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "PairDesk is still running. Stop it from its tray icon (Stop PairDesk), then press Retry." IDRETRY retry
      ${EndIf}
      Abort "Couldn't replace ${EXE}: PairDesk is still running."
    ${EndIf}
  File "/oname=pairdesk.ico" "..\icons\pairdesk.ico"
  File "/oname=LICENSE.txt" "..\..\LICENSE"

  WriteUninstaller "$INSTDIR\${UNINSTALLER}"
  CreateShortCut "$SMPROGRAMS\PairDesk.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0 SW_SHOWNORMAL "" "Control this computer from your phone"

  ; Settings → Apps
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Sandun Madhushan"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${EXE},0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\${UNINSTALLER}"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\${UNINSTALLER}" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${URL}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "HelpLink" "https://github.com/sandunMadhushan/pairdesk/issues"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"

  ; Silent installs don't show the Finish page: start PairDesk quietly.
  ${If} ${Silent}
    ${If} $Update == 1
      Exec '"$INSTDIR\${EXE}" --background --updated'
    ${Else}
      Exec '"$INSTDIR\${EXE}" --background'
    ${EndIf}
  ${EndIf}
SectionEnd

Section "Uninstall"
  !insertmacro StopPairDesk "$INSTDIR\${EXE}"
  ; The optional helper service (sign-in screen and admin prompts) lives in
  ; Program Files; removing it needs administrator rights, so Windows asks.
  ClearErrors
  ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Services\PairDesk" "ImagePath"
  ${IfNot} ${Errors}
    DetailPrint "Removing the PairDesk helper service…"
    ExecShellWait "runas" "$INSTDIR\${EXE}" "--uninstall-service" SW_HIDE
  ${EndIf}
  ; Start at sign-in and "Send to → PairDesk phone" are added by PairDesk
  ; itself; remove them only if they point at this copy.
  ReadRegStr $0 HKCU "${RUN_KEY}" "PairDesk"
  StrCpy $1 '"$INSTDIR\${EXE}"'
  StrLen $2 $1
  StrCpy $3 $0 $2
  ${If} $3 == $1
    DeleteRegValue HKCU "${RUN_KEY}" "PairDesk"
  ${EndIf}
  Delete "$APPDATA\Microsoft\Windows\SendTo\PairDesk phone.lnk"
  Delete "$SMPROGRAMS\PairDesk.lnk"

  Delete "$INSTDIR\${EXE}"
  Delete "$INSTDIR\.${EXE}.old*"
  Delete "$INSTDIR\.${EXE}.download"
  Delete "$INSTDIR\pairdesk.ico"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\${UNINSTALLER}"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"

  ${IfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "Also delete PairDesk's settings and the list of paired phones?$\r$\n$\r$\nChoose No to keep them for a later reinstall. Received files in Downloads\PairDesk are kept either way." IDNO keep
    RMDir /r "$APPDATA\PairDesk"
    keep:
  ${EndIf}
SectionEnd
