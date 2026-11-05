import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/main.dart';

void main() {
  testWidgets('the editor renders its shell', (tester) async {
    await tester.pumpWidget(const HalfstopApp());
    await tester.pump();

    // The landing page carries the wordmark and both entry cards. It must not
    // show the editor chrome (原图/预览, 导出, the slider sheet), because none
    // of it can do anything before a picture is open.
    expect(find.text('半档'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('RAW 文件'), findsOneWidget);
    expect(find.text('原图'), findsNothing);
    expect(find.text('导出'), findsNothing);
    expect(find.text('展开调节面板'), findsNothing);
  });
}
