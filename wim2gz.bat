@echo off
title WIM一键转换GZ（Windows DD包制作工具）
SETLOCAL ENABLEDELAYEDEXPANSION

:: 检查是否以管理员权限运行
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo 请以管理员身份运行此脚本！
    pause
    exit
)

:START
echo 请输入当前目录下wim/esd文件的文件名（例如：win2008.wim），然后按回车键:
set /p InputFileName=
set "InputPath=%~dp0%InputFileName%"

REM 检查文件是否存在
if not exist "%InputPath%" (
    echo 错误: 文件不存在。
    echo.
    goto START
)

FOR %%i IN ("%InputPath%") DO (
    set "DirPath=%%~dpi"        :: 提取文件的文件夹路径
    set "FileNameNoExt=%%~ni"   :: 提取不包含扩展名的文件名
    set "FullPathWithExt=%%~fi" :: 提取完整的文件路径（包含文件名和扩展名）
    set "FileExtension=%%~xi"   :: 提取文件的扩展名（.wim）
)
:: 判断文件扩展名是否为.wim或.esd
if /I "%FileExtension%"==".wim" (
    echo 输入的文件是一个.wim文件。
) else if /I "%FileExtension%"==".esd" (
    echo 输入的文件是一个.esd文件。
) else (
    echo 错误: 请输入一个.wim或.esd文件。
    echo.
    goto START
)

:: 获取WIM文件的信息并列出所有版本
echo 正在获取WIM文件的版本信息...
dism /Get-WimInfo /WimFile:"%FullPathWithExt%"

:: 提示用户选择一个版本
echo.
echo 请输入上述列表中的版本号（例如：1、2、3...）然后按回车键:
set /p selectedIndex=

:: 初始化版本大小变量
set "ChosenSize="

:: 获取WIM文件的大小
for /F "tokens=*" %%a in ('dism /Get-WimInfo /WimFile:"%FullPathWithExt%"') do (
    echo %%a | findstr /R /C:"[0-9][0-9]*,[0-9][0-9]*,[0-9][0-9]*" >nul
    if not errorlevel 1 (
        REM 提取数字并移除逗号
        for /F "tokens=2 delims=: " %%b in ("%%a") do (
            set "num=%%b"
            set "num=!num:,=!"
            if not defined ChosenSize[%selectedIndex%] (
                set "ChosenSize[%selectedIndex%]=!num!"
            )
        )
    )
)

:: 检查是否成功获取所选版本的大小
if not defined ChosenSize[%selectedIndex%] (
    echo 错误: 所选版本号无效。
    goto START
)

:: 让用户设置WIM镜像密码
:PromptPassword
set /p "UserPassword=请输入您想为WIM文件镜像系统设置的新密码，然后按回车键："
set "valid=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
set "is_valid=true"
for /l %%i in (0,1,255) do (
    set "char=!UserPassword:~%%i,1!"
    if "!char!"=="" (
        goto PromptPassword_check_valid
    )
    echo "!valid!" | findstr /c:"!char!" > nul || (
        set "is_valid=false"
        goto PromptPassword_check_valid
    )
)

:: 遍历所有字符检查密码是否有效
:PromptPassword_check_valid
if "!is_valid!"=="true" (
    echo 输入成功，您的密码是: !UserPassword!
) else (
    echo 输入错误，密码只能包含大小写字母、数字以及以下符号: . - _
    echo.
    goto PromptPassword
)

:: 使用PowerShell转换选择的版本大小到MB和GB
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    for /f "tokens=*" %%i in ('powershell -command "$bytes = !ChosenSize[%selectedIndex%]!; $MB = [math]::Floor($bytes / 1MB); $MB"') do (
        set MB=%%i
    )
    :: 计算wim镜像展开后大小并显示
    set /a WimGB=MB/1024
    set /a WimRemainingMB=MB%%1024
    set WimTotalSize=!WimGB!.!WimRemainingMB!
    echo wim镜像展开后大小： !WimTotalSize! GB
    :: 增加VHD大小以容纳KVM驱动
    set /a MB+=512
) else (
    echo 未检测到PowerShell，将直接使用默认值（16GB）创建VHD。
    set MB=16384
)

:: 计算VHD文件大小并显示
set /a TotalGB=MB/1024
set /a RemainingMB=MB%%1024
set TotalSize=!TotalGB!.!RemainingMB!
echo VHD文件大小为： !TotalSize! GB

:: 把新的VHD文件大小进行赋予变量
SET DiskSizeMB=!MB!

REM 根据输入的文件名组合出新的VHD路径
set "VHDPath=%DirPath%%FileNameNoExt%.vhd"
echo VHD文件路径: %VHDPath%

:: 根据WIM大小创建VHD文件并挂载
echo 正在创建VHD文件...
(
    echo create vdisk file="%VHDPath%" maximum=%DiskSizeMB% type=fixed
    echo select vdisk file="%VHDPath%"
    echo attach vdisk
    echo create partition primary
    echo format fs=ntfs quick label="VHDVolume"
    echo assign
    echo exit
) | diskpart

REM 获取新建的VHD的盘符
for /f "tokens=2 delims== " %%a in ('wmic logicaldisk where "VolumeName='VHDVolume'" get DeviceID /value') do set DiskDrive=%%a

if not defined DiskDrive (
    echo 错误: 获取VHD驱动器字母失败。
    exit /b
)

REM 使用dism释放镜像到新的VHD
echo 正在向新VHD释放选定的镜像版本...
dism /apply-image /imagefile:"%FullPathWithExt%" /index:%selectedIndex% /ApplyDir:%DiskDrive%\
if errorlevel 1 (
    echo 错误: 镜像应用失败。
    pause
    exit /b
)

:: 创建SetupComplete.cmd脚本（安装最后阶段自动执行脚本）
echo 开始创建 "SetupComplete.cmd" 文件...
:: 检查目录是否存在，如果不存在则创建
if not exist "%DiskDrive%\Windows\Setup\Scripts" mkdir "%DiskDrive%\Windows\Setup\Scripts"
(
    echo @echo off
    echo :: 自动扩容剩余硬盘空间
    echo echo Selecting Disk 0...
    echo (
    echo echo list volume
    echo echo select volume C
    echo echo extend
    echo ^) ^| diskpart
    echo :: 允许通过远程桌面协议 ^(RDP^) 连接到此计算机
    echo reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
    echo :: 决定是否要求使用网络级别的身份验证 ^(NLA^) 来连接到此计算机
    echo reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f
    echo :: 禁用 “Ctrl+Alt+Delete” 登录序列 ^(Policies\System^)
    echo reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v disablecad /t REG_DWORD /d 1 /f
    echo :: 关闭防火墙
    echo netsh advfirewall set allprofiles state off
    echo :: 关闭Edge提示“此版本Windows不再受支持”
    echo REG ADD "HKLM\SOFTWARE\Policies\Microsoft\EDGE" /v "SuppressUnsupportedOSWarning" /t REG_DWORD /d 1 /f
    echo :: 关闭Internet Explorer增强安全配置 ^(对于管理员^)
    echo REG ADD "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" /v "IsInstalled" /t REG_DWORD /d 0 /f
    echo :: 关闭Internet Explorer增强安全配置 ^(对于用户^)
    echo REG ADD "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" /v "IsInstalled" /t REG_DWORD /d 0 /f
) >> "%DiskDrive%\Windows\Setup\Scripts\SetupComplete.cmd"
echo "SetupComplete.cmd" 文件已创建成功!

:: 创建无人值守文件目录，如果不存在
if not exist %DiskDrive%\Windows\Panther mkdir %DiskDrive%\Windows\Panther
echo 正在生成自动应答文件...
(
echo ^<^?xml version="1.0" encoding="utf-8"?^>
echo ^<unattend xmlns="urn:schemas-microsoft-com:unattend"^>
echo    ^<settings pass="oobeSystem"^>
echo        ^<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"^>
echo            ^<OOBE^>
echo                ^<HideEULAPage^>true^</HideEULAPage^>
echo                ^<NetworkLocation^>Other^</NetworkLocation^>
echo                ^<ProtectYourPC^>3^</ProtectYourPC^>
echo                ^<SkipMachineOOBE^>true^</SkipMachineOOBE^>
echo                ^<SkipUserOOBE^>true^</SkipUserOOBE^>
echo            ^</OOBE^>
echo            ^<UserAccounts^>
echo                ^<AdministratorPassword^>
echo                    ^<PlainText^>true^</PlainText^>
echo                    ^<Value^>%UserPassword%^</Value^>
echo                ^</AdministratorPassword^>
echo            ^</UserAccounts^>
echo        ^</component^>
echo    ^</settings^>
echo    ^<settings pass="specialize"^>
echo        ^<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"^>
echo            ^<RunSynchronous^>
echo                ^<RunSynchronousCommand wcm:action="add"^>
echo                    ^<Order^>1^</Order^>
echo                    ^<Path^>net user Administrator /active:Yes^</Path^>
echo                    ^<WillReboot^>Never^</WillReboot^>
echo                ^</RunSynchronousCommand^>
echo            ^</RunSynchronous^>
echo        ^</component^>
echo    ^</settings^>
echo    ^<settings pass="windowsPE"^>
echo        ^<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"^>
echo            ^<Diagnostics^>
echo                ^<OptIn^>false^</OptIn^>
echo            ^</Diagnostics^>
echo            ^<DynamicUpdate^>
echo                ^<WillShowUI^>OnError^</WillShowUI^>
echo            ^</DynamicUpdate^>
echo            ^<ImageInstall^>
echo                ^<OSImage^>
echo                    ^<WillShowUI^>OnError^</WillShowUI^>
echo                    ^<InstallFrom^>
echo                        ^<MetaData wcm:action="add"^>
echo                            ^<Key^>/IMAGE/INDEX^</Key^>
echo                            ^<Value^>1^</Value^>
echo                        ^</MetaData^>
echo                    ^</InstallFrom^>
echo                ^</OSImage^>
echo            ^</ImageInstall^>
echo            ^<UserData^>
echo                ^<AcceptEula^>true^</AcceptEula^>
echo            ^</UserData^>
echo        ^</component^>
echo    ^</settings^>
echo ^</unattend^>
) > %DiskDrive%\Windows\Panther\unattend.xml
echo 自动应答文件已成功生成并放置！

:: 检查virtio-win.iso是否存在
if not exist "%~dp0virtio-win.iso" (
    echo virtio-win.iso 不存在，开始下载...
    powershell Invoke-WebRequest -Uri https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso -OutFile "%~dp0virtio-win.iso"
    if errorlevel 1 (
        echo 错误: 下载 virtio-win.iso 失败。
        pause
        exit /b
    )
)

:: 检查7-Zip是否已经安装
reg query "HKEY_LOCAL_MACHINE\SOFTWARE\7-Zip" /v Path >nul 2>&1
if %errorlevel% NEQ 0 (
    echo 7-Zip 未安装，正在下载并安装...
    powershell Invoke-WebRequest -Uri https://www.7-zip.org/a/7z2301-x64.exe -OutFile "%~dp07z2301-x64.exe"
    
    if errorlevel 1 (
        echo 错误: 下载7-Zip失败。
        pause
        exit /b
    )
    "%~dp07z2301-x64.exe" /S
    
    if errorlevel 1 (
        echo 错误: 安装7-Zip失败。
        pause
        exit /b
    )
    del "%~dp07z2301-x64.exe"
) else (
    echo 7-Zip 已安装。
)

:: 使用7zip解压virtio-win.iso到同名目录
echo 正在解压 virtio-win.iso...
"C:\Program Files\7-Zip\7z.exe" x "%~dp0virtio-win.iso" -o"%~dp0virtio-win" -aoa
if errorlevel 1 (
    echo 错误: 解压 virtio-win.iso 失败。
    pause
    exit /b
) else (
    echo virtio-win.iso 解压成功。
)

:: 将驱动注入到已释放到 VHD 的 Windows 映像中（这里不能去判断是否注入成功）
echo 正在添加KVM驱动...
dism /Image:%DiskDrive%\ /Add-Driver /Driver:"%~dp0virtio-win" /Recurse

:: 删除解压出的驱动文件夹
echo 删除解压的驱动文件夹...
rd /s /q "%~dp0virtio-win"

REM 使用bcdboot添加VHD引导
echo 正在使用bcdboot复制MBR/BIOS启动文件...
bcdboot %DiskDrive%\Windows /s %DiskDrive% /f BIOS

:: 从路径 \Device\Harddisk1\Partition1 中，磁盘编号为 1，分区编号为 1
set "DiskNumber=1"
set "PartitionNumber=1"
:: 使用 diskpart 将分区设置为活动状态
(
    echo select disk %DiskNumber%
    echo select partition %PartitionNumber%
    echo active
    echo exit
) | diskpart

echo 正在卸载VHD...
(
    echo select vdisk file="%VHDPath%"
    echo detach vdisk
    echo exit
) | diskpart

REM 使用7zip压缩VHD文件
echo 正在压缩VHD文件...
"C:\Program Files\7-Zip\7z.exe" a -tgzip -mx=1 "%VHDPath%.gz" "%VHDPath%"
if errorlevel 1 (
    echo 错误: VHD压缩失败。
    pause
    exit /b
)

:: 删除新生成的VHD文件
echo 正在清理临时VHD文件...
del "%VHDPath%"

echo 完成！
ENDLOCAL
pause
