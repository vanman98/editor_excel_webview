import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LuckysheetPocPage(),
    ),
  );
}

enum ChangeFilter { all, value, formula, style }

class LuckysheetPocPage extends StatefulWidget {
  const LuckysheetPocPage({super.key});

  @override
  State<LuckysheetPocPage> createState() => _LuckysheetPocPageState();
}

class _LuckysheetPocPageState extends State<LuckysheetPocPage> {
  late final WebViewController _controller;

  String _status = 'Ready';
  bool _webReady = false;

  /// key: sheetKey#r#c
  final Map<String, Map<String, dynamic>> _changes = {};

  /// sheetKey -> {id,name,order}
  final Map<String, Map<String, dynamic>> _sheetMetaById = {};

  /// sheetKey -> list of ops
  final Map<String, List<Map<String, dynamic>>> _sheetOpsById = {};

  /// UI state
  String? _selectedSheetId;
  String? _selectedChangeKey;
  ChangeFilter _filter = ChangeFilter.all;
  String _search = '';
  final Set<String> _reviewedKeys = {};
  bool _isTrackerVisible = true;

  // ---------------- helpers ----------------
  int _toInt(dynamic v, {int fallback = 0}) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  String _toStr(dynamic v, {String fallback = ''}) {
    if (v == null) return fallback;
    return v.toString();
  }

  /// sheetKey ưu tiên: sheetId -> sheetIndex -> sheetName
  String _sheetKeyFromMap(Map<String, dynamic> m) {
    final sheetId = _toStr(m['sheetId']);
    if (sheetId.isNotEmpty) return sheetId;

    final sheetIndex = _toStr(m['sheetIndex']);
    if (sheetIndex.isNotEmpty) return sheetIndex;

    final sheetName = _toStr(m['sheetName']);
    if (sheetName.isNotEmpty) return sheetName;

    return 'Unknown';
  }

  String _makeKey(Map<String, dynamic> change) {
    final sheetKey = _sheetKeyFromMap(change);
    final r = _toInt(change['r']);
    final c = _toInt(change['c']);
    return '$sheetKey#$r#$c';
  }

  void _ensureSelectedSheet() {
    if (_selectedSheetId != null) return;
    final ids = _allSheetIds();
    if (ids.isNotEmpty) _selectedSheetId = ids.first;
  }

  void _ensureSelectedChange(List<_ChangeRow> feed) {
    if (_selectedChangeKey != null &&
        _changes.containsKey(_selectedChangeKey)) {
      return;
    }
    if (feed.isNotEmpty) _selectedChangeKey = feed.first.key;
  }

  void _upsertSheetMetaFromChange(Map<String, dynamic> ch) {
    final id = _sheetKeyFromMap(ch);
    if (id.isEmpty) return;

    final prev = _sheetMetaById[id] ?? const <String, dynamic>{};
    _sheetMetaById[id] = {
      'id': id,
      'name': _toStr(
        ch['sheetName'],
        fallback: _toStr(prev['name'], fallback: 'Sheet'),
      ),
      'order': _toInt(ch['sheetOrder'], fallback: _toInt(prev['order'])),
    };
  }

  void _upsertSheetMetaFromSheetsList(List<dynamic> sheets) {
    for (final s in sheets) {
      if (s is! Map) continue;
      final m = s.cast<String, dynamic>();

      final id = _toStr(
        m['sheetId'],
        fallback: _toStr(
          m['id'],
          fallback: _toStr(m['index'], fallback: _toStr(m['name'])),
        ),
      );
      if (id.isEmpty) continue;

      final prev = _sheetMetaById[id] ?? const <String, dynamic>{};
      _sheetMetaById[id] = {
        'id': id,
        'name': _toStr(
          m['name'],
          fallback: _toStr(prev['name'], fallback: 'Sheet'),
        ),
        'order': _toInt(m['order'], fallback: _toInt(prev['order'])),
      };
    }
  }

  List<String> _allSheetIds() {
    final ids = <String>{
      ..._sheetMetaById.keys,
      ..._sheetOpsById.keys,
      ..._changes.values.map((e) => _sheetKeyFromMap(e)),
    }.toList();

    ids.sort((a, b) {
      final ao = _toInt(_sheetMetaById[a]?['order']);
      final bo = _toInt(_sheetMetaById[b]?['order']);
      final od = ao.compareTo(bo);
      if (od != 0) return od;
      final an = _toStr(_sheetMetaById[a]?['name'], fallback: a);
      final bn = _toStr(_sheetMetaById[b]?['name'], fallback: b);
      return an.compareTo(bn);
    });

    return ids;
  }

  String _fmtTs(int? ms) {
    if (ms == null || ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  String _displayValueOrFormula(Map<String, dynamic> cellObj) {
    final f = cellObj['formula'];
    if (f != null && f.toString().trim().isNotEmpty) return f.toString();
    final v = cellObj['value'];
    if (v == null) return '(empty)';
    final s = v.toString();
    return s.isEmpty ? '(empty)' : s;
  }

  Map<String, dynamic> _styleOf(Map<String, dynamic> cellObj) {
    final s = cellObj['style'];
    if (s is Map) return s.cast<String, dynamic>();
    return const {};
  }

  bool _hasStyleChange(
    Map<String, dynamic> oldStyle,
    Map<String, dynamic> newStyle,
  ) {
    final keys = {...oldStyle.keys, ...newStyle.keys};
    for (final k in keys) {
      if (oldStyle[k] != newStyle[k]) return true;
    }
    return false;
  }

  bool _hasValueChange(
    Map<String, dynamic> oldObj,
    Map<String, dynamic> newObj,
  ) {
    return oldObj['value'] != newObj['value'];
  }

  bool _hasFormulaChange(
    Map<String, dynamic> oldObj,
    Map<String, dynamic> newObj,
  ) {
    return (oldObj['formula']?.toString() ?? '') !=
        (newObj['formula']?.toString() ?? '');
  }

  // ---------------- lifecycle ----------------
  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final url = req.url;

            final isLocal =
                url.startsWith('flutter-asset://') ||
                url.startsWith('file://') ||
                url.startsWith('about:blank');

            if (isLocal) return NavigationDecision.navigate;

            // DEV allow CDN
            if (!kReleaseMode) {
              final allowDevCdn = url.startsWith('https://cdn.jsdelivr.net');
              return allowDevCdn
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            }

            return NavigationDecision.prevent;
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (msg) => _handleWebMessage(msg.message),
      )
      ..loadFlutterAsset('assets/web/index.html');
  }

  void _handleWebMessage(String message) {
    try {
      final obj = jsonDecode(message) as Map<String, dynamic>;
      final type = obj['type'];

      switch (type) {
        case 'web_ready':
          setState(() {
            _webReady = true;
            _status = 'Web ready';
          });
          return;

        case 'import_ok':
          setState(() {
            _status = 'Import OK. sheets=${obj['sheetCount']}';
            _changes.clear();
            _sheetOpsById.clear();
            _sheetMetaById.clear();
            _selectedSheetId = null;
            _selectedChangeKey = null;
            _reviewedKeys.clear();
          });
          return;

        case 'import_err':
          setState(() => _status = 'Import ERROR: ${obj['err']}');
          return;

        case 'sheet_activate':
          setState(() => _status = 'Active sheet: ${jsonEncode(obj['sheet'])}');
          return;

        case 'sheet_ops':
          final opsRaw = obj['ops'];
          final sheetsRaw = obj['sheets'];

          final ops = (opsRaw is List)
              ? opsRaw
                    .whereType<Map>()
                    .map((e) => e.cast<String, dynamic>())
                    .toList()
              : <Map<String, dynamic>>[];

          final sheets = (sheetsRaw is List) ? sheetsRaw : <dynamic>[];
          _upsertSheetMetaFromSheetsList(sheets);

          final ts = _toInt(
            obj['ts'],
            fallback: DateTime.now().millisecondsSinceEpoch,
          );

          for (final op in ops) {
            final sheet = (op['sheet'] is Map)
                ? (op['sheet'] as Map).cast<String, dynamic>()
                : const <String, dynamic>{};

            final id = _toStr(
              sheet['sheetId'],
              fallback: _toStr(
                sheet['id'],
                fallback: _toStr(
                  sheet['index'],
                  fallback: _toStr(sheet['name'], fallback: 'Unknown'),
                ),
              ),
            );

            (_sheetOpsById[id] ??= []).add({...op, 'ts': ts});
            if ((_sheetOpsById[id]?.length ?? 0) > 200) {
              _sheetOpsById[id] = _sheetOpsById[id]!.sublist(
                _sheetOpsById[id]!.length - 200,
              );
            }
          }

          setState(() {
            _status = 'Sheet ops: +${ops.length}';
            _ensureSelectedSheet();
          });
          return;

        case 'cell_change':
          final changeRaw = obj['change'];
          if (changeRaw is! Map) return;
          final change = changeRaw.cast<String, dynamic>();

          _upsertSheetMetaFromChange(change);
          final key = _makeKey(change);
          _changes[key] = change;

          setState(() {
            _status =
                'Changed cells: ${_changes.length} (last: ${change['a1']}@${change['sheetName']})';
            _ensureSelectedSheet();
            _selectedSheetId ??= _sheetKeyFromMap(change);
            _selectedChangeKey ??= key;
          });
          return;

        case 'export_changes':
          final listRaw = obj['changes'];
          final list = (listRaw is List) ? listRaw : <dynamic>[];

          for (final item in list) {
            if (item is! Map) continue;
            final change = item.cast<String, dynamic>();
            _upsertSheetMetaFromChange(change);
            _changes[_makeKey(change)] = change;
          }

          setState(() {
            _status = 'Export changes OK. total=${_changes.length}';
            _ensureSelectedSheet();
          });
          return;

        case 'changes_cleared':
          setState(() {
            _changes.clear();
            _sheetOpsById.clear();
            _sheetMetaById.clear();
            _selectedSheetId = null;
            _selectedChangeKey = null;
            _reviewedKeys.clear();
            _status = 'Changes cleared.';
          });
          return;

        case 'warn':
          setState(() => _status = 'WARN: ${obj['message']}');
          return;

        default:
          setState(() => _status = 'Message: $message');
          return;
      }
    } catch (e) {
      setState(() => _status = 'Bad message: $message\n$e');
    }
  }

  // ---------------- actions ----------------
  Future<void> _pickAndImportXlsx() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final f = result.files.single;
    final bytes = f.bytes ?? await File(f.path!).readAsBytes();

    final b64 = base64Encode(bytes);
    final name = f.name;

    setState(() => _status = 'Importing $name ...');

    final js =
        'window.importXlsxBase64(${jsonEncode(b64)}, ${jsonEncode(name)});';
    await _controller.runJavaScript(js);
  }

  Future<void> _requestExportChanges() async {
    if (!_webReady) {
      setState(() => _status = 'Web not ready yet.');
      return;
    }
    await _controller.runJavaScript(
      'window.exportChangesToFlutter && window.exportChangesToFlutter();',
    );
  }

  Future<void> _requestClearChanges() async {
    if (!_webReady) return;
    await _controller.runJavaScript(
      'window.clearChanges && window.clearChanges();',
    );
  }

  Future<void> _saveDraftChangesJson() async {
    if (_changes.isEmpty && _sheetOpsById.isEmpty) {
      setState(() => _status = 'No changes to save.');
      return;
    }

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save draft changes JSON',
      fileName: 'draft_changes.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (savePath == null) return;

    final outFile = File(
      savePath.endsWith('.json') ? savePath : '$savePath.json',
    );

    final payload = {
      "docId": "demo-doc",
      "userId": "demo-user",
      "clientTs": DateTime.now().millisecondsSinceEpoch,
      "sheetMeta": _sheetMetaById,
      "sheetOps": _sheetOpsById,
      "cellChanges": _changes.values.toList(),
    };

    final pretty = const JsonEncoder.withIndent('  ').convert(payload);
    await outFile.writeAsString(pretty, flush: true);

    setState(() => _status = 'Saved draft JSON: ${p.basename(outFile.path)}');
  }

  Future<void> _goToCell(Map<String, dynamic> ch) async {
    final r = _toInt(ch['r']);
    final c = _toInt(ch['c']);

    // Thử ưu tiên sheetIndex/sheetId/order để activate sheet
    final sheetIndex = _toStr(
      ch['sheetIndex'],
      fallback: _toStr(ch['sheetId']),
    );
    final order = ch['sheetOrder'];

    final js =
        '''
(function(){
  try{
    if(!window.luckysheet) return;

    // activate sheet (tùy version luckysheet, có thể nhận index string hoặc order)
    try { if(luckysheet.setSheetActive && ${jsonEncode(sheetIndex)}){
      luckysheet.setSheetActive(${jsonEncode(sheetIndex)});
    }} catch(e){}

    try { if(luckysheet.setSheetActive && ${jsonEncode(order)}!=null){
      luckysheet.setSheetActive(${jsonEncode(order)});
    }} catch(e){}

    // show selection + scroll
    try { if(luckysheet.setRangeShow){
      luckysheet.setRangeShow({row:[${r},${r}],column:[${c},${c}]});
    }} catch(e){}

    try { if(luckysheet.scrollToCell){
      luckysheet.scrollToCell(${r},${c});
    }} catch(e){}
  }catch(e){}
})();
''';
    await _controller.runJavaScript(js);
  }

  // ---------------- UI derived ----------------
  List<_SheetRow> _buildSheetRows() {
    final ids = _allSheetIds();
    final rows = <_SheetRow>[];

    for (final id in ids) {
      final name = _toStr(_sheetMetaById[id]?['name'], fallback: id);
      final ops = _sheetOpsById[id]?.length ?? 0;

      final changes = _changes.values
          .where((c) => _sheetKeyFromMap(c) == id)
          .toList();

      final cellCount = changes.length;
      final lastTs = changes.isEmpty
          ? 0
          : changes
                .map((e) => _toInt(e['lastTs']))
                .reduce((a, b) => a > b ? a : b);

      rows.add(
        _SheetRow(
          id: id,
          name: name,
          ops: ops,
          cells: cellCount,
          lastTs: lastTs,
        ),
      );
    }
    return rows;
  }

  List<_ChangeRow> _buildFeed(String sheetId) {
    final list = <_ChangeRow>[];

    for (final entry in _changes.entries) {
      final key = entry.key;
      final ch = entry.value;
      if (_sheetKeyFromMap(ch) != sheetId) continue;

      final a1 = _toStr(ch['a1']);
      final lastTs = _toInt(ch['lastTs']);
      final oldObj = (ch['old'] as Map?)?.cast<String, dynamic>() ?? {};
      final newObj = (ch['new'] as Map?)?.cast<String, dynamic>() ?? {};

      final oldStyle = _styleOf(oldObj);
      final newStyle = _styleOf(newObj);

      final hasValue = _hasValueChange(oldObj, newObj);
      final hasFormula = _hasFormulaChange(oldObj, newObj);
      final hasStyle = _hasStyleChange(oldStyle, newStyle);

      // filter
      final ok = switch (_filter) {
        ChangeFilter.all => true,
        ChangeFilter.value => hasValue,
        ChangeFilter.formula => hasFormula,
        ChangeFilter.style => hasStyle,
      };
      if (!ok) continue;

      // search
      if (_search.trim().isNotEmpty) {
        final q = _search.trim().toLowerCase();
        final text = [
          a1,
          _displayValueOrFormula(oldObj),
          _displayValueOrFormula(newObj),
        ].join(' ').toLowerCase();

        if (!text.contains(q)) continue;
      }

      list.add(
        _ChangeRow(
          key: key,
          a1: a1.isEmpty ? '(cell)' : a1,
          lastTs: lastTs,
          oldText: _displayValueOrFormula(oldObj),
          newText: _displayValueOrFormula(newObj),
          tags: _buildTags(
            hasValue: hasValue,
            hasFormula: hasFormula,
            hasStyle: hasStyle,
          ),
          reviewed: _reviewedKeys.contains(key),
        ),
      );
    }

    // newest first
    list.sort((a, b) => b.lastTs.compareTo(a.lastTs));
    return list;
  }

  List<String> _buildTags({
    required bool hasValue,
    required bool hasFormula,
    required bool hasStyle,
  }) {
    final tags = <String>[];
    if (hasValue) tags.add('Value');
    if (hasFormula) tags.add('Formula');
    if (hasStyle) tags.add('Style');
    if (tags.isEmpty) tags.add('Other');
    return tags;
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final sheetRows = _buildSheetRows();
    _ensureSelectedSheet();

    final sheetId = _selectedSheetId;
    final feed = (sheetId == null) ? <_ChangeRow>[] : _buildFeed(sheetId);
    _ensureSelectedChange(feed);

    final selectedKey = _selectedChangeKey;
    final selectedChange = (selectedKey != null) ? _changes[selectedKey] : null;

    final totalChanges = _changes.length;
    final totalStyle = _changes.values.where((ch) {
      final oldObj = (ch['old'] as Map?)?.cast<String, dynamic>() ?? {};
      final newObj = (ch['new'] as Map?)?.cast<String, dynamic>() ?? {};
      return _hasStyleChange(_styleOf(oldObj), _styleOf(newObj));
    }).length;

    final totalFormula = _changes.values.where((ch) {
      final oldObj = (ch['old'] as Map?)?.cast<String, dynamic>() ?? {};
      final newObj = (ch['new'] as Map?)?.cast<String, dynamic>() ?? {};
      return _hasFormulaChange(oldObj, newObj);
    }).length;

    final lastEdit = _changes.isEmpty
        ? 0
        : _changes.values
              .map((e) => _toInt(e['lastTs']))
              .reduce((a, b) => a > b ? a : b);

    return Scaffold(
      appBar: AppBar(
        title: const Text('POC: Luckysheet in WebView'),
        actions: [
          IconButton(
            tooltip: 'Open .xlsx',
            onPressed: _pickAndImportXlsx,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: 'Get changes (from JS buffer)',
            onPressed: _requestExportChanges,
            icon: const Icon(Icons.list_alt),
          ),
          IconButton(
            tooltip: 'Clear changes',
            onPressed: _requestClearChanges,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Save Draft JSON',
            onPressed: _saveDraftChangesJson,
            icon: const Icon(Icons.download),
          ),
          const VerticalDivider(),
          IconButton(
            tooltip: _isTrackerVisible
                ? 'Hide Change Tracker'
                : 'Show Change Tracker',
            onPressed: () =>
                setState(() => _isTrackerVisible = !_isTrackerVisible),
            icon: Icon(
              _isTrackerVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // top status strip
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: Colors.black12,
            child: Text(_status),
          ),
          const Divider(height: 1),

          Expanded(
            child: Row(
              children: [
                // ---- WebView (left) ----
                Expanded(
                  flex: _isTrackerVisible ? 3 : 1,
                  child: WebViewWidget(controller: _controller),
                ),
                if (_isTrackerVisible) const VerticalDivider(width: 1),

                // ---- Change Tracker Panel (right) ----
                if (_isTrackerVisible)
                  Expanded(
                    flex: 2,
                    child: Container(
                      color: const Color(0xFFF7F7FB),
                      child: Column(
                        children: [
                          _TrackerTopBar(
                            totalChanges: totalChanges,
                            totalStyle: totalStyle,
                            totalFormula: totalFormula,
                            lastEdit: _fmtTs(lastEdit),
                            filter: _filter,
                            onFilterChanged: (f) => setState(() {
                              _filter = f;
                              _selectedChangeKey = null;
                            }),
                            search: _search,
                            onSearchChanged: (s) => setState(() {
                              _search = s;
                              _selectedChangeKey = null;
                            }),
                            onExport: _requestExportChanges,
                          ),
                          const Divider(height: 1),

                          Expanded(
                            child: Row(
                              children: [
                                // 1) Sheets
                                Expanded(
                                  flex: 3,
                                  child: _SheetsPanel(
                                    sheets: sheetRows,
                                    selectedId: _selectedSheetId,
                                    fmtTs: _fmtTs,
                                    onSelect: (id) => setState(() {
                                      _selectedSheetId = id;
                                      _selectedChangeKey = null;
                                    }),
                                  ),
                                ),
                                const VerticalDivider(width: 1),

                                // 2) Change feed
                                Expanded(
                                  flex: 5,
                                  child: _FeedPanel(
                                    feed: feed,
                                    selectedKey: _selectedChangeKey,
                                    fmtTs: _fmtTs,
                                    onSelect: (key) => setState(
                                      () => _selectedChangeKey = key,
                                    ),
                                  ),
                                ),
                                const VerticalDivider(width: 1),

                                // 3) Details
                                Expanded(
                                  flex: 4,
                                  child: _DetailsPanel(
                                    change: selectedChange,
                                    fmtTs: _fmtTs,
                                    displayValueOrFormula:
                                        _displayValueOrFormula,
                                    styleOf: _styleOf,
                                    hasStyleChange: _hasStyleChange,
                                    reviewed:
                                        selectedKey != null &&
                                        _reviewedKeys.contains(selectedKey),
                                    onGoToCell: selectedChange == null
                                        ? null
                                        : () => _goToCell(selectedChange),
                                    onCopyDiff: selectedChange == null
                                        ? null
                                        : () async {
                                            final sheetName = _toStr(
                                              selectedChange['sheetName'],
                                              fallback: 'Sheet',
                                            );
                                            final a1 = _toStr(
                                              selectedChange['a1'],
                                              fallback: '(cell)',
                                            );
                                            final oldObj =
                                                (selectedChange['old'] as Map?)
                                                    ?.cast<String, dynamic>() ??
                                                {};
                                            final newObj =
                                                (selectedChange['new'] as Map?)
                                                    ?.cast<String, dynamic>() ??
                                                {};
                                            final text =
                                                '$sheetName!$a1\nOLD: ${_displayValueOrFormula(oldObj)}\nNEW: ${_displayValueOrFormula(newObj)}';
                                            await Clipboard.setData(
                                              ClipboardData(text: text),
                                            );
                                            if (mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Copied diff to clipboard',
                                                  ),
                                                ),
                                              );
                                            }
                                          },
                                    onToggleReviewed: selectedKey == null
                                        ? null
                                        : () => setState(() {
                                            if (_reviewedKeys.contains(
                                              selectedKey,
                                            )) {
                                              _reviewedKeys.remove(selectedKey);
                                            } else {
                                              _reviewedKeys.add(selectedKey);
                                            }
                                          }),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== UI WIDGETS =====================

class _TrackerTopBar extends StatelessWidget {
  final int totalChanges;
  final int totalStyle;
  final int totalFormula;
  final String lastEdit;

  final ChangeFilter filter;
  final ValueChanged<ChangeFilter> onFilterChanged;

  final String search;
  final ValueChanged<String> onSearchChanged;

  final VoidCallback onExport;

  const _TrackerTopBar({
    required this.totalChanges,
    required this.totalStyle,
    required this.totalFormula,
    required this.lastEdit,
    required this.filter,
    required this.onFilterChanged,
    required this.search,
    required this.onSearchChanged,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(String text, ChangeFilter v) {
      final selected = filter == v;
      return ChoiceChip(
        label: Text(text),
        selected: selected,
        onSelected: (_) => onFilterChanged(v),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'Changes',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$lastEdit',
                  style: const TextStyle(color: Colors.black54, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: onExport,
                icon: const Icon(Icons.file_upload_outlined, size: 18),
                tooltip: 'Export',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _pill('Changed', '$totalChanges'),
                const SizedBox(width: 8),
                _pill('Style', '$totalStyle'),
                const SizedBox(width: 8),
                _pill('Formula', '$totalFormula'),
                const SizedBox(width: 12),
                chip('All', ChangeFilter.all),
                const SizedBox(width: 8),
                chip('Value', ChangeFilter.value),
                const SizedBox(width: 8),
                chip('Formula', ChangeFilter.formula),
                const SizedBox(width: 8),
                chip('Style', ChangeFilter.style),
                const SizedBox(width: 12),
                SizedBox(
                  width: 240,
                  height: 40,
                  child: TextField(
                    controller: TextEditingController(text: search)
                      ..selection = TextSelection.fromPosition(
                        TextPosition(offset: search.length),
                      ),
                    onChanged: onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search "A1" / value...',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _pill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 12)),
    );
  }
}

class _SheetsPanel extends StatelessWidget {
  final List<_SheetRow> sheets;
  final String? selectedId;
  final String Function(int? ms) fmtTs;
  final ValueChanged<String> onSelect;

  const _SheetsPanel({
    required this.sheets,
    required this.selectedId,
    required this.fmtTs,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Sheets',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: sheets.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = sheets[i];
              final selected = s.id == selectedId;

              return InkWell(
                onTap: () => onSelect(s.id),
                child: Container(
                  color: selected ? Colors.blue.withOpacity(0.10) : null,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.blue : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${s.cells} cells',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FeedPanel extends StatelessWidget {
  final List<_ChangeRow> feed;
  final String? selectedKey;
  final String Function(int? ms) fmtTs;
  final ValueChanged<String> onSelect;

  const _FeedPanel({
    required this.feed,
    required this.selectedKey,
    required this.fmtTs,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (feed.isEmpty) {
      return const Center(
        child: Text(
          'No changes.\nEdit value / formula / style to see feed.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      children: [
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                'Change Feed',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: feed.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = feed[i];
              final selected = it.key == selectedKey;

              return InkWell(
                onTap: () => onSelect(it.key),
                child: Container(
                  color: selected ? Colors.amber.withOpacity(0.15) : null,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _tagIcon(it.tags),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  it.a1,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  fmtTs(it.lastTs),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                const Spacer(),
                                if (it.reviewed)
                                  const Icon(
                                    Icons.check_circle,
                                    size: 16,
                                    color: Colors.green,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${it.oldText}  →  ${it.newText}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: it.tags
                                  .map((t) => _miniTag(t))
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static Widget _miniTag(String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(t, style: const TextStyle(fontSize: 11)),
    );
  }

  static Widget _tagIcon(List<String> tags) {
    final hasStyle = tags.contains('Style');
    final hasFormula = tags.contains('Formula');
    final hasValue = tags.contains('Value');

    IconData icon = Icons.edit_note;
    Color color = Colors.blueGrey;

    if (hasStyle) {
      icon = Icons.format_paint_outlined;
      color = Colors.indigo;
    } else if (hasFormula) {
      icon = Icons.functions;
      color = Colors.deepPurple;
    } else if (hasValue) {
      icon = Icons.edit_outlined;
      color = Colors.blue;
    }

    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  final Map<String, dynamic>? change;

  final String Function(int? ms) fmtTs;
  final String Function(Map<String, dynamic> cellObj) displayValueOrFormula;
  final Map<String, dynamic> Function(Map<String, dynamic> cellObj) styleOf;
  final bool Function(Map<String, dynamic>, Map<String, dynamic>)
  hasStyleChange;

  final bool reviewed;
  final VoidCallback? onGoToCell;
  final VoidCallback? onCopyDiff;
  final VoidCallback? onToggleReviewed;

  const _DetailsPanel({
    required this.change,
    required this.fmtTs,
    required this.displayValueOrFormula,
    required this.styleOf,
    required this.hasStyleChange,
    required this.reviewed,
    required this.onGoToCell,
    required this.onCopyDiff,
    required this.onToggleReviewed,
  });

  @override
  Widget build(BuildContext context) {
    if (change == null) {
      return const Center(child: Text('Select a change to view details.'));
    }

    final ch = change!;
    final sheetName = (ch['sheetName'] ?? 'Sheet').toString();
    final a1 = (ch['a1'] ?? '(cell)').toString();
    final lastTs = ch['lastTs'] as int?;

    final oldObj = (ch['old'] as Map?)?.cast<String, dynamic>() ?? {};
    final newObj = (ch['new'] as Map?)?.cast<String, dynamic>() ?? {};

    final oldStyle = styleOf(oldObj);
    final newStyle = styleOf(newObj);
    final styleChanged = hasStyleChange(oldStyle, newStyle);

    final oldText = displayValueOrFormula(oldObj);
    final newText = displayValueOrFormula(newObj);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Change Details',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$sheetName › $a1',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                fmtTs(lastTs),
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 12),

          const Text('Value', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          _kv('OLD', oldText),
          const SizedBox(height: 8),
          _kvHighlight('NEW', newText),

          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 10),

          Text(
            'STYLE CHANGES:',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: Colors.blue.shade700,
            ),
          ),
          const SizedBox(height: 6),
          if (!styleChanged)
            const Text(
              'No style changes',
              style: TextStyle(color: Colors.black54),
            )
          else ...[
            _small('Old: ${_formatStyle(oldStyle)}'),
            const SizedBox(height: 4),
            _small('New: ${_formatStyle(newStyle)}'),
          ],

          const Spacer(),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onGoToCell,
              icon: const Icon(Icons.navigation_outlined),
              label: const Text('Go to cell'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onCopyDiff,
              icon: const Icon(Icons.copy),
              label: const Text('Copy diff'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onToggleReviewed,
              icon: Icon(
                reviewed ? Icons.check_circle : Icons.check_circle_outline,
              ),
              label: Text(reviewed ? 'Reviewed' : 'Mark reviewed'),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _kv(String k, String v) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$k: $v', style: const TextStyle(fontSize: 13)),
    );
  }

  static Widget _kvHighlight(String k, String v) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$k: $v',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }

  static Widget _small(String t) =>
      Text(t, style: const TextStyle(fontSize: 12));

  static String _formatStyle(Map<String, dynamic> style) {
    if (style.isEmpty) return '(no style)';
    final parts = <String>[];
    void add(String k, String label) {
      if (style[k] != null) parts.add('$label=${style[k]}');
    }

    add('bg', 'bg');
    add('fc', 'fc');
    add('ff', 'font');
    add('fs', 'size');
    if (style['bl'] == 1 || style['bl'] == true) parts.add('bold');
    if (style['it'] == 1 || style['it'] == true) parts.add('italic');
    if (style['ul'] == 1 || style['ul'] == true) parts.add('underline');
    add('ht', 'align');
    add('vt', 'valign');

    return parts.isEmpty ? '(no style)' : parts.join(', ');
  }
}

// ===================== data rows =====================

class _SheetRow {
  final String id;
  final String name;
  final int ops;
  final int cells;
  final int lastTs;

  _SheetRow({
    required this.id,
    required this.name,
    required this.ops,
    required this.cells,
    required this.lastTs,
  });
}

class _ChangeRow {
  final String key;
  final String a1;
  final int lastTs;
  final String oldText;
  final String newText;
  final List<String> tags;
  final bool reviewed;

  _ChangeRow({
    required this.key,
    required this.a1,
    required this.lastTs,
    required this.oldText,
    required this.newText,
    required this.tags,
    required this.reviewed,
  });
}
