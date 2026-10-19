import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/admin_shell.dart';
import 'ui/bind_page.dart';
import 'ui/common.dart';
import 'ui/home_shell.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Boot());
}

/// 引导层：先建 AppState（读 token、开本地库），完成后再挂 MaterialApp
class Boot extends StatefulWidget {
  const Boot({super.key});

  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> with WidgetsBindingObserver {
  final _state = AppState();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _noticeSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 同步冲突之类需要用户知道的提示，由 AppState 转发到这里统一弹出
    _state.bootstrap().then((_) {
      _noticeSub = _state.notices.listen((msg) {
        _messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 4),
          ));
      });
      // 启动静默检查更新：有新版本才弹窗，没有就当无事发生。
      // 放在首帧之后，等 MaterialApp / Navigator 挂好再拿 context。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navKey.currentContext;
        if (ctx != null && ctx.mounted) unawaited(checkForUpdate(ctx));
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台挂起会掐断 WS 的定时器，回到前台立刻重连，别干等退避
    if (state == AppLifecycleState.resumed) _state.onAppResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _noticeSub?.cancel();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: _state,
      child: MaterialApp(
        title: '食在有你',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messengerKey,
        navigatorKey: _navKey,
        theme: AppTheme.light(),
        builder: (context, child) {
          // 全局限制字体放大，避免系统超大字体把布局顶爆
          final scale = MediaQuery.of(context).textScaler.clamp(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.2,
          );
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scale),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const Gate(),
      ),
    );
  }
}

/// 三态路由闸门：未登录 → 登录页；已登录无关系 → 绑定页；有关系 → 主壳
///
/// 用声明式切换而不是 push/pop：登录态变化（被对方解散、token 失效）时
/// 界面必须整体切换，命令式导航容易留下脏栈。
class Gate extends StatelessWidget {
  const Gate({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    if (!s.booted) return const SplashScreen();

    // 超管：独立界面，不进情侣主流程
    if (s.isLoggedIn && s.session.isAdmin) return const AdminShell();

    if (!s.isLoggedIn) return const LoginPage();

    // 有关系（含冻结期）→ 主壳
    if (s.couple != null) return const HomeShell();

    // 已登录但还没有关系 → 绑定页
    // sync 尚未就绪时先显示加载，避免闪一下绑定页
    if (!s.syncReady) return const SplashScreen();
    return const BindPage();
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset('assets/logo.png', width: 84, height: 84),
            ),
            const SizedBox(height: 20),
            const Text('食在有你',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 2)),
            const SizedBox(height: 28),
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: scheme.primary.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}
