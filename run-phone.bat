@echo off
chcp 65001 >nul
REM ============================================================
REM  情侣点菜 App - 安卓真机 USB 调试（零安装、零改造，今天就能用）
REM
REM  前置：手机「开发者选项 -> USB 调试」打开，数据线连电脑，
REM        首次连接手机上点「允许 USB 调试（本机 RSA 指纹）」。
REM
REM  同样是免打包的：走的是 flutter run 的 debug 增量安装，
REM  改代码按 r 热重载（约 1 秒），不用重新打 release APK。
REM
REM  多台设备时用 -d 指定：
REM    run-phone.bat -d <deviceId>
REM ============================================================
set "PATH=D:\Program Files\Git\bin;%PATH%"
set "JAVA_HOME=D:\dev\jdk17"
set "ANDROID_HOME=D:\dev\android-sdk"
set "ANDROID_SDK_ROOT=D:\dev\android-sdk"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"

set "PROJ=%~dp0app"
cd /d "%PROJ%"

echo.
echo [1/3] 拉取依赖 ...
call D:\dev\flutter\bin\flutter.bat pub get
if errorlevel 1 goto :fail

echo.
echo [2/3] 当前已连接设备：
call D:\dev\flutter\bin\flutter.bat devices

echo.
echo [3/3] 启动真机调试（热重载已开启）...
call D:\dev\flutter\bin\flutter.bat run %*
if errorlevel 1 goto :fail

exit /b 0

:fail
echo.
echo !!! 启动失败 !!!
echo 若列表里没有你的手机：检查数据线、USB 调试开关、手机上是否点了「允许调试」。
pause
exit /b 1
