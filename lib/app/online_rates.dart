import 'dart:convert';
import 'dart:io';

import 'models/currency.dart';

typedef OnlineRate = ({String code, DateTime date, double rateToBase});

Future<List<OnlineRate>> fetchOnlineRates(
  String base,
  Set<String> codes,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  // Fetch the base currency table. No accounts, amounts or list of holdings
  // are sent to the provider.
  final uri = Uri.https('api.frankfurter.dev', '/v2/rates', {'base': base});
  Future<List<OnlineRate>> read() async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Rates HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 128 * 1024) {
        throw const FormatException('Rate table too large');
      }
      bytes.addAll(chunk);
    }
    return parseOnlineRates(
      jsonDecode(utf8.decode(bytes)),
      base,
      codes,
      DateTime.now(),
    );
  }

  try {
    return await read().timeout(const Duration(seconds: 15));
  } finally {
    client.close(force: true);
  }
}

List<OnlineRate> parseOnlineRates(
  Object? data,
  String base,
  Set<String> codes,
  DateTime today,
) {
  if (data is! List) throw const FormatException('Expected rate table');
  final quotes = <OnlineRate>[];
  for (final row in data) {
    if (row case {
      'base': String from,
      'quote': String code,
      'rate': num rate,
      'date': String day,
    }) {
      if (from != base || !codes.contains(code) || code == base) continue;
      final date = parseCurrencyDateKey(day);
      final inverse = 1 / rate;
      if (rate <= 0 ||
          !rate.isFinite ||
          !inverse.isFinite ||
          date == null ||
          date.isAfter(today)) {
        continue;
      }
      quotes.add((code: code, date: date, rateToBase: inverse));
    }
  }
  return quotes;
}
