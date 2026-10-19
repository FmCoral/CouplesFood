Flutter 写的单端 App（**只出 Android apk，不做 iOS**）。

- 24 个 Dart 文件，12 个页面，`flutter analyze` 0 error / 0 warning
- 离线优先：本地 SQLite 是「副本」不是缓存，断网也能正常加菜、点菜
- 状态管理用 `provider`，没有引入 Riverpod / Bloc —— 这个体量不值得

---

## 环境

| 项 | 版本 | 备注 |
|---|---|---|
| Flutter | **3.47.x** | `environment.sdk: ^3.13.5` |
| Dart | 3.13.x | 随 Flutter 一起 |
| JDK | **17+** | `sourceCompatibility = VERSION_17` |
| Android compileSdk | 36 | 由 `flutter.compileSdkVersion` 决定 |
| Android minSdk | 23 | `flutter_secure_storage` / `sqflite` 需要 21+，22 更稳 |
| Gradle | 9.3.1 | wrapper 里已固定 |
| AGP | 9.1.0 | `android/settings.gradle.kts` |
| Kotlin | 2.4.0 | 同上 |

**国内网络必看**：官方 `storage.googleapis.com` 实测 80KB/s，`storage.flutter-io.cn` 13MB/s。
`android/settings.gradle.kts` 里已经把阿里云 maven 排在 `google()` 前面，
`gradle-wrapper.properties` 指向腾讯云镜像。clone 下来直接能构建，不用另配。

要下载 Flutter SDK 本身，先设这两个环境变量：

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.dev
```

仓库根的 `app/build.env` 是本次构建实际用的环境（SDK 路径、JDK、镜像），可作参考。

---

## 构建

```bash
# 通用版（含 arm64 / armeabi-v7a / x86_64，58MB）
flutter build apk --release

# arm64 精简版（现在几乎所有手机都是 arm64，23MB）
flutter build apk --release --target-platform android-arm64

# 产物
ls build/app/outputs/flutter-apk/
```

构建前内存不够会报 `Gradle build ran out of Java heap space`，
在 `android/gradle.properties` 里加：

```properties
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g
```

---

## 签名

`android/app/build.gradle.kts` 的 `signingConfigs.release` 会读 `android/key.properties`：

```properties
storeFile=app/keystore/couple-menu.keystore
storePassword=***
keyAlias=couple-menu
keyPassword=***
```

**这个文件和 keystore 都不入库**（`.gitignore` 已排除）。缺失时 release 自动退回
debug 签名——能装能跑，但**不能覆盖升级已装的正式版**（签名不同，系统拒绝安装）。

### 用原来的密钥（要升级线上已装版本）

线上版本用的密钥没有放进仓库（私钥入库等于公开）。找发布者要
`食在有你-签名密钥备份包.zip`，解开后：

```bash
unzip 食在有你-签名密钥备份包.zip -d /tmp/key
cp /tmp/key/couple-menu.keystore app/android/app/keystore/
cp /tmp/key/key.properties       app/android/key.properties
```

校验指纹是否是同一把（指纹对不上就不是同一个 App）：

```bash
keytool -list -v -keystore app/android/app/keystore/couple-menu.keystore \
  -alias couple-menu -storepass CoupleMenu2024 | grep SHA256
# 期望 6C:01:09:18:58:EC:49:6C:DB:1B:1A:0A:37:C0:6D:B3:...
```

### 自己生成新密钥

```bash
keytool -genkeypair -v -keystore app/android/app/keystore/my.keystore \
  -alias my-key -keyalg RSA -keysize 2048 -validity 10000
```

> ⚠️ 换密钥 = 换签名 = 用户必须**卸载重装**，不能覆盖升级。
> 密钥丢了也没法找回，Google Play 之外的场景就是彻底断更——所以拿到后请离线备份。

---

## 目录结构

```
lib/
├── main.dart              入口：Boot → Gate 三态闸门（未登录/待绑定/正常）
├── core/
│   ├── config.dart        ★ 服务器地址（编译期常量，App 内不可改）
│   ├── api_client.dart    HTTP 封装、统一错误映射、token 自动刷新
│   ├── session.dart       登录态持久化（flutter_secure_storage）
│   ├── models.dart        所有数据模型 + 状态文案映射
│   ├── problem.dart       后端 RFC7807 错误对象
│   └── theme.dart         Material 3 暖橙主题
├── data/
│   ├── local_db.dart      sqflite：dishes/categories/orders/kv/outbox
│   ├── sync_engine.dart   同步引擎：推 outbox + 拉 events，cursor 补漏
│   └── ws_client.dart     WebSocket，断线指数退避重连
├── state/
│   └── app_state.dart     唯一的 ChangeNotifier，串起 session/api/db/sync/ws
└── ui/                    12 个页面 + 2 个公共件
    ├── login_page.dart       登录 / 注册
    ├── bind_page.dart        生成邀请码 / 输入邀请码
    ├── home_shell.dart       3 Tab 外壳 + 冻结横幅 + 订单角标
    ├── menu_page.dart        菜单网格 + 双维度筛选
    ├── dish_editor.dart      菜品编辑（图片、种类、口味、标签）
    ├── category_manager.dart 种类/口味管理
    ├── order_compose_page.dart 购物车下单
    ├── orders_page.dart      订单列表 + 详情 + 状态机动作
    ├── profile_page.dart     我的：昵称、另一半、设置、解散
    ├── dissolve_sheet.dart   解散三视角（发起/撤回/同意）
    ├── admin_shell.dart      超管：状态、情侣、用户
    ├── common.dart           扩展方法、空态、确认框、同步角标
    ├── dish_photo.dart       无图时首字 + 渐变占位
    └── theme.dart            Material 3 暖橙主题
```

---

## 改代码前必须知道的四个坑

**1. 绑定成功后 token 里的 `coupleId` 还是 `null`**

后端在绑定那一刻不会改已签发的 access token。客户端必须换发新 token 才能调业务接口。
`AppState.joinCouple()` 里已经处理（换 token + `_silentRefreshTokens()`），
`couple.bound` WebSocket 事件也会触发一次静默刷新。自己加接口时别绕过这条路。

**2. 服务器地址只能改 `core/config.dart`**

App 内**故意没有**任何修改服务器地址的入口。理由写在 `config.dart` 注释里：
用户改地址框是个假逃生门，真出问题时用户不知道该填什么，反而给自己留了一个
「被引导到仿冒服务器」的入口。换服务器就改 DNS 解析，App 无感。

**3. 图片走客户端压缩**

`sync_engine.compressAndUpload()` 长边压到 1280、JPEG q80 再上传。
服务端 `MAX_UPLOAD_MB=5` 是硬闸。别改成原图直传——2C2G 机器 + 国外线路会很难受。

**4. 冻结期（`dissolving`）所有写操作都会被 403**

后端有 `ensureCoupleEditable()` 兜底，客户端 UI 也把编辑区包在 `AbsorbPointer` 里。
如果你的新页面要写数据，记得两处都处理。

---

## 调试

```bash
flutter devices                    # 看有没有连上真机/模拟器
flutter run --release              # 真机跑，看日志
adb logcat -s flutter              # 只看 Dart 打印
flutter analyze                    # 提交前必须 0 error
flutter test                       # 目前只有一个冒烟测试
```

`app/test/widget_test.dart` 故意只验证 `Boot` 能构建、不碰网络和本地库——
写真正的 UI 测试需要 mock 掉 `AppState`，这个体量不值得。
