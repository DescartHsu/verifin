import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/online_rates.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  final day = DateTime(2026, 11, 6);

  test('validates rate direction, date, currency pair and numeric bounds', () {
    Map<String, Object> row(
      String code,
      num rate, {
      String date = '2026-11-06',
      String base = 'CNY',
    }) => {'base': base, 'quote': code, 'date': date, 'rate': rate};
    final quotes = parseOnlineRates(
      [
        row('USD', 0.125),
        row('JPY', 0),
        row('HKD', double.nan),
        row('AUD', 0.2, date: '2026-11-07'),
        row('CAD', 1, date: '2026-02-30'),
        row('EUR', 1, base: 'USD'),
        row('GBP', 1),
      ],
      'CNY',
      {'USD', 'JPY', 'HKD', 'AUD', 'CAD', 'EUR'},
      day,
    );
    expect(quotes, [(code: 'USD', date: day, rateToBase: 8.0)]);
  });

  test(
    'concurrent refresh preserves manual records and reports missing quotes',
    () async {
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      expect(controller.autoRates, isFalse);
      await controller.setAutoRates(true);
      final quotes = Completer<List<OnlineRate>>();
      final pending = controller.refreshExchangeRates({
        'USD',
        'EUR',
        'JPY',
      }, fetch: (_, _) => quotes.future);
      await controller.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: day,
        rateToBase: 7.3,
      );
      quotes.complete([
        (code: 'USD', date: day, rateToBase: 7.1),
        (code: 'EUR', date: day, rateToBase: 8.0),
      ]);
      expect(await pending, {'JPY'});
      final restarted = await makeController(store);
      expect(restarted.autoRates, isTrue);
      expect(restarted.exchangeRateFor('USD', day)?.rateToBase, 7.3);
      expect(
        restarted.exchangeRateFor('EUR', day)?.source,
        ExchangeRateSource.frankfurter,
      );
      expect(restarted.exchangeRateFor('EUR', DateTime(2026, 11, 5)), isNull);
      await expectLater(
        restarted.refreshExchangeRates({
          'EUR',
        }, fetch: (_, _) async => throw const FormatException()),
        throwsFormatException,
      );
      expect(restarted.exchangeRates.length, 2);
      final backup = restarted.exportDataJson();
      expect(backup, contains('frankfurter'));
      expect(backup, isNot(contains('autoRates')));
      expect(await restarted.resetAllData(), isTrue);
      final reset = await makeController(store);
      expect(reset.autoRates, isFalse);
      expect(reset.exchangeRates, isEmpty);
    },
  );
}
