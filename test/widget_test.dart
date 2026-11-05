import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/main.dart';

void main() {
  testWidgets('the editor renders its shell', (tester) async {
    await tester.pumpWidget(const HalfstopApp());
    await tester.pump();

    // Header lockup + the empty-state wordmark both say it.
    expect(find.text('半档'), findsWidgets);
    expect(find.text('HALFSTOP'), findsWidgets);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('RAW 文件'), findsOneWidget);
  });
}
