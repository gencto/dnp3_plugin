import 'package:dnp3_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home page renders without touching the native library', (tester) async {
    await tester.pumpWidget(const Dnp3App());
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
