import 'package:flutter_test/flutter_test.dart';
import 'package:spektrafilm_mobile/main.dart';

void main() {
  testWidgets('the editor renders its shell', (tester) async {
    await tester.pumpWidget(const SpektraApp());
    await tester.pump();

    expect(find.text('Spektrafilm'), findsOneWidget);
    expect(find.text('选一张照片开始'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('RAW 文件'), findsOneWidget);
  });
}
