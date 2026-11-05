import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/main.dart';

void main() {
  testWidgets('the editor renders its shell', (tester) async {
    await tester.pumpWidget(const HalfstopApp());
    await tester.pump();

    // The landing page carries the wordmark and both entry cards; the header
    // is now just back / 原图·预览 / 导出.
    expect(find.text('半档'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('RAW 文件'), findsOneWidget);
    expect(find.text('原图'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
  });
}
