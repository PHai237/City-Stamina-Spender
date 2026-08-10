import 'package:flutter_test/flutter_test.dart';

import 'package:city_stamina_mobile/main.dart';

void main() {
  testWidgets('opens owner automation directly', (WidgetTester tester) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    expect(find.text("Owner's Selection"), findsOneWidget);
    expect(find.text('City Stamina'), findsOneWidget);
    expect(find.text('1-1'), findsOneWidget);
    expect(find.text('1-9'), findsOneWidget);
  });

  testWidgets('run button is available on owner page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    expect(find.text("Owner's Selection"), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });
}
