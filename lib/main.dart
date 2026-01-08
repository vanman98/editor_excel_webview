import 'dart:convert';
import 'dart:io';

import 'package:editor_excel_webview/sheet_card.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/foundation.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LuckysheetPocPage(),
    ),
  );
}

class LuckysheetPocPage extends StatefulWidget {
  const LuckysheetPocPage({super.key});

  @override
  State<LuckysheetPocPage> createState() => _LuckysheetPocPageState();
}

class _LuckysheetPocPageState extends State<LuckysheetPocPage> {
  late final WebViewController _controller;

  String _status = 'Ready';
  bool _webReady = false;

  /// key: sheetId#r#c
  final Map<String, Map<String, dynamic>> _changes = {};

  /// sheetId -> {id,name,order}
  final Map<String, Map<String, dynamic>> _sheetMetaById = {};

  /// sheetId -> list of ops
  final Map<String, List<Map<String, dynamic>>> _sheetOpsById = {};

  String _makeKey(Map<String, dynamic> change) {
    final sheetId = (change['sheetId'] ?? change['sheetName'] ?? '').toString();
    final r = change['r'];
    final c = change['c'];
    return '$sheetId#$r#$c';
  }

  void _upsertSheetMetaFromChange(Map<String, dynamic> ch) {
    final id = (ch['sheetId'] ?? ch['sheetName'] ?? '').toString();
    if (id.isEmpty) return;
    _sheetMetaById[id] = {
      "id": id,
      "name": (ch['sheetName'] ?? _sheetMetaById[id]?['name'] ?? 'Sheet')
          .toString(),
      "order": (ch['sheetOrder'] ?? _sheetMetaById[id]?['order'] ?? 0),
    };
  }

  void _upsertSheetMetaFromSheetsList(List<dynamic> sheets) {
    for (final s in sheets) {
      final m = (s as Map).cast<String, dynamic>();
      final id = (m['id'] ?? m['index'] ?? m['name'] ?? '').toString();
      if (id.isEmpty) continue;
      _sheetMetaById[id] = {
        "id": id,
        "name": (m['name'] ?? 'Sheet').toString(),
        "order": (m['order'] ?? 0),
      };
    }
  }

  Map<String, List<Map<String, dynamic>>> _groupChangesBySheetId() {
    final map = <String, List<Map<String, dynamic>>>{};

    for (final ch in _changes.values) {
      final sheetId = (ch['sheetId'] ?? ch['sheetName'] ?? 'Unknown')
          .toString();
      (map[sheetId] ??= []).add(ch);
    }

    // Sort cells inside each sheet: latest first
    for (final entry in map.entries) {
      entry.value.sort((a, b) {
        final bt = (b['lastTs'] ?? 0) as int;
        final at = (a['lastTs'] ?? 0) as int;
        return bt.compareTo(at);
      });
    }

    return map;
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
          setState(() => _status = 'Import OK. sheets=${obj['sheetCount']}');
          return;

        case 'import_err':
          setState(() => _status = 'Import ERROR: ${obj['err']}');
          return;

        case 'sheet_activate':
          setState(() => _status = 'Active sheet: ${obj['sheet']}');
          return;

        // ✅ NEW: sheet ops watcher (add/rename/delete/reorder)
        case 'sheet_ops':
          final ops = (obj['ops'] as List? ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();

          final sheets = (obj['sheets'] as List? ?? const []);
          _upsertSheetMetaFromSheetsList(sheets);

          for (final op in ops) {
            final sheet = (op['sheet'] as Map?)?.cast<String, dynamic>() ?? {};
            final id = (sheet['id'] ?? sheet['index'] ?? sheet['name'] ?? '0')
                .toString();

            (_sheetOpsById[id] ??= []).add({
              ...op,
              "ts": obj["ts"] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }

          setState(() {
            _status = 'Sheet ops: +${ops.length}';
          });
          return;

        // ✅ realtime single-cell update (includes style)
        case 'cell_change':
          final change = (obj['change'] as Map).cast<String, dynamic>();
          _upsertSheetMetaFromChange(change);

          final key = _makeKey(change);
          _changes[key] = change;

          setState(() {
            _status =
                'Changed cells: ${_changes.length} (last: ${change['a1']}@${change['sheetName']})';
          });
          return;

        // Bulk export from JS buffer
        case 'export_changes':
          final list = (obj['changes'] as List).cast<dynamic>();
          for (final item in list) {
            final change = (item as Map).cast<String, dynamic>();
            _upsertSheetMetaFromChange(change);
            _changes[_makeKey(change)] = change;
          }
          setState(
            () => _status = 'Export changes OK. total=${_changes.length}',
          );
          return;

        case 'changes_cleared':
          setState(() {
            _changes.clear();
            _sheetOpsById.clear();
            _status = 'Changes cleared.';
          });
          return;

        default:
          setState(() => _status = 'Message: $message');
          return;
      }
    } catch (e) {
      setState(() => _status = 'Bad message: $message\n$e');
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final grouped = _groupChangesBySheetId();

    final allSheetIds = <String>{
      ...grouped.keys,
      ..._sheetOpsById.keys,
    }.toList();

    // Sort by order then name
    allSheetIds.sort((a, b) {
      final ao = (_sheetMetaById[a]?['order'] ?? 0) as num;
      final bo = (_sheetMetaById[b]?['order'] ?? 0) as num;
      final od = ao.compareTo(bo);
      if (od != 0) return od;
      final an = (_sheetMetaById[a]?['name'] ?? a).toString();
      final bn = (_sheetMetaById[b]?['name'] ?? b).toString();
      return an.compareTo(bn);
    });

    final totalOps = _sheetOpsById.values.fold<int>(
      0,
      (sum, list) => sum + list.length,
    );

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
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: Colors.black12,
            child: Text(
              'Status: $_status | sheets=${allSheetIds.length} | '
              'cellChanges=${_changes.length} | sheetOps=$totalOps',
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: WebViewWidget(controller: _controller),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: allSheetIds.isEmpty
                        ? const Center(
                            child: Text(
                              'No changes yet.\nEdit cells / change style / add sheet to see logs.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.separated(
                            itemCount: allSheetIds.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, idx) {
                              final sheetId = allSheetIds[idx];
                              final sheetName =
                                  (_sheetMetaById[sheetId]?['name'] ?? 'Sheet')
                                      .toString();
                              final items = grouped[sheetId] ?? const [];
                              final ops = _sheetOpsById[sheetId] ?? const [];

                              return SheetChangesCard(
                                sheetId: sheetId,
                                sheetName: sheetName,
                                items: items,
                                sheetOps: ops,
                                fmtTs: _fmtTs,
                                displayValueOrFormula: _displayValueOrFormula,
                              );
                            },
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
