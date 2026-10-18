import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../state/app_state.dart';
import '../ui/common.dart';

/// 登录 / 注册
///
/// 一个界面两种模式：超管用同一个界面，凭账号密码自动识别（后端 JWT 带 adm 声明），
/// 不做单独的"管理员登录"入口——内部测试没必要，也少一处暴露面。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isRegister = false;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    final s = context.read<AppState>();
    // 登录/注册成功后由 Gate 自动切页，这里只负责报错
    final ok = await runGuarded(context, () async {
      if (_isRegister) {
        await s.register(
          phone: _phone.text.trim(),
          password: _password.text,
          nickname: _nickname.text.trim(),
        );
      } else {
        await s.login(
          phone: _phone.text.trim(),
          password: _password.text,
          nickname: '',
        );
      }
    });

    if (mounted) setState(() => _busy = false);
    if (!ok) return;
  }

  Future<void> _openServerSettings() async {
    final s = context.read<AppState>();
    final ctrl = TextEditingController(
      text: s.session.baseUrl.isEmpty ? AppConfig.defaultBaseUrl : s.session.baseUrl,
    );
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('换服务器时只改这里，不用重装 App。',
                style: TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'https://food.fmcoral.com',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(minimumSize: const Size(88, 42)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (r == null || r.isEmpty) return;

    var url = r;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    await s.session.setBaseUrl(url);
    if (mounted) context.snack('已保存：$url');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ---- 头部 ----
                    Center(
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Icon(Icons.restaurant_menu, size: 38, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _isRegister ? '创建账号' : '欢迎回来',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isRegister ? '注册后生成邀请码，让对方输入即可绑定' : '两个人，一张菜单',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 32),

                    // ---- 手机号 ----
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '手机号',
                        prefixIcon: Icon(Icons.phone_iphone, size: 20),
                        counterText: '',
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return '请输入手机号';
                        if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(t)) return '手机号格式不对';
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    // ---- 昵称（仅注册）----
                    if (_isRegister) ...[
                      TextFormField(
                        controller: _nickname,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          labelText: '昵称',
                          prefixIcon: Icon(Icons.face_outlined, size: 20),
                          counterText: '',
                        ),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? '起个名字吧' : null,
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ---- 密码 ----
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                              size: 20),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) {
                        final t = v ?? '';
                        if (t.isEmpty) return '请输入密码';
                        if (_isRegister && t.length < 8) return '密码至少 8 位';
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),

                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_isRegister ? '注册并进入' : '登录'),
                    ),
                    const SizedBox(height: 14),

                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _isRegister = !_isRegister;
                                _formKey.currentState?.reset();
                              }),
                      child: Text(_isRegister ? '已有账号？去登录' : '还没有账号？去注册'),
                    ),

                    const SizedBox(height: 24),
                    Center(
                      child: TextButton.icon(
                        onPressed: _busy ? null : _openServerSettings,
                        icon: Icon(Icons.dns_outlined, size: 16, color: scheme.onSurfaceVariant),
                        label: Text('服务器设置',
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
