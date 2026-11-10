import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/credit_card.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'transactions_pages.dart';

class CardCurrenciesPage extends StatefulWidget {
  const CardCurrenciesPage({super.key, required this.card});
  final Account card;

  @override
  State<CardCurrenciesPage> createState() => _CardCurrenciesPageState();
}

class _CardCurrenciesPageState extends State<CardCurrenciesPage> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final members = controller.cardCurrencyAccounts(widget.card);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              VeriHeader(
                title: l10n.cardCurrencies,
                subtitle: widget.card.name,
                showBack: true,
                actions: [
                  if (!_adding && members.isNotEmpty)
                    HeaderAction(
                      icon: Icons.add,
                      tooltip: l10n.addCardCurrency,
                      onPressed: _add,
                    ),
                ],
              ),
              for (final account in members) ...[
                const SizedBox(height: 10),
                VeriCard(
                  child: Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(account.currencyCode),
                      subtitle: Text(
                        [
                          '${l10n.currentBalance}  ${formatUserMoney(controller.accountBalance(account), account.currencyCode)}',
                          if (account.type.supportsCredit)
                            '${l10n.aiHeaderCurrentDebt}  ${formatUserMoney(usedCredit(controller.accountBalance(account)), account.currencyCode)}',
                        ].join('\n'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => TransactionsPage(
                            accountId: account.id,
                            title: l10n.accountEntriesTitle(account.name),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add() async {
    if (_adding) return;
    final controller = VeriFinScope.of(context);
    final book = controller.activeBook;
    final l10n = AppLocalizations.of(context);
    setState(() => _adding = true);
    try {
      if (book.currencySetupStatus == CurrencySetupStatus.legacyUnconfirmed) {
        final ok = await confirmLegacyLedgerCurrency(
          context: context,
          book: book,
        );
        if (!mounted || !ok) return;
      }
      final currency = await showCurrencyPickerSheet(
        context: context,
        title: l10n.addCardCurrency,
        excludedCodes: controller
            .cardCurrencyAccounts(widget.card)
            .map((a) => a.currencyCode),
      );
      if (!mounted || currency == null) return;
      final balance = await showNumberPadSheet(
        context,
        title: widget.card.type.supportsCredit
            ? '${l10n.accountBalanceCurrencyLabel(currency.code)} · ${l10n.cardDebtInputHint}'
            : l10n.accountBalanceCurrencyLabel(currency.code),
        currencyCode: currency.code,
        allowNegative: true,
        allowZero: true,
      );
      if (!mounted || balance == null) return;
      final saved = await controller.addCardCurrency(
        widget.card,
        currency.code,
        balance,
      );
      if (!mounted || saved) return;
      unawaited(
        VeriFeedbackHost.of(
          context,
        ).showMessage(message: l10n.saveFailed, tone: VeriFeedbackTone.error),
      );
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}
