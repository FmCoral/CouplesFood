/// RFC 9457 Problem Details —— 与后端错误信封一一对应
class ApiProblem implements Exception {
  final String type;
  final String title;
  final int status;
  final String detail;
  final String? requestId;
  final List<ValidationIssue> issues;

  ApiProblem({
    required this.type,
    required this.title,
    required this.status,
    required this.detail,
    this.requestId,
    this.issues = const [],
  });

  factory ApiProblem.fromJson(Map<String, dynamic> j) {
    final rawIssues = j['issues'];
    return ApiProblem(
      type: (j['type'] ?? 'about:blank').toString(),
      title: (j['title'] ?? 'UNKNOWN').toString(),
      status: (j['status'] as num?)?.toInt() ?? 500,
      detail: (j['detail'] ?? '请求失败').toString(),
      requestId: j['request_id']?.toString(),
      issues: rawIssues is List
          ? rawIssues
              .whereType<Map>()
              .map((e) => ValidationIssue(
                    path: ((e['path'] as List?) ?? const []).map((x) => x.toString()).join('.'),
                    message: (e['message'] ?? '').toString(),
                  ))
              .toList()
          : const [],
    );
  }

  /// 网络层失败（连不上、超时），不是后端返回的错误
  factory ApiProblem.network(String detail) => ApiProblem(
        type: 'about:blank',
        title: 'NETWORK_ERROR',
        status: 0,
        detail: detail,
      );

  bool get isNetwork => status == 0;
  bool get isUnauthorized => status == 401;
  bool get isConflict => status == 409;
  bool get isNotFound => status == 404;
  bool get isForbidden => status == 403;

  /// 给用户看的文案：优先具体 detail，其次泛化
  String get friendly {
    if (isNetwork) return detail;
    if (issues.isNotEmpty) return issues.first.message;
    return detail.isNotEmpty ? detail : '操作失败（$status）';
  }

  @override
  String toString() => 'ApiProblem($status $title: $detail)';
}

class ValidationIssue {
  final String path;
  final String message;
  const ValidationIssue({required this.path, required this.message});
}
