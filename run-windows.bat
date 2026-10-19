@echo off
chcp 65001 >nul
REM ============================================================
REM  情侣点菜 App - Windows 桌面端调试（推荐）
REM  双击运行即可。省掉打 APK，改代码后在窗口里：
REM    r  = 热重载（约 1 秒）   R = 热重启   q = 退出
REM
REM  额外参数原样传给 flutter，例如连本机后端：
REM    run-windows.bat --dart-define=BASE_URL=http://127.0.0.1:3000
REM
REM  默认不传 --dart-define 时，服务器地址仍是线上 food.fmcoral.com。
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
echo [1/2] 拉取依赖 ...
call D:\dev\flutter\bin\flutter.bat pub get
if errorlevel 1 goto :fail

echo.
echo [2/2] 启动 Windows 桌面端（热重载已开启）...
call D:\dev\flutter\bin\flutter.bat run -d windows %*
if errorlevel 1 goto :fail

exit /b 0

:fail
echo.
echo !!! 启动失败，请把上面的报错发出来 !!!
echo 若是 .plugin_symlinks 相关报错：请在 Windows 设置里打开「开发者模式」后重试。
pause
exit /b 1
