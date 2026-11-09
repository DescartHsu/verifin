import 'dart:async';

import 'package:anchored_menu/anchored_menu.dart';
import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/calendar_days.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/online_rates.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

class CurrencyRatesPage extends StatefulWidget {
  const CurrencyRatesPage({super.key, this.fetchRates = fetchOnlineRates});

  final Future<List<OnlineRate>> Function(String, Set<String>) fetchRates;

  @override
  State<CurrencyRatesPage> createState() => _CurrencyRatesPageState();
}

class _CurrencyRatesPageState extends State<CurrencyRatesPage> {
  String? _openedBook;
  bool _busy = false;
  bool _offeredLegacySetup = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = VeriFinScope.of(context);
    final book = controller.activeBook;
    if (_openedBook != book.id) {
      _openedBook = book.id;
      if (controller.autoRates &&
          controller.foreignRateCodes.isNotEmpty &&
          book.currencySetupStatus == CurrencySetupStatus.confirmed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              controller.activeBook.id == book.id &&
              controller.autoRates) {
            unawaited(_refresh(automatic: true));
          }
        });
      }
    }
    if (!_offeredLegacySetup &&
        book.currencySetupStatus == CurrencySetupStatus.legacyUnconfirmed) {
      _offeredLegacySetup = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          confirmLegacyLedgerCurrency(context: context, book: book);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final book = controller.activeBook;
    final base = CurrencyCatalog.require(book.baseCurrencyCode);
    final codes = controller.foreignRateCodes;

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.currencyRatesTitle,
                subtitle: l10n.currentBookLabel(book.name),
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.help_outline,
                    tooltip: l10n.currencyRatesHelpTitle,
                    onPressed: _showRateHelp,
                  ),
                  if (book.currencySetupStatus == CurrencySetupStatus.confirmed)
                    HeaderAction(
                      icon: Icons.add,
                      tooltip: l10n.exchangeRateAdd,
                      onPressed: _addRate,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Row(
                  children: <Widget>[
                    VeriIconBox(
                      icon: Icons.account_balance_wallet_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.ledgerBaseCurrency,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.55),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${base.code} · ${base.nameForLocale(Localizations.localeOf(context).toLanguageTag())}',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (book.currencySetupStatus ==
                  CurrencySetupStatus.legacyUnconfirmed)
                _LegacySetupCard(book: book)
              else ...<Widget>[
                VeriCard(
                  child: Column(
                    children: [
                      Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          title: Text(l10n.rateAutoTitle),
                          subtitle: Text(l10n.rateAutoDescription),
                          value: controller.autoRates,
                          onChanged: _busy ? null : _toggleAuto,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : () => _refresh(),
                        icon: const Icon(Icons.sync),
                        label: Text(
                          _busy ? l10n.rateRefreshing : l10n.rateFetch,
                        ),
                      ),
                    ],
                  ),
                ),
                SectionLabel(l10n.exchangeRateCurrencies),
                if (codes.isEmpty)
                  VeriCard(
                    child: EmptyState(
                      icon: Icons.currency_exchange,
                      title: l10n.exchangeRateEmpty,
                      description: l10n.exchangeRateEmptyDesc,
                    ),
                  )
                else
                  VeriCard(
                    child: Column(
                      children: <Widget>[
                        for (final item in codes.indexed) ...<Widget>[
                          _CurrencyRateRow(currencyCode: item.$2),
                          if (item.$1 != codes.length - 1)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleAuto(bool value) async {
    final controller = VeriFinScope.of(context);
    setState(() => _busy = true);
    try {
      await controller.setAutoRates(value);
    } catch (error) {
      controller.logger?.warning(
        error.runtimeType.toString(),
        source: 'rate-preference',
      );
      if (mounted) {
        _message(AppLocalizations.of(context).saveFailed, error: true);
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && value) await _refresh(automatic: true);
  }

  void _message(String message, {bool error = false}) {
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: message,
        tone: error ? VeriFeedbackTone.error : VeriFeedbackTone.success,
      ),
    );
  }

  Future<void> _refresh({bool automatic = false}) async {
    if (_busy) return;
    final controller = VeriFinScope.of(context);
    final book = controller.activeBook;
    final l10n = AppLocalizations.of(context);
    final codes = controller.foreignRateCodes.toSet();
    setState(() => _busy = true);
    try {
      if (codes.isEmpty) {
        if (automatic) return;
        final selected = await showCurrencyPickerSheet(
          context: context,
          title: l10n.selectRateCurrency,
          excludedCodes: [book.baseCurrencyCode],
        );
        if (!mounted ||
            selected == null ||
            controller.activeBook.id != book.id) {
          return;
        }
        codes.add(selected.code);
      }
      final missing = await controller.refreshExchangeRates(
        codes,
        fetch: widget.fetchRates,
      );
      if (!mounted || controller.activeBook.id != book.id) return;
      if (missing.isNotEmpty) {
        _message(l10n.rateUnavailable(missing.join(', ')), error: true);
      } else if (!automatic) {
        _message(l10n.rateRefreshed);
      }
    } catch (error) {
      controller.logger?.warning(
        error.runtimeType.toString(),
        source: 'rate-refresh',
      );
      if (mounted) _message(l10n.rateFetchFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addRate() async {
    final controller = VeriFinScope.of(context);
    final selected = await showCurrencyPickerSheet(
      context: context,
      title: AppLocalizations.of(context).selectRateCurrency,
      excludedCodes: <String>[controller.activeBook.baseCurrencyCode],
      preferredCodes: <String>[
        ...controller.accounts.map((account) => account.currencyCode),
        ...controller.exchangeRates.map((rate) => rate.currencyCode),
      ],
    );
    if (!mounted || selected == null) return;
    await editExchangeRate(context: context, currencyCode: selected.code);
  }

  Future<void> _showRateHelp() {
    final l10n = AppLocalizations.of(context);
    return showInfoDialog(
      context: context,
      title: l10n.currencyRatesHelpTitle,
      message: l10n.currencyRatesOfflineDesc,
    );
  }
}

class _LegacySetupCard extends StatelessWidget {
  const _LegacySetupCard({required this.book});

  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.legacyCurrencySetupTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(l10n.legacyCurrencySetupDesc),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () =>
                  confirmLegacyLedgerCurrency(context: context, book: book),
              child: Text(l10n.legacyCurrencyStart),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrencyRateRow extends StatelessWidget {
  const _CurrencyRateRow({required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final currency = CurrencyCatalog.require(currencyCode);
    final rates = controller.exchangeRates
        .where((rate) => rate.currencyCode == currencyCode)
        .toList();
    final today = DateTime.now();
    final current = controller.exchangeRateFor(currencyCode, today);
    final future =
        rates
            .where((rate) => calendarDaysBetween(today, rate.effectiveDate) > 0)
            .toList()
          ..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
    final displayed = current ?? (future.isEmpty ? null : future.first);
    final stale = current != null && isExchangeRateStale(current, today);
    final status = displayed == null
        ? null
        : <String>[
            exchangeRateSourceLabel(l10n, displayed.source),
            if (displayed == current && stale) l10n.exchangeRateStale,
            if (displayed != current) l10n.exchangeRateNotEffective,
            if (current != null && future.isNotEmpty)
              l10n.exchangeRateFutureCount(future.length),
          ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: ListTile(
        key: Key('currency_rate_$currencyCode'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: SizedBox(
          width: 44,
          child: Text(
            currencyCode,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        title: Text(
          displayed == null
              ? currency.nameForLocale(
                  Localizations.localeOf(context).toLanguageTag(),
                )
              : l10n.exchangeRateEquation(
                  currencyCode,
                  formatRateValue(displayed.rateToBase),
                  controller.activeBook.baseCurrencyCode,
                ),
        ),
        subtitle: Text(
          displayed == null
              ? l10n.exchangeRateNotSet
              : l10n.exchangeRateDateAndStatus(
                  l10n.dateYearMonthDay(displayed.effectiveDate),
                  status!,
                ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (context) =>
                CurrencyRateHistoryPage(currencyCode: currencyCode),
          ),
        ),
      ),
    );
  }
}

class CurrencyRateHistoryPage extends StatelessWidget {
  const CurrencyRateHistoryPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final rates = controller.exchangeRates
        .where((rate) => rate.currencyCode == currencyCode)
        .toList();
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.exchangeRateHistory(currencyCode),
                subtitle: l10n.exchangeRateAgainst(
                  controller.activeBook.baseCurrencyCode,
                ),
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.add,
                    tooltip: l10n.exchangeRateAdd,
                    onPressed: () => editExchangeRate(
                      context: context,
                      currencyCode: currencyCode,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (rates.isEmpty)
                VeriCard(
                  child: EmptyState(
                    icon: Icons.history,
                    title: l10n.exchangeRateHistoryEmpty,
                    description: l10n.exchangeRateHistoryEmptyDesc,
                  ),
                )
              else
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      for (final item in rates.indexed) ...<Widget>[
                        _RateHistoryRow(rate: item.$2),
                        if (item.$1 != rates.length - 1)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RateHistoryRow extends StatelessWidget {
  const _RateHistoryRow({required this.rate});

  final ExchangeRate rate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final future = calendarDaysBetween(DateTime.now(), rate.effectiveDate) > 0;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          l10n.exchangeRateEquation(
            rate.currencyCode,
            formatRateValue(rate.rateToBase),
            rate.baseCurrencyCode,
          ),
        ),
        subtitle: Text(
          l10n.exchangeRateDateAndStatus(
            l10n.dateYearMonthDay(rate.effectiveDate),
            <String>[
              exchangeRateSourceLabel(l10n, rate.source),
              if (future) l10n.exchangeRateNotEffective,
            ].join(' · '),
          ),
        ),
        onTap: () => editExchangeRate(
          context: context,
          currencyCode: rate.currencyCode,
          existing: rate,
        ),
        trailing: AnchoredMenuButton(
          icon: Icons.more_vert,
          tooltip: l10n.exchangeRateHistory(rate.currencyCode),
          entries: <AnchoredMenuEntry>[
            AnchoredMenuItem(
              id: 'rate_edit',
              icon: Icons.edit_outlined,
              title: l10n.commonEdit,
              onPressed: () async => editExchangeRate(
                context: context,
                currencyCode: rate.currencyCode,
                existing: rate,
              ),
            ),
            const AnchoredMenuDivider(),
            AnchoredMenuItem(
              id: 'rate_delete',
              icon: Icons.delete_outline,
              title: l10n.commonDelete,
              foregroundColor: Theme.of(context).colorScheme.error,
              onPressed: () async => _deleteRate(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteRate(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.exchangeRateDeleteTitle,
      message: l10n.exchangeRateDeleteMessage,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (!context.mounted || !confirmed) return;
    final deleted = await VeriFinScope.of(context).deleteExchangeRate(rate.id);
    if (!context.mounted || deleted) return;
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: l10n.saveFailed,
        tone: VeriFeedbackTone.error,
        duration: VeriFeedbackDuration.long,
        priority: VeriFeedbackPriority.high,
        dedupeKey: 'exchange-rate-save',
      ),
    );
  }
}

Future<void> editExchangeRate({
  required BuildContext context,
  required String currencyCode,
  ExchangeRate? existing,
}) async {
  final l10n = AppLocalizations.of(context);
  final initialDate = existing?.effectiveDate ?? DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: DateTime(1970),
    lastDate: DateTime(2100),
    helpText: l10n.exchangeRateEffectiveDate,
  );
  if (!context.mounted || date == null) return;
  final controller = VeriFinScope.of(context);
  final amount = await showNumberPadSheet(
    context,
    title: l10n.exchangeRateInputTitle(
      currencyCode,
      controller.activeBook.baseCurrencyCode,
    ),
    initialAmount: existing?.rateToBase,
    maxFractionDigits: 10,
  );
  if (!context.mounted || amount == null) return;
  final hadWaitingRecurring = controller
      .dueRecurringMissingRates(DateTime.now())
      .isNotEmpty;
  final saved = await controller.saveExchangeRateDraft(
    id: existing?.id,
    currencyCode: currencyCode,
    effectiveDate: date,
    rateToBase: amount,
    // 用户只要在编辑器里确认保存，这条记录就已经是手工维护的值；不能再把
    // 手工修改后的结果标成“导入”。
    source: ExchangeRateSource.manual,
  );
  if (!context.mounted) return;
  if (!saved) {
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: l10n.saveFailed,
        tone: VeriFeedbackTone.error,
        duration: VeriFeedbackDuration.long,
        priority: VeriFeedbackPriority.high,
        dedupeKey: 'exchange-rate-save',
      ),
    );
    return;
  }
  final result = await VeriFeedbackHost.of(context).showMessage(
    message: l10n.exchangeRateSaved,
    tone: VeriFeedbackTone.success,
    duration: hadWaitingRecurring
        ? VeriFeedbackDuration.long
        : VeriFeedbackDuration.standard,
    actionLabel: hadWaitingRecurring ? l10n.recurringRetryNow : null,
  );
  if (!context.mounted || result != VeriFeedbackResult.action) return;
  final generated = await controller.applyDueRecurring(DateTime.now());
  if (!context.mounted) return;
  unawaited(
    VeriFeedbackHost.of(context).showMessage(
      message: generated < 0
          ? l10n.saveFailed
          : l10n.recurringGeneratedCount(generated),
      tone: generated < 0 ? VeriFeedbackTone.error : VeriFeedbackTone.success,
    ),
  );
}

String exchangeRateSourceLabel(
  AppLocalizations l10n,
  ExchangeRateSource source,
) {
  return switch (source) {
    ExchangeRateSource.frankfurter => 'Frankfurter',
    ExchangeRateSource.manual => l10n.exchangeRateSourceManual,
    ExchangeRateSource.imported => l10n.exchangeRateSourceImported,
  };
}
