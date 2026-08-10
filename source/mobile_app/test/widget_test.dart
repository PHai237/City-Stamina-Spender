import 'package:flutter_test/flutter_test.dart';

import 'package:city_stamina_mobile/main.dart';

void main() {
  testWidgets('hub shows owner automation', (WidgetTester tester) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    expect(find.text('Automation Hub'), findsOneWidget);
    expect(find.text("Owner's Selection"), findsOneWidget);
    expect(find.text('NTE - 1-1 / 1-9'), findsOneWidget);
  });

  testWidgets('owner page opens from hub', (WidgetTester tester) async {
    await tester.pumpWidget(const CityStaminaMobileApp());

    await tester.tap(find.text("Owner's Selection"));
    await tester.pumpAndSettle();

    expect(find.text("Owner's Selection"), findsOneWidget);
    expect(find.text('City Stamina'), findsOneWidget);
    expect(find.text('1-1'), findsOneWidget);
    expect(find.text('1-9'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    expect(find.text('Check'), findsOneWidget);
    expect(find.text('Hub'), findsOneWidget);
    expect(find.text('Send log'), findsOneWidget);
  });
}
