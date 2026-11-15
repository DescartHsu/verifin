part of 'veri_fin_controller.dart';

/// Desktop only receives this book's public accounting fields. Device settings,
/// card numbers, credentials and attachment files never enter the transport.
extension LanLedger on VeriFinController {
  bool _lanEditable(
    LedgerEntry e,
    Map<String, Account> byAccount,
    Set<String> systemCategories,
  ) =>
      (e.type == EntryType.expense || e.type == EntryType.income) &&
      !systemCategories.contains(e.categoryId) &&
      e.currencyCode == activeBook.baseCurrencyCode &&
      e.conversionSource == ConversionSource.identity &&
      e.baseAmount == e.amount &&
      (e.accountId.isEmpty ||
          (byAccount[e.accountId]?.currencyCode == e.currencyCode &&
              e.accountAmount == e.amount));

  lan.Json lanSnapshot() {
    final byAccount = {for (final a in accounts) a.id: a};
    final system = {
      for (final c in categories)
        if (c.isBalanceAdjust) c.id,
    };
    return {
      'bookId': activeBook.id,
      'name': activeBook.name,
      'currency': activeBook.baseCurrencyCode,
      'minorUnit': activeBaseCurrency.minorUnit,
      'accounts': [
        for (final a in accounts)
          {
            'id': a.id,
            'name': a.name,
            'currency': a.currencyCode,
            'balance': accountBalance(a),
            'hidden': a.hidden,
          },
      ],
      'categories': [
        for (final c in categories)
          {
            'id': c.id,
            'name': c.label,
            'type': c.type.storageValue,
            'system': c.isBalanceAdjust,
          },
      ],
      'entries': [
        for (final e in entries)
          {
            'id': e.id,
            'type': e.type.storageValue,
            'amount': e.amount,
            'currency': e.currencyCode,
            'note': e.note,
            'date': e.occurredAt.toIso8601String(),
            'account': e.accountId,
            'category': e.categoryId,
            'rev': lan.digest(e.toJson()),
            'editable': _lanEditable(e, byAccount, system),
          },
      ],
    };
  }

  Future<bool> applyLanEdit(
    String bookId,
    lan.Json edit, {
    bool replayOnly = false,
  }) => _serializeEntrySave(() => _applyLanEdit(bookId, edit, replayOnly));

  Future<bool> _applyLanEdit(
    String bookId,
    lan.Json edit,
    bool replayOnly,
  ) async {
    if (activeBook.id != bookId) return false;
    final body = edit['entry'] as lan.Json;
    final id = body['id'] as String;
    if (edit['id'] != id || id.isEmpty || id.length > 256) return false;
    final original = _entries.where((e) => e.id == id).firstOrNull;
    final amount = (body['amount'] as num).toDouble();
    final note = body['note'] as String;
    final category = categories
        .where((c) => c.id == body['category'])
        .firstOrNull;
    final accountId = body['account'] as String;
    final code = activeBook.baseCurrencyCode;
    if (!amount.isFinite ||
        amount <= 0 ||
        amount > 1e15 ||
        normalizeCurrencyAmount(amount, code) != amount ||
        note.length > 4096 ||
        body['currency'] != code ||
        category == null ||
        category.isBalanceAdjust ||
        category.type.storageValue != body['type'] ||
        !(category.type == EntryType.expense ||
            category.type == EntryType.income) ||
        (accountId.isNotEmpty &&
            !accounts.any(
              (a) => a.id == accountId && a.currencyCode == code,
            ))) {
      return false;
    }
    final date = DateTime.tryParse(body['date'] as String);
    if (date == null) return false;
    LedgerEntry next;
    if (original == null) {
      if (replayOnly || edit['base'] != null || !id.startsWith('lan-')) {
        return false;
      }
      next = LedgerEntry(
        id: id,
        bookId: bookId,
        type: category.type,
        amount: amount,
        currencyCode: code,
        categoryId: category.id,
        accountId: accountId,
        note: note,
        occurredAt: date,
      );
    } else {
      if (original.bookId != bookId ||
          !_lanEditable(
            original,
            {for (final a in accounts) a.id: a},
            {
              for (final c in categories)
                if (c.isBalanceAdjust) c.id,
            },
          ) ||
          original.accountId != accountId ||
          original.categoryId != category.id ||
          original.occurredAt != date) {
        return false;
      }
      // A lost acknowledgement may replay an already committed edit.
      if (original.amount == amount && original.note == note) return true;
      if (replayOnly || lan.digest(original.toJson()) != edit['base']) {
        return false;
      }
      next = original.copyWith(
        amount: amount,
        baseAmount: amount,
        accountAmount: accountId.isEmpty ? null : amount,
        note: note,
      );
    }
    final result = await _saveEntryAggregate(
      entry: next,
      isNew: original == null,
      refunds: _entries.where((e) => e.refundOf == id).toList(),
      attachments: attachmentsForEntry(id),
    );
    if (result is EntrySavePersistenceFailure) throw StateError('storage');
    return result.isSuccess;
  }
}
