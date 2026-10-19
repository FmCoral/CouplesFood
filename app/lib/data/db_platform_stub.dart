/// 数据库平台初始化的「兜底实现」
///
/// 通过条件导入在 Web（以及任何非 dart:io 平台）上生效：
///   import 'db_platform_stub.dart' if (dart.library.io) 'db_platform_io.dart';
///
/// Web 上 sqflite 走 sqflite_common_ffi_wasm，本项目暂不支持，
/// 这里保持空实现，避免 Web 构建时 import 'dart:io' 报错。
void initDbPlatform() {
  // 无操作
}
