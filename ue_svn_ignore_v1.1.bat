@echo off
rem ================================================================
rem  本文件必须保存为 ANSI / GBK (代码页 936) 编码，否则中文会乱码。
rem  不要用 UTF-8 保存，cmd 解析 UTF-8 编码的 bat 会出错。
rem ================================================================
setlocal enabledelayedexpansion
set "SELF=%~nx0"
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLDCP=%%A"
chcp 936 >nul

rem ================================================================
rem  ue_svn_ignore.bat  -  UE 工程 SVN 排除 / 清理工具
rem
rem  作用：让下面这些内容不再出现在 SVN 提交列表中（整个工作副本递归生效）
rem      Binaries          (目录，递归)
rem      DerivedDataCache  (目录，递归)
rem      Intermediate      (目录，递归)
rem      Saved             (目录，递归)
rem      .vs               (目录，递归)
rem      .vsconfig
rem      *.sln
rem
rem  例外（白名单）：脚本中部可配置"不排除"的路径，白名单里的文件即使位于
rem        被排除的目录（如 Binaries）之下，也会被强制加入版本控制，从而
rem        重新出现在提交列表中。格式见 "白名单" 配置段。
rem
rem  原理：把上述规则写进工作副本根目录的 svn:global-ignores 属性。
rem        该属性会被所有子目录继承，所以等价于"递归排除"，
rem        TortoiseSVN 的提交对话框和 svn status 都会自动跳过它们。
rem
rem  注意：忽略属性只对"未纳入版本控制"的内容有效。
rem        如果某些目标已经被加进了版本库（提交列表里显示 A / M / D），
rem        必须先移出版本控制，否则它们依然会出现在提交列表中。
rem        脚本会递归扫描整棵工作副本（含 Plugins 等子目录），
rem        只要同名目录 / 文件已经纳入版本控制，就会被移出版本控制。
rem
rem  用法（可直接双击）：
rem      ue_svn_ignore.bat                设置排除规则；若发现目标已被纳入
rem                                       版本控制，会列出并询问怎么处理
rem      ue_svn_ignore.bat /ignore        只设置排除规则，绝不删除任何东西
rem      ue_svn_ignore.bat /fix           设置排除规则，并把已被纳入版本控制
rem                                       的目标直接移出版本控制（本地文件保留）
rem      ue_svn_ignore.bat /path "D:\WC"  对指定的工作副本根目录执行
rem
rem  说明：移出版本控制只是本地"待删除"状态，需要提交一次才真正写进仓库；
rem        本地文件不会被删，随时可以对"显示 D 的那个目录 / 文件"执行
rem        svn revert -R "<路径>" 撤销（-R 后面必须带路径）。
rem ================================================================

set "ROOT=%~dp0"
set "MODE=ask"
rem ================================================================
rem  白名单：不排除的路径（可自行增删，每行一条）
rem
rem  格式：每行一条，路径相对工作副本根目录，照抄下面这行的写法改路径即可。
rem        文件：call :KEEP_ADD "Plugins\X\Binaries\ThirdParty\Win64\X.dll"
rem        目录：call :KEEP_ADD "Plugins\X\Binaries\ThirdParty\Win64"
rem
rem  作用：白名单里的文件 / 目录会被强制加入版本控制；即使它位于 Binaries
rem        这类被排除的目录里，也会重新出现在 SVN 提交列表中。
rem        同时把它的各级父目录一起加入版本控制，并给"被排除目录"（如 Binaries）
rem        及其下面的父目录设置 svn:ignore = *，让同级的其它内容继续隐藏。
rem
rem  注意：路径本地必须存在，否则脚本会提示跳过。
rem        如果之前跑过 /fix，把它或它的父目录移出了版本控制（提交列表里显示 D），
rem        先对"最上层显示 D 的那个目录"执行恢复（注意 -R 后面必须带路径）：
rem            svn revert -R "<最上层显示 D 的路径，例如 ...\Plugins\XXX\Binaries>"
rem        若提示 "without reverting parent"，说明路径选得不够上层，换成父目录再试。
rem        revert 会把文件内容恢复成版本库里的旧版本；本地换过 DLL 的话先备份，
rem        恢复后把新文件覆盖回来再提交。
rem ================================================================
set /a KEEP_COUNT=0
call :KEEP_ADD "Plugins\UnrealPackTimeVerification\Binaries\ThirdParty\Win64\TimeVerificationCrypto.dll"

:PARSE
if "%~1"=="" goto PARSE_DONE
if /i "%~1"=="/ignore" ( set "MODE=ignore" & shift & goto PARSE )
if /i "%~1"=="/fix"    ( set "MODE=fix"    & shift & goto PARSE )
if /i "%~1"=="/path"   ( set "ROOT=%~2"    & shift & shift & goto PARSE )
if /i "%~1"=="/?"      goto USAGE
echo [错误] 无法识别的参数：%~1
goto USAGE
:PARSE_DONE

rem ---- svn 返回的路径用的是正斜杠，这里统一成反斜杠 ----
set "ROOT=%ROOT:/=\%"

rem ---- 去掉路径结尾的反斜杠，避免 "路径\" 被 svn 误解析 ----
if "%ROOT:~-1%"=="\" (
    set "R=%ROOT:~0,-1%"
    if "!R:~-1!"==":" set "R=!R!\"
    set "ROOT=!R!"
)

where svn >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 svn.exe。
    echo        请安装 TortoiseSVN 并勾选 "command line client tools"，
    echo        或安装 Apache Subversion 命令行版，并确保 svn.exe 在 PATH 中。
    goto END
)

if not exist "%ROOT%\" (
    echo [错误] 目录不存在：%ROOT%
    goto END
)
cd /d "%ROOT%"

rem ---- 定位工作副本根目录（脚本可以放在工程根目录直接双击）----
set "WCROOT="
for /f "usebackq delims=" %%R in (`svn info --show-item wc-root "%ROOT%" 2^>nul`) do set "WCROOT=%%R"
if not defined WCROOT (
    echo [错误] 这个目录不是 SVN 工作副本：%ROOT%
    echo        请把本 bat 放到 UE 工程根目录（里面有 .svn 目录）再运行，
    echo        或用  ue_svn_ignore.bat /path "工作副本根目录"  指定路径。
    goto END
)
set "WCROOT=%WCROOT:/=\%"
if /i not "%WCROOT%"=="%ROOT%" echo [提示] 目标不是工作副本根目录，已自动切换到：%WCROOT%

echo ================================================================
echo 工作副本：%WCROOT%
echo 模式：%MODE%
echo ================================================================
echo.

rem ================= 第 1 步：写入递归排除规则 =================
echo [1/3] 正在设置递归排除规则 svn:global-ignores ...

set "IGN_FILE=%TEMP%\ue_svn_ignores_%RANDOM%%RANDOM%.txt"
(
    echo Binaries
    echo DerivedDataCache
    echo Intermediate
    echo Saved
    echo .vs
    echo .vsconfig
    echo *.sln
) > "%IGN_FILE%"

svn propset svn:global-ignores --file "%IGN_FILE%" "%WCROOT%"
set "PS_RC=%ERRORLEVEL%"
del /f /q "%IGN_FILE%" >nul 2>&1

if not "%PS_RC%"=="0" (
    echo [错误] 设置 svn:global-ignores 失败，请检查上面的报错信息。
    goto END
)
echo       排除规则已生效，当前内容为：
for /f "usebackq delims=" %%P in (`svn propget svn:global-ignores "%WCROOT%" 2^>nul`) do echo           %%P
echo.

rem ================= 第 2 步：处理白名单（不排除的路径） =================
echo [2/3] 正在处理白名单（不排除的路径）...
set /a KEEP_FAILED=0
set /a PROT_COUNT=0
if %KEEP_COUNT%==0 goto KEEP_SKIP
echo       白名单条目：
for /l %%I in (1,1,%KEEP_COUNT%) do echo           !KEEP_%%I!
for /l %%I in (1,1,%KEEP_COUNT%) do call :KEEP_ONE "!KEEP_%%I!"
if not "!KEEP_FAILED!"=="0" echo       [警告] 有 !KEEP_FAILED! 个白名单路径处理失败，请按上面的提示处理。
goto KEEP_DONE
:KEEP_SKIP
echo       未配置白名单，跳过。
:KEEP_DONE
echo.

rem ================= 第 3 步：处理已被纳入版本控制的目标 =================
echo [3/3] 正在递归检查（含 Plugins 子目录）是否已经被纳入版本控制 ...

set /a FAILED=0
call :COLLECT

if %VC_COUNT%==0 (
    echo       没有发现被纳入版本控制的目标。
    echo       这些目录 / 文件设置忽略后就不会再出现在提交列表里了。
    goto VERIFY
)

echo.
echo       [注意] 以下内容已经被纳入版本控制，仅靠忽略属性无法让它们
echo              从提交列表中消失，需要先移出版本控制（共 %VC_COUNT% 项）：
for /l %%I in (1,1,%VC_COUNT%) do (
    set "SHOW=!VC_%%I!"
    set "SHOW=!SHOW:%WCROOT%\=!"
    echo           !SHOW!
)
echo.

if /i "%MODE%"=="ignore" (
    echo       [提示] 当前是 /ignore 模式，未做任何移除。
    echo              如需处理，请运行：  "!SELF!" /fix
    goto VERIFY
)

if /i "%MODE%"=="ask" (
    echo       是否把它们移出版本控制？本地文件会完整保留，提交一次后生效。
    set /p "ANSWER=      请输入 Y 确认，直接回车跳过："
    if /i not "!ANSWER!"=="Y" (
        echo       [跳过] 未做移除。
        goto VERIFY
    )
)

echo.
echo       开始移出版本控制 ...
for /l %%I in (1,1,%VC_COUNT%) do call :REMOVE_ONE "!VC_%%I!"
echo.
if not %FAILED%==0 echo       [警告] 有 %FAILED% 个目标处理失败，请按上面的提示手动处理。

:VERIFY
echo ================================================================
echo 验证：重新递归扫描一遍
echo ================================================================
call :COLLECT
if %VC_COUNT%==0 echo       已确认：整棵工作副本里没有仍处于版本控制的排除目标。
if not %VC_COUNT%==0 echo       [警告] 还有 %VC_COUNT% 项仍在版本控制中：
for /l %%I in (1,1,%VC_COUNT%) do (
    set "SHOW=!VC_%%I!"
    set "SHOW=!SHOW:%WCROOT%\=!"
    echo           !SHOW!
)
echo.
echo       工作副本根目录一级条目的 SVN 状态
echo       (D = 已移出版本控制待提交   M = 正常修改   ? = 未版本化)
svn status --depth=immediates "%WCROOT%"
if errorlevel 1 echo       [警告] svn status 执行失败。
echo.
echo ================================================================
echo [完成] 排除规则已写入本地工作副本。
echo        属性的改动本身也需要提交一次，才会同步给其他人。
echo        在 TortoiseSVN 里按 F5 刷新后，这些内容就不会出现在提交列表中了。
echo ================================================================
goto END


:COLLECT
rem  递归收集"已经在版本控制里"的目标，结果放在 VC_COUNT / VC_1..VC_n
set /a VC_COUNT=0

rem  .vsconfig 不是目录，直接按根目录路径检查
call :CHECK_VER "%WCROOT%\.vsconfig"

rem  递归扫描整棵工作副本找同名目录
rem  先用 findstr 按目录名过滤（只看目录，含隐藏目录，名字不匹配的会被丢掉），
rem  剩下的候选再逐个用 svn info 判断有没有被纳入版本控制
for /f "usebackq delims=" %%D in (`dir /s /b /ad "%WCROOT%" 2^>nul ^| findstr /i /r "\\Binaries$ \\DerivedDataCache$ \\Intermediate$ \\Saved$ \\.vs$"`) do call :CHECK_VER "%%~fD"

rem  *.sln 同样递归找
for /f "usebackq delims=" %%F in (`dir /s /b /a-d "%WCROOT%\*.sln" 2^>nul`) do call :CHECK_VER "%%~fF"
exit /b 0


:CHECK_VER
rem  %1 可以是相对名字，也可以是完整路径；已纳入版本控制才计入列表
set "TP=%~1"
if not "!TP:~1,1!"==":" set "TP=%WCROOT%\%~1"
if not exist "%TP%" exit /b 0
svn info "%TP%" >nul 2>&1
if errorlevel 1 exit /b 0
set "SCHED="
for /f "usebackq delims=" %%S in (`svn info --show-item schedule "%TP%" 2^>nul`) do set "SCHED=%%S"
if /i "!SCHED!"=="delete" exit /b 0
call :IS_PROT "%TP%"
if not errorlevel 1 exit /b 0
set /a VC_COUNT+=1
set "VC_!VC_COUNT!=%TP%"
exit /b 0


:REMOVE_ONE
set "TP=%~1"
set "SHOW=!TP!"
set "SHOW=!SHOW:%WCROOT%\=!"
if not exist "!TP!" (
    echo          跳过（本地已不存在）：!SHOW!
    exit /b 0
)
set "SCHED="
for /f "usebackq delims=" %%S in (`svn info --show-item schedule "!TP!" 2^>nul`) do set "SCHED=%%S"
if /i "!SCHED!"=="delete" (
    echo          跳过（父目录已一并移出）：!SHOW!
    exit /b 0
)
echo          正在移出版本控制：!SHOW!
svn delete --force --keep-local "!TP!"
if errorlevel 1 (
    set /a FAILED+=1
    echo          [失败] 没有移出版本控制，请手动处理。
) else (
    echo          [完成] 已标记为删除，本地文件保留。
)
exit /b 0


:KEEP_ADD
rem  %1 白名单条目（先原样记录，确定工作副本根目录后再解析成绝对路径）
set /a KEEP_COUNT+=1
set "KEEP_!KEEP_COUNT!=%~1"
exit /b 0


:PROT_ADD
rem  %1 受保护的路径（白名单路径本身或其父目录），"移出版本控制"阶段会跳过它们
set "PA=%~1"
set /a PROT_COUNT+=1
set "PROT_!PROT_COUNT!=%PA%"
exit /b 0


:IS_PROT
rem  %1 待检查路径；命中白名单保护列表时返回 errorlevel 0
for /l %%I in (1,1,%PROT_COUNT%) do if /i "%~1"=="!PROT_%%I!" exit /b 0
exit /b 1


:IS_EXCLUDED_NAME
rem  %1 目录名；判断它是不是第 1 步里的"被排除目录名"
rem  注意：第 1 步的排除列表里新增目录名时，这里要同步加一行
set "NM=%~nx1"
if /i "!NM!"=="Binaries" exit /b 0
if /i "!NM!"=="DerivedDataCache" exit /b 0
if /i "!NM!"=="Intermediate" exit /b 0
if /i "!NM!"=="Saved" exit /b 0
if /i "!NM!"==".vs" exit /b 0
exit /b 1


:IGNORE_STAR
rem  %1 目录；给它补一条 svn:ignore = *，让同级的非白名单内容继续被隐藏
rem     只处理已纳入版本控制、且不是"待删除"状态的目录
set "DS=%~1"
set "SCHED="
for /f "usebackq delims=" %%S in (`svn info --show-item schedule "!DS!" 2^>nul`) do set "SCHED=%%S"
if not defined SCHED exit /b 0
if /i "!SCHED!"=="delete" exit /b 0
set "IPF=%TEMP%\ue_svn_ignorep_%RANDOM%%RANDOM%.txt"
svn propget svn:ignore "!DS!" > "!IPF!" 2>nul
set "HASSTAR=0"
for /f "usebackq delims=" %%L in ("!IPF!") do if "%%L"=="*" set "HASSTAR=1"
if "!HASSTAR!"=="1" (
    del /f /q "!IPF!" >nul 2>&1
    exit /b 0
)
echo *>> "!IPF!"
svn propset svn:ignore --file "!IPF!" "!DS!" >nul 2>&1
if errorlevel 1 echo        [警告] 无法设置 svn:ignore：!DS!
del /f /q "!IPF!" >nul 2>&1
exit /b 0


:KEEP_ONE
rem  %1 白名单路径（可能是相对路径）；确保它被纳入版本控制
set "KP=%~1"
set "KP=%KP:/=\%"
if not "!KP:~1,1!"==":" set "KP=%WCROOT%\!KP!"
if "!KP:~-1!"=="\" if not "!KP:~-2,1!"==":" set "KP=!KP:~0,-1!"
set "SHOW=!KP!"
set "SHOW=!SHOW:%WCROOT%\=!"
if not exist "!KP!" (
    echo        [提示] 白名单路径本地不存在，跳过：!SHOW!
    exit /b 0
)
set "INVC=0"
svn info "!KP!" >nul 2>&1
if not errorlevel 1 set "INVC=1"
if "!INVC!"=="1" goto K1_SCHED
echo        [加入版本控制] !SHOW!
svn add --no-ignore --parents --force "!KP!" >nul 2>&1
if errorlevel 1 goto K1_ADD_FAIL
echo           [完成] 已加入版本控制。
goto K1_HIDE

:K1_ADD_FAIL
set /a KEEP_FAILED+=1
call :DEL_ROOT "!KP!"
echo        [错误] 加入版本控制失败：!SHOW!
echo               常见原因：它或它的父目录之前被 /fix 移出了版本控制（显示 D）。
echo               请对最上层显示 D 的路径执行（-R 后面必须带路径）：
echo                 svn revert -R "!DELPATH!"
echo               然后重新运行本脚本。
goto K1_HIDE

:K1_SCHED
set "SCHED="
for /f "usebackq delims=" %%S in (`svn info --show-item schedule "!KP!" 2^>nul`) do set "SCHED=%%S"
if /i "!SCHED!"=="delete" goto K1_DELETED
echo        [跳过] 已在版本控制中：!SHOW!
goto K1_HIDE

:K1_DELETED
set /a KEEP_FAILED+=1
call :DEL_ROOT "!KP!"
echo        [错误] 白名单路径已被移出版本控制（提交列表里显示 D）：!SHOW!
echo               请对最上层显示 D 的路径执行（-R 后面必须带路径）：
echo                 svn revert -R "!DELPATH!"
echo               如果本地换过这个 DLL，先备份，revert 后再覆盖回来。
goto K1_HIDE

:K1_HIDE
call :KEEP_HIDE "!KP!"
call :PROT_ADD "!KP!"
exit /b 0


:DEL_ROOT
rem  %1 已被移出版本控制的路径；向上找最上层的"待删除"节点，结果放在 DELPATH
set "DELPATH=%~1"
set "UP=%~1"
:K3_UP
for %%A in ("!UP!") do set "PAR=%%~dpA"
if "!PAR:~-1!"=="\" set "PAR=!PAR:~0,-1!"
if "!PAR:~-1!"==":" set "PAR=!PAR!\"
if /i "!PAR!"=="!UP!" exit /b 0
if /i "!PAR!"=="%WCROOT%" exit /b 0
set "SCHED="
for /f "usebackq delims=" %%S in (`svn info --show-item schedule "!PAR!" 2^>nul`) do set "SCHED=%%S"
if /i not "!SCHED!"=="delete" exit /b 0
set "DELPATH=!PAR!"
set "UP=!PAR!"
goto K3_UP


:KEEP_HIDE
rem  %1 白名单路径；把父目录登记为受保护，并对"被排除目录"（如 Binaries）
rem      及其下面的各级父目录补 svn:ignore = *，让同级其它内容继续隐藏
set "TP2=%~1"
set /a ANC_COUNT=0
set "UP=!TP2!"
:K2_UP
for %%A in ("!UP!") do set "PAR=%%~dpA"
if "!PAR:~-1!"=="\" set "PAR=!PAR:~0,-1!"
if "!PAR:~-1!"==":" set "PAR=!PAR!\"
if /i "!PAR!"=="!UP!" goto K2_DONE
if /i "!PAR!"=="%WCROOT%" goto K2_DONE
set /a ANC_COUNT+=1
set "ANC_!ANC_COUNT!=!PAR!"
set "UP=!PAR!"
goto K2_UP
:K2_DONE
rem  ANC_1 最靠近文件，编号越大越靠上；找最靠上的那个被排除目录
set /a ANC_TOP=0
for /l %%I in (1,1,%ANC_COUNT%) do (
    set "ANC_ITEM=!ANC_%%I!"
    call :IS_EXCLUDED_NAME "!ANC_ITEM!"
    if not errorlevel 1 set /a ANC_TOP=%%I
)
for /l %%I in (1,1,%ANC_TOP%) do (
    set "ANC_ITEM=!ANC_%%I!"
    call :PROT_ADD "!ANC_ITEM!"
    call :IGNORE_STAR "!ANC_ITEM!"
)
exit /b 0


:USAGE
echo.
echo 用法：
echo     ue_svn_ignore.bat                设置排除规则，并询问如何处理已版本化的目标
echo     ue_svn_ignore.bat /ignore        只设置排除规则，不做任何移除
echo     ue_svn_ignore.bat /fix           设置排除规则 + 直接把已版本化的目标移出版本控制
echo     ue_svn_ignore.bat /path "D:\WC"  对指定的工作副本根目录执行
echo.
echo 白名单（不排除的路径）请在本脚本中部的 "白名单" 配置段里，
echo 按 call :KEEP_ADD "相对路径" 的格式逐行添加。
goto END


:END
if defined OLDCP chcp %OLDCP% >nul
rem 双击运行时暂停一下，方便看结果。
rem 这里刻意不用 echo "%cmdcmdline%"|find：cmd 会把 %变量% 的展开结果
rem 再做一次特殊字符解析，命令行里带重定向时会被当成本脚本的重定向而报错。
if /i not "!cmdcmdline!"=="!cmdcmdline:%SELF%=!" pause
endlocal
exit /b
