import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:njbrec/ui/widgets/logo.dart';

void main() {
  testWidgets('El logo se dibuja sin errores', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: NjbWordmark()))),
    );
    expect(find.text('NJB'), findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
  });
}
