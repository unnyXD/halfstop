import 'package:flutter_test/flutter_test.dart';
import 'package:spektrafilm_mobile/main.dart';

void main() {
  testWidgets('the editor renders its shell', (tester) async {
    await tester.pumpWidget(const SpektraApp());
    await tester.pump();

    expect(find.text('Spektrafilm'), findsOneWidget);
    expect(find.text('打开一张 RAW'), findsOneWidget);
    expect(find.text('选择 RAW'), findsOneWidget);
  });
}
