import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'lan_host.dart';
import 'ledger_store.dart';

String tr(String zh, String en) =>
    WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh'
    ? zh
    : en;
String money(Json row) => NumberFormat.currency(
  name: row['currency'] as String,
  symbol: '${row['currency']} ',
).format(row['amount'] ?? row['balance']);
List<Json> rows(Json? data, String key) =>
    (data?[key] as List? ?? []).cast<Json>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      title: 'VeriFin',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh'), Locale('en')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DesktopHome(),
    ),
  );
}

class DesktopHome extends StatefulWidget {
  const DesktopHome({super.key, this.initialHost});
  final LanHost? initialHost;
  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<DesktopHome> {
  LanHost? host;
  String? error;
  bool listening = false;
  String search = '';
  Json? _lastSnapshot;
  List<Json>? _lastPending;
  String? _lastSearch;
  Map<String, Json> entries = {}, edits = {};
  Map<String, String> cats = {}, names = {};
  List<Json> accounts = [], ordered = [], shown = [];
  void _refreshView(Json? snapshot, List<Json> pending) {
    if (!identical(snapshot, _lastSnapshot) ||
        !identical(pending, _lastPending)) {
      _lastSnapshot = snapshot;
      _lastPending = pending;
      _lastSearch = null;
      entries = {
        for (final e in rows(snapshot, 'entries')) e['id'] as String: e,
      };
      edits = {for (final e in pending) e['id'] as String: e};
      ordered =
          {
            ...entries,
            for (final e in edits.entries) e.key: e.value['entry'] as Json,
          }.values.toList()..sort(
            (a, b) => (b['date'] as String).compareTo(a['date'] as String),
          );
      cats = {
        for (final c in rows(snapshot, 'categories'))
          c['id'] as String: c['name'] as String,
      };
      final deltas = <String, double>{};
      for (final draft in pending) {
        if (draft['blocked'] == true) continue;
        final row = draft['entry'] as Json, account = row['account'] as String;
        if (account.isEmpty) continue;
        final prior = entries[row['id']];
        // The phone may already have applied this offline edit before its
        // acknowledgement was received. Only add the outstanding difference.
        final change =
            (row['amount'] as num).toDouble() -
            ((prior?['amount'] as num?)?.toDouble() ?? 0);
        deltas.update(
          account,
          (n) => n + (row['type'] == 'expense' ? -change : change),
          ifAbsent: () => row['type'] == 'expense' ? -change : change,
        );
      }
      accounts = [
        for (final a in rows(snapshot, 'accounts'))
          {...a, 'balance': (a['balance'] as num) + (deltas[a['id']] ?? 0)},
      ];
      names = {
        for (final a in accounts) a['id'] as String: a['name'] as String,
      };
    }
    if (_lastSearch != search) {
      _lastSearch = search;
      shown = ordered
          .where(
            (e) => [
              e['note'],
              cats[e['category']],
              names[e['account']],
              e['amount'],
            ].join(' ').toLowerCase().contains(search.toLowerCase()),
          )
          .toList();
    }
  }

  @override
  void initState() {
    super.initState();
    host = widget.initialHost;
    if (host == null) {
      unawaited(_open());
    } else {
      listening = true;
    }
  }

  Future<void> _open() async {
    try {
      host ??= LanHost(await openDesktopLedger());
      await host!.start();
      if (mounted) {
        setState(() {
          listening = true;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            '无法打开本地数据库或监听局域网端口。请检查是否已启动另一个电脑版。',
            'Cannot open the database or LAN port. Check for another running instance.',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    final h = host;
    if (h != null && widget.initialHost == null) {
      unawaited(
        h.stop().then((_) {
          h.dispose();
          h.store.db.close();
        }),
      );
    }
    super.dispose();
  }

  Future<void> _pair() async {
    final h = host!;
    await h.refreshAddresses();
    if (!mounted) return;
    h.newInvitation();
    await showDialog<void>(
      context: context,
      builder: (_) => DesktopPairDialog(h),
    );
    h.cancelInvite();
  }

  Future<void> _disconnect() async {
    final h = host!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('解除配对并清除此电脑的账本？', 'Unpair and clear this computer?')),
        content: Text(
          tr(
            '手机上的账目会保留。此电脑缓存的流水和未同步修改将被删除。',
            'Phone data is retained. Cached transactions and pending edits on this computer will be deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('解除并清除', 'Unpair and clear')),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      h.store.forget();
      setState(() {});
    }
  }

  Future<void> _edit(Json snapshot, {Json? entry, Json? pending}) async {
    final value = await showDialog<Json>(
      context: context,
      builder: (_) => _EditEntry(snapshot, entry),
    );
    if (value != null && mounted) {
      setState(
        () => host!.store.stage(
          value,
          pending != null
              ? pending['base'] as String?
              : entry?['rev'] as String?,
        ),
      );
    }
  }

  Future<void> _resolve(Json pending, Json? phone) async {
    final desired = pending['entry'] as Json;
    String describe(Json? e) => e == null
        ? tr('已删除或尚未添加', 'Deleted or not yet added')
        : '${money(e)}  ${e['note']}';
    final useDesktop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('核对两端记录', 'Review conflicting changes')),
        content: Text(
          '${tr('手机', 'Phone')}  ${describe(phone)}\n\n${tr('电脑', 'Computer')}  ${describe(desired)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('保留手机版', 'Keep phone version')),
          ),
          if (phone?['editable'] == true || phone == null)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('使用电脑版', 'Use desktop version')),
            ),
        ],
      ),
    );
    if (useDesktop != null && mounted) {
      setState(
        () => host!.store.resolve(
          pending['id'] as String,
          phone?['rev'] as String?,
          useDesktop: useDesktop,
          phone: phone,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = host;
    if (h == null) {
      return Scaffold(
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Text(error!),
        ),
      );
    }
    return ListenableBuilder(
      listenable: h,
      builder: (context, _) {
        final snapshot = h.store.snapshot;
        _refreshView(snapshot, h.store.edits);
        return Scaffold(
          appBar: AppBar(
            title: Text(snapshot?['name'] as String? ?? 'VeriFin'),
            actions: [
              if (h.paired && widget.initialHost == null)
                TextButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: Text(tr('解除配对', 'Unpair')),
                )
              else if (!h.paired && listening)
                FilledButton.icon(
                  onPressed: _pair,
                  icon: const Icon(Icons.qr_code),
                  label: Text(tr('连接手机', 'Connect phone')),
                ),
              const SizedBox(width: 20),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (error != null)
                  TextButton(onPressed: _open, child: Text(error!)),
                if (snapshot == null)
                  Expanded(
                    child: Center(
                      child: Text(
                        h.paired
                            ? tr(
                                '已配对，等待手机传入账本。',
                                'Paired. Waiting for the ledger.',
                              )
                            : tr(
                                '点击「连接手机」，用 VeriFin 的「局域网同步」扫码。',
                                'Choose Connect phone, then scan the code in VeriFin → LAN sync.',
                              ),
                      ),
                    ),
                  )
                else ...[
                  Text(
                    '${h.lastSeen == null ? tr('离线账本', 'Offline ledger') : '${tr('上次连接', 'Last contact')}  ${DateFormat.Hm().format(h.lastSeen!)}'}     ${tr('待同步', 'Pending')}  ${edits.length}',
                  ),
                  const SizedBox(height: 12),
                  if (accounts.isNotEmpty)
                    SizedBox(
                      height: 64,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: accounts.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (ctx, i) => Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(accounts[i]['name'] as String),
                                Text(money(accounts[i])),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (s) => setState(() => search = s),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            labelText: tr('搜索流水', 'Search transactions'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      FilledButton.icon(
                        onPressed: () => _edit(snapshot),
                        icon: const Icon(Icons.add),
                        label: Text(tr('记一笔', 'Add transaction')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (ctx, i) {
                        final e = shown[i],
                            pending = edits[e['id']],
                            conflict = pending?['blocked'] == true;
                        final kind = switch (e['type']) {
                          'expense' => tr('支出', 'Expense'),
                          'income' => tr('收入', 'Income'),
                          'refund' => tr('退款', 'Refund'),
                          _ => tr('转账', 'Transfer'),
                        };
                        final day = DateTime.parse(e['date'] as String);
                        return ListTile(
                          key: ValueKey(e['id']),
                          leading: Icon(
                            conflict
                                ? Icons.warning_amber
                                : pending != null
                                ? Icons.schedule
                                : Icons.receipt_long_outlined,
                          ),
                          title: Text(
                            '$kind  ${cats[e['category']] ?? ''}     ${e['note']}',
                          ),
                          subtitle: Text(
                            '${DateFormat.yMd(Localizations.localeOf(context).toLanguageTag()).format(day)}  ${names[e['account']] ?? ''}',
                          ),
                          trailing: Text(money(e)),
                          onTap: conflict
                              ? () => _resolve(pending!, entries[e['id']])
                              : (e['editable'] == true || pending != null)
                              ? () =>
                                    _edit(snapshot, entry: e, pending: pending)
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class DesktopPairDialog extends StatefulWidget {
  const DesktopPairDialog(this.host, {super.key});
  final LanHost host;
  @override
  State<DesktopPairDialog> createState() => _DesktopPairDialogState();
}

class _DesktopPairDialogState extends State<DesktopPairDialog> {
  String? ip;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    ip = widget.host.addresses.firstOrNull;
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String tr(String zh, String en) =>
        Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
    final h = widget.host, invite = ip == null ? null : h.invite(ip!);
    return AlertDialog(
      title: Text(tr('局域网同步', 'LAN sync')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (h.paired)
            Text(tr('手机已连接', 'Phone connected'))
          else ...[
            Text(
              tr(
                '请用手机首页右上角扫码。电脑将显示已授权的手机账本，修改会自动同步。',
                'Scan from the phone home screen to open the authorized phone books. Edits sync automatically.',
              ),
            ),
            if (h.addresses.isEmpty)
              Text(
                tr('请连接家庭局域网后重试。', 'Connect to a local network and try again.'),
              )
            else
              DropdownButton<String>(
                value: ip,
                items: [
                  for (final a in h.addresses)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (a) => setState(() => ip = a),
              ),
            if (invite != null)
              QrImageView(
                data: invite.qr,
                size: 240,
                backgroundColor: Colors.white,
              )
            else if (ip != null)
              TextButton(
                onPressed: () => setState(h.newInvitation),
                child: Text(tr('刷新配对码', 'Refresh QR code')),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('关闭', 'Close')),
        ),
      ],
    );
  }
}

class _EditEntry extends StatefulWidget {
  const _EditEntry(this.book, this.entry);
  final Json book;
  final Json? entry;
  @override
  State<_EditEntry> createState() => _EditEntryState();
}

class _EditEntryState extends State<_EditEntry> {
  late final amount = TextEditingController(
    text: widget.entry?['amount']?.toString(),
  );
  late final note = TextEditingController(
    text: widget.entry?['note'] as String?,
  );
  late String kind = widget.entry?['type'] as String? ?? 'expense',
      account = widget.entry?['account'] as String? ?? '';
  late String? category = widget.entry?['category'] as String?;
  bool invalid = false;
  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book, old = widget.entry;
    final categories = rows(
      book,
      'categories',
    ).where((c) => c['type'] == kind && c['system'] != true).toList();
    final selected = category ?? categories.firstOrNull?['id'] as String?;
    return AlertDialog(
      title: Text(
        old == null
            ? tr('记一笔', 'Add transaction')
            : tr('编辑流水', 'Edit transaction'),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (old == null) ...[
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'expense',
                      label: Text(tr('支出', 'Expense')),
                    ),
                    ButtonSegment(
                      value: 'income',
                      label: Text(tr('收入', 'Income')),
                    ),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setState(() {
                    kind = v.first;
                    category = null;
                  }),
                ),
                DropdownButton<String>(
                  value: selected,
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(
                        value: c['id'] as String,
                        child: Text(c['name'] as String),
                      ),
                  ],
                  onChanged: (v) => setState(() => category = v),
                ),
                DropdownButton<String>(
                  value: account,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(tr('无账户', 'No account')),
                    ),
                    for (final a in rows(book, 'accounts').where(
                      (a) =>
                          a['currency'] == book['currency'] &&
                          a['hidden'] != true,
                    ))
                      DropdownMenuItem(
                        value: a['id'] as String,
                        child: Text(a['name'] as String),
                      ),
                  ],
                  onChanged: (v) => setState(() => account = v ?? ''),
                ),
              ],
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '${tr('金额', 'Amount')} (${book['currency']})',
                  errorText: invalid
                      ? tr('请输入有效金额并选择分类', 'Enter a valid amount and category')
                      : null,
                ),
              ),
              TextField(
                controller: note,
                maxLength: 4096,
                decoration: InputDecoration(labelText: tr('备注', 'Note')),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () {
            final n = double.tryParse(amount.text.trim());
            if (n == null ||
                !n.isFinite ||
                n <= 0 ||
                n > 1e15 ||
                n !=
                    double.tryParse(
                      n.toStringAsFixed((book['minorUnit'] as int?) ?? 2),
                    ) ||
                selected == null) {
              setState(() => invalid = true);
              return;
            }
            Navigator.pop(context, <String, dynamic>{
              ...?old,
              'id': old?['id'] ?? 'lan-${secret()}',
              'type': kind,
              'amount': n,
              'currency': book['currency'],
              'account': account,
              'category': selected,
              'date': old?['date'] ?? DateTime.now().toIso8601String(),
              'note': note.text,
              'editable': true,
            });
          },
          child: Text(tr('保存', 'Save')),
        ),
      ],
    );
  }
}
