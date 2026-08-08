import 'package:flutter_test/flutter_test.dart';

import 'package:city_stamina_mobile/main.dart';

void main() {
  testWidgets('hub shows available mobile automations', (WidgetTester tester) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    expect(find.text('Automation Hub'), findsOneWidget);
    expect(find.text('NTE'), findsOneWidget);
    expect(find.text('Debug'), findsOneWidget);
  });

  testWidgets('owner page opens from NTE card', (WidgetTester tester) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    await tester.tap(find.text('NTE'));
    await tester.pumpAndSettle();

    expect(find.text("Owner's Selection"), findsOneWidget);
    expect(find.text('City Stamina'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });
}
