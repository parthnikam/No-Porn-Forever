import 'package:filterd_mobile/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app loads home branding', (WidgetTester tester) async {
    await tester.pumpWidget(const NoPornForeverApp());
    // Allow first frame + async list load without settling forever on animations.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('NoPornForever'), findsWidgets);
  });
}
