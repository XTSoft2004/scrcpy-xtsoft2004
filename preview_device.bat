@echo off
setlocal enabledelayedexpansion

:: Check if adb is in PATH
where adb >nul 2>nul
if %errorlevel% equ 0 (
    set "ADB_CMD=adb"
    echo ADB detected in system PATH.
) else (
    if exist "%~dp0adb.exe" (
        set "ADB_CMD=%~dp0adb.exe"
        echo ADB not found in system PATH. Using local adb.exe.
    ) else if exist "%LocalAppData%\Android\Sdk\platform-tools\adb.exe" (
        set "ADB_CMD=%LocalAppData%\Android\Sdk\platform-tools\adb.exe"
        echo ADB detected in Android SDK platform-tools.
    ) else (
        echo Error: adb is not in system PATH, local folder, or Android SDK.
        pause
        exit /b 1
    )
)

:: Ensure scrcpy uses the exact same ADB executable to avoid version mismatch daemon kills
set "ADB=%ADB_CMD%"

:: Find scrcpy.exe
if exist "%~dp0scrcpy.exe" (
    set "SCRCPY_CMD=%~dp0scrcpy.exe"
) else (
    where scrcpy >nul 2>nul
    if %errorlevel% equ 0 (
        set "SCRCPY_CMD=scrcpy"
    ) else (
        echo Error: scrcpy.exe was not found.
        pause
        exit /b 1
    )
)

echo.
echo Retrieving connected devices information...
echo Please wait...
echo.

set count=0

:: Temporary storage for device list to avoid delay in rendering table
for /f "tokens=1,2" %%i in ('"%ADB_CMD%" devices') do (
    if "%%j"=="device" (
        set /a count+=1
        set "device[!count!]=%%i"
        
        :: Query model
        set "model=Unknown"
        for /f "delims=" %%a in ('"%ADB_CMD%" -s %%i shell getprop ro.product.model 2^>nul') do (
            set "model=%%a"
            for /f "delims=" %%b in ("!model!") do set "model=%%b"
        )
        set "device_model[!count!]=!model!"
        
        :: Query Android Release Version
        set "android=Unknown"
        for /f "delims=" %%a in ('"%ADB_CMD%" -s %%i shell getprop ro.build.version.release 2^>nul') do (
            set "android=%%a"
            for /f "delims=" %%b in ("!android!") do set "android=%%b"
        )
        set "device_android[!count!]=!android!"
    )
)

if %count% equ 0 (
    echo No devices found. Please ensure USB debugging is enabled on your device.
    echo.
    pause
    exit /b 1
)

:: Display Table Header
echo STT    Ten thiet bi                   Ma thiet bi              Android Release
echo ------------------------------------------------------------------------------
for /l %%k in (1, 1, %count%) do (
    set "col1= [%%k]  "
    set "col1=!col1:~0,6!"
    
    set "temp_model=!device_model[%%k]!"
    set "col2=!temp_model!                                   "
    set "col2=!col2:~0,30!"
    
    set "temp_id=!device[%%k]!"
    set "col3=!temp_id!                               "
    set "col3=!col3:~0,25!"
    
    set "col4=!device_android[%%k]!"
    
    echo !col1!!col2!!col3!!col4!
)
echo ------------------------------------------------------------------------------
echo.

:select_device
set /p "choice=Select a device (1-%count% or 'q' to cancel): "

:: Handle cancel/quit input
if /i "%choice%"=="q" (
    echo Cancelled by user. Exiting...
    timeout /t 2 >nul
    exit /b 0
)

:: Validate input
if not defined device[%choice%] (
    echo Invalid choice. Please try again.
    goto select_device
)

set "selected_device=!device[%choice%]!"
set "selected_model=!device_model[%choice%]!"
set "selected_ver=!device_android[%choice%]!"

:: Parse major Android version to disable audio on Android < 11
set "audio_args="
for /f "delims=." %%a in ("!selected_ver!") do set "major_ver=%%a"
set /a "major_num=major_ver" 2>nul
if !major_num! LSS 11 (
    set "audio_args=--no-audio"
    echo Android version !selected_ver! is less than 11. Disabling audio to avoid errors...
)

:: Force ADB forward tunnel for network/TCP-IP devices to prevent EPIPE/Broken pipe connection errors
set "tunnel_args="
echo "%selected_device%" | findstr ":" >nul
if %errorlevel% equ 0 (
    set "tunnel_args=--force-adb-forward"
    echo TCP/IP device detected. Forcing adb forward tunnel...
)

:run_scrcpy
echo.
echo ------------------------------------------------------------------------------
echo Starting scrcpy preview for %selected_model% (%selected_device%)...
echo Close the window normally to exit. Auto-reconnect triggers if the connection drops.
echo ------------------------------------------------------------------------------
echo.

:: Run scrcpy synchronously to monitor connection and auto-reconnect
"%SCRCPY_CMD%" -s "%selected_device%" %audio_args% %tunnel_args%
set "scrcpy_exit=%errorlevel%"

echo.
echo [scrcpy exited with code %scrcpy_exit%]

:: If user closed scrcpy normally (exit code 0), exit the script.
if %scrcpy_exit% equ 0 (
    echo Preview closed normally. Exiting...
    timeout /t 2 >nul
    exit /b 0
)

:: Check if the device is a TCP/IP device (contains a colon ':')
echo "%selected_device%" | findstr ":" >nul
if %errorlevel% equ 0 (
    echo.
    echo Connection lost or scrcpy failed to start (exit code %scrcpy_exit%).
    echo Attempting to reconnect to %selected_device% in 3 seconds...
    timeout /t 3
    
    :: Attempt to reconnect up to 3 times
    for /l %%g in (1, 1, 3) do (
        echo [Attempt %%g/3] Connecting to %selected_device%...
        "%ADB_CMD%" connect "%selected_device%" | findstr /i "connected" >nul
        if !errorlevel! equ 0 (
            echo Reconnect successful. Restarting preview...
            goto :run_scrcpy
        )
        timeout /t 2 >nul
    )
    
    echo.
    echo Could not reconnect after 3 attempts.
    set /p "retry=Do you want to keep trying? (y/n): "
    if /i "!retry!"=="y" goto :run_scrcpy
) else (
    echo.
    echo Device connection lost or window closed with error. Exiting...
    timeout /t 3 >nul
)
