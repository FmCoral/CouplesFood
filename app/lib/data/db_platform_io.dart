/// 数据库平台初始化（dart:io 平台：Android / Windows / Linux / macOS）
///
/// 通过条件导入在原生平台上生效：
///   import 'db_platform_stub.dart' if (dart.library.io) 'db_platform_io.dart';
///
/// 背景：
/// sqflite 官方插件只实现了 Android / iOS / macOS，Windows / Linux 上没有原生通道。
/// 桌面端必须把全局 databaseFactory 换成 FFI 版本（sqflite_common_ffi），
/// 否则调用 openDatabase 会抛 MissingPluginException。
///
/// 对 Android 零影响：非桌面平台这里什么都不做，仍走 sqflite 原生实现。
library;

import 'dart:io' show Platform;

import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

/// 是否已初始化过（重复调用幂等）
bool _initialized = false;

/// 在 Windows / Linux 上把 sqflite 切到 FFI 工厂；其他平台直接返回。
///
/// 必须在任何 openDatabase 之前调用一次。
void initDbPlatform() {
  if (_initialized) return;
  _initialized = true;

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
