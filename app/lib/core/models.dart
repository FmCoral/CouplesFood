/// 领域模型：字段名与后端 JSON 严格一一对应，避免"看起来像但拼错"的低级 bug

String _s(dynamic v) => v?.toString() ?? '';
String? _ns(dynamic v) => v == null ? null : v.toString();
int _i(dynamic v, [int def = 0]) => (v as num?)?.toInt() ?? def;

// ---------------- 用户 / 关系 ----------------

class Partner {
  final String id;
  final String nickname;
  final String? avatarUrl;
  final String? roleLabel;

  Partner({required this.id, required this.nickname, this.avatarUrl, this.roleLabel});

  factory Partner.fromJson(Map<String, dynamic> j) => Partner(
        id: _s(j['id']),
        nickname: _s(j['nickname']),
        avatarUrl: _ns(j['avatarUrl']),
        roleLabel: _ns(j['roleLabel']),
      );
}

class DissolutionInfo {
  final String requestId;
  final String initiatedBy;
  final DateTime? createdAt;

  DissolutionInfo({required this.requestId, required this.initiatedBy, this.createdAt});

  factory DissolutionInfo.fromJson(Map<String, dynamic> j) => DissolutionInfo(
        requestId: _s(j['requestId']),
        initiatedBy: _s(j['initiatedBy']),
        createdAt: DateTime.tryParse(_s(j['createdAt']))?.toLocal(),
      );
}

/// 关系状态机：pending → active → dissolving → dissolved(归档)
class CoupleInfo {
  final String coupleId;
  final String status; // active | dissolving
  final int version;
  final DateTime? boundAt;
  final Partner? partner;
  final String? myRoleLabel;
  final DissolutionInfo? dissolution;

  CoupleInfo({
    required this.coupleId,
    required this.status,
    required this.version,
    this.boundAt,
    this.partner,
    this.myRoleLabel,
    this.dissolution,
  });

  /// 冻结期：只读，连菜品都不能改
  bool get isFrozen => status == 'dissolving';

  /// 我是不是解散发起人（发起人不能再批准，只能撤回）
  bool get iInitiatedDissolution =>
      dissolution != null && dissolution!.initiatedBy == _selfId;

  String _selfId = '';

  set selfId(String v) => _selfId = v;

  factory CoupleInfo.fromJson(Map<String, dynamic> j, String selfId) {
    final c = CoupleInfo(
      coupleId: _s(j['coupleId']),
      status: _s(j['status']),
      version: _i(j['version'], 1),
      boundAt: DateTime.tryParse(_s(j['boundAt']))?.toLocal(),
      partner: j['partner'] is Map ? Partner.fromJson(Map<String, dynamic>.from(j['partner'])) : null,
      myRoleLabel: _ns(j['myRoleLabel']),
      dissolution: j['dissolution'] is Map
          ? DissolutionInfo.fromJson(Map<String, dynamic>.from(j['dissolution']))
          : null,
    );
    c._selfId = selfId;
    return c;
  }
}

// ---------------- 分类 ----------------

class DishType {
  final String id;
  final String name;
  final int sortOrder;
  final bool isPreset;
  final int dishCount;

  DishType({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isPreset,
    required this.dishCount,
  });

  factory DishType.fromJson(Map<String, dynamic> j) => DishType(
        id: _s(j['id']),
        name: _s(j['name']),
        sortOrder: _i(j['sortOrder']),
        isPreset: j['isPreset'] == true,
        dishCount: _i(j['dishCount']),
      );
}

class DishFlavor {
  final String id;
  final String name;
  final int sortOrder;
  final bool isPreset;
  final int dishCount;

  DishFlavor({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isPreset,
    required this.dishCount,
  });

  factory DishFlavor.fromJson(Map<String, dynamic> j) => DishFlavor(
        id: _s(j['id']),
        name: _s(j['name']),
        sortOrder: _i(j['sortOrder']),
        isPreset: j['isPreset'] == true,
        dishCount: _i(j['dishCount']),
      );
}

// ---------------- 菜品 ----------------

class Dish {
  final String id;
  final String name;
  final String? imageKey;
  final String? imageUrl;
  final String? note;
  final List<String> tags;
  final String? typeId;
  final String? typeName;
  final List<String> flavorIds;
  final List<String> flavorNames;
  final bool isAvailable;
  final int version;
  final String? createdBy;

  Dish({
    required this.id,
    required this.name,
    this.imageKey,
    this.imageUrl,
    this.note,
    this.tags = const [],
    this.typeId,
    this.typeName,
    this.flavorIds = const [],
    this.flavorNames = const [],
    this.isAvailable = true,
    this.version = 1,
    this.createdBy,
  });

  factory Dish.fromJson(Map<String, dynamic> j) {
    final type = j['type'];
    return Dish(
      id: _s(j['id']),
      name: _s(j['name']),
      imageKey: _ns(j['imageKey']),
      imageUrl: _ns(j['imageUrl']),
      note: _ns(j['note']),
      tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      typeId: type is Map ? _ns(type['id']) : null,
      typeName: type is Map ? _ns(type['name']) : null,
      flavorIds: (j['flavors'] as List?)
              ?.whereType<Map>()
              .map((e) => _s(e['id']))
              .toList() ??
          const [],
      flavorNames: (j['flavors'] as List?)
              ?.whereType<Map>()
              .map((e) => _s(e['name']))
              .toList() ??
          const [],
      isAvailable: j['isAvailable'] != false,
      version: _i(j['version'], 1),
      createdBy: _ns(j['createdBy']),
    );
  }

  Dish copyWith({String? imageKey, String? imageUrl}) => Dish(
        id: id,
        name: name,
        imageKey: imageKey ?? this.imageKey,
        imageUrl: imageUrl ?? this.imageUrl,
        note: note,
        tags: tags,
        typeId: typeId,
        typeName: typeName,
        flavorIds: flavorIds,
        flavorNames: flavorNames,
        isAvailable: isAvailable,
        version: version,
        createdBy: createdBy,
      );
}

// ---------------- 订单 ----------------

class OrderItem {
  final String dishId;
  final String name;
  final String? imageKey;
  final String? imageUrl;
  final int quantity;
  final String? note;

  OrderItem({
    required this.dishId,
    required this.name,
    this.imageKey,
    this.imageUrl,
    this.quantity = 1,
    this.note,
  });

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        dishId: _s(j['dishId']),
        name: _s(j['name']),
        imageKey: _ns(j['imageKey']),
        imageUrl: _ns(j['imageUrl']),
        quantity: _i(j['quantity'], 1),
        note: _ns(j['note']),
      );
}

/// 状态机：pending → accepted → cooking → served → completed
/// 另有 rejected / cancelled 两个终态
class Order {
  final String id;
  final String status;
  final String mealType;
  final String? requestNote;
  final String? replyNote;
  final String requesterId;
  final String? chefId;
  final int version;
  final List<OrderItem> items;
  final DateTime? createdAt;
  final DateTime? acceptedAt;
  final DateTime? servedAt;
  final DateTime? completedAt;

  Order({
    required this.id,
    required this.status,
    required this.mealType,
    this.requestNote,
    this.replyNote,
    required this.requesterId,
    this.chefId,
    this.version = 1,
    this.items = const [],
    this.createdAt,
    this.acceptedAt,
    this.servedAt,
    this.completedAt,
  });

  factory Order.fromJson(Map<String, dynamic> j) {
    final tl = j['timeline'];
    return Order(
      id: _s(j['id']),
      status: _s(j['status']),
      mealType: _s(j['mealType']).isEmpty ? 'dinner' : _s(j['mealType']),
      requestNote: _ns(j['requestNote']),
      replyNote: _ns(j['replyNote']),
      requesterId: _s(j['requesterId']),
      chefId: _ns(j['chefId']),
      version: _i(j['version'], 1),
      items: (j['items'] as List?)?.whereType<Map>().map((e) => OrderItem.fromJson(Map<String, dynamic>.from(e))).toList() ?? const [],
      createdAt: DateTime.tryParse(_s(j['createdAt']))?.toLocal(),
      acceptedAt: tl is Map ? DateTime.tryParse(_s(tl['acceptedAt']))?.toLocal() : null,
      servedAt: tl is Map ? DateTime.tryParse(_s(tl['servedAt']))?.toLocal() : null,
      completedAt: tl is Map ? DateTime.tryParse(_s(tl['completedAt']))?.toLocal() : null,
    );
  }

  bool get isOpen => const ['pending', 'accepted', 'cooking', 'served'].contains(status);
  bool get isDone => const ['completed', 'rejected', 'cancelled'].contains(status);

  String get statusLabel => switch (status) {
        'pending' => '待接单',
        'accepted' => '已接单',
        'cooking' => '烹饪中',
        'served' => '已出餐',
        'completed' => '已完成',
        'rejected' => '被拒绝',
        'cancelled' => '已取消',
        _ => status,
      };

  String get mealTypeLabel => switch (mealType) {
        'breakfast' => '早餐',
        'lunch' => '午餐',
        'dinner' => '晚餐',
        'night_snack' => '夜宵',
        'other' => '其他',
        _ => mealType,
      };

  String get summary =>
      items.map((e) => e.quantity > 1 ? '${e.name}×${e.quantity}' : e.name).join('、');

  int get totalQuantity => items.fold(0, (a, b) => a + b.quantity);
}

// ---------------- 同步事件 ----------------

class SyncEvent {
  final String id; // bigint，跨事件单调递增，用作 cursor
  final String type;
  final String entityType;
  final String entityId;
  final Map<String, dynamic> payload;
  final int version;

  SyncEvent({
    required this.id,
    required this.type,
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.version,
  });

  factory SyncEvent.fromJson(Map<String, dynamic> j) => SyncEvent(
        id: _s(j['id']),
        type: _s(j['type']),
        entityType: _s(j['entityType']),
        entityId: _s(j['entityId']),
        payload: j['payload'] is Map ? Map<String, dynamic>.from(j['payload']) : const {},
        version: _i(j['version'], 0),
      );
}
