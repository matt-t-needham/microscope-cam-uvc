import 'package:flutter_test/flutter_test.dart';

import 'package:uvc_microscope/main.dart';

void main() {
  testWidgets('App initializes', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(cameras: []));
    expect(find.text('No camera detected'), findsOneWidget);
  });
}
