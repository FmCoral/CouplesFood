import 'package:flutter_test/flutter_test.dart';

import 'package:couple_menu/main.dart';

/// 冒烟测试：只验证 App 能构建，不碰网络与本地库
void main() {
  testWidgets('Boot 能构建', (WidgetTester tester) async {
    await tester.pumpWidget(const Boot());
    expect(find.byType(Boot), findsOneWidget);
  });
}
