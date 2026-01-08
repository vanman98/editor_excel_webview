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

  /// key: sheet#r#c
  final Map<String, Map<String, dynamic>> _changes = {};
  Map<String, List<Map<String, dynamic>>> _groupChangesBySheet() {
    final map = <String, List<Map<String, dynamic>>>{};

    for (final ch in _changes.values) {
      final sheet = (ch['sheetName'] ?? 'Unknown').toString();
      (map[sheet] ??= []).add(ch);
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
    // hiển thị đơn giản cho tester
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  String _displayValueOrFormula(Map<String, dynamic> cellObj) {
    // ưu tiên formula nếu có
    final f = cellObj['formula'];
    if (f != null && f.toString().trim().isNotEmpty) return f.toString();
    final v = cellObj['value'];
    if (v == null) return '(empty)';
    final s = v.toString();
    return s.isEmpty ? '(empty)' : s;
  }

  String _makeKey(Map<String, dynamic> change) {
    final sheet = (change['sheetName'] ?? '').toString();
    final r = change['r'];
    final c = change['c'];
    return '$sheet#$r#$c';
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

            // ✅ luôn cho phép local
            final isLocal =
                url.startsWith('flutter-asset://') ||
                url.startsWith('file://') ||
                url.startsWith('about:blank');

            if (isLocal) return NavigationDecision.navigate;

            // DEV: tạm cho CDN để bạn test nhanh
            if (!kReleaseMode) {
              final allowDevCdn = url.startsWith('https://cdn.jsdelivr.net');
              return allowDevCdn
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            }

            // PROD: chặn hết ngoài local
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

        // Realtime single-cell update
        case 'cell_change':
          final change = (obj['change'] as Map).cast<String, dynamic>();
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
            _changes[_makeKey(change)] = change;
          }
          setState(
            () => _status = 'Export changes OK. total=${_changes.length}',
          );
          return;

        case 'changes_cleared':
          setState(() {
            _changes.clear();
            _status = 'Changes cleared.';
          });
          return;

        // Existing export xlsx (optional)
        case 'export_xlsx':
          final b64 = (obj['b64'] ?? '') as String;
          final fileName = (obj['fileName'] ?? 'edited.xlsx') as String;

          if (b64.isEmpty) {
            setState(() => _status = 'Export XLSX ERROR: empty base64');
            return;
          }

          setState(() => _status = 'Exported XLSX from Web. Saving...');
          _saveB64AsXlsx(b64, fileName);
          return;

        case 'export_err':
          setState(() => _status = 'Export ERROR: ${obj['err']}');
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

  Future<void> _requestExportAndSaveXlsx() async {
    if (!_webReady) {
      setState(() => _status = 'Web not ready yet.');
      return;
    }
    setState(() => _status = 'Exporting XLSX from web...');
    await _controller.runJavaScript('exportXlsxToFlutter();');
  }

  Future<void> _saveDraftChangesJson() async {
    if (_changes.isEmpty) {
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
      "docId": "demo-doc", // sau này BE cấp
      "userId": "demo-user", // sau này auth cấp
      "clientTs": DateTime.now().millisecondsSinceEpoch,
      "changes": _changes.values.toList(),
    };

    final pretty = const JsonEncoder.withIndent('  ').convert(payload);
    await outFile.writeAsString(pretty, flush: true);

    setState(() => _status = 'Saved draft JSON: ${p.basename(outFile.path)}');
  }

  Future<void> _saveB64AsXlsx(String b64, String suggestedName) async {
    final bytes = base64Decode(b64);

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save As .xlsx',
      fileName: suggestedName.endsWith('.xlsx')
          ? suggestedName
          : '$suggestedName.xlsx',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (savePath == null) {
      setState(() => _status = 'Save cancelled.');
      return;
    }

    final outFile = File(
      savePath.endsWith('.xlsx') ? savePath : '$savePath.xlsx',
    );
    await outFile.writeAsBytes(bytes, flush: true);

    setState(() => _status = 'Saved: ${p.basename(outFile.path)}');
  }

  @override
  Widget build(BuildContext context) {
    final changesList = _changes.values.toList()
      ..sort(
        (a, b) =>
            ((b['lastTs'] ?? 0) as int).compareTo((a['lastTs'] ?? 0) as int),
      );
    final grouped = _groupChangesBySheet();
    final sheetNames = grouped.keys.toList()..sort();
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
            child: Text('Status: $_status | changes=${_changes.length}'),
          ),
          const Divider(height: 1),

          // Viewer: show changes collected by Flutter
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
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: _changes.isEmpty
                        ? const Center(
                            child: Text(
                              'No changes yet.\nEdit some cells to see logs.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Header summary
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.black12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Sheets changed: ${sheetNames.length}\nTotal changed cells: ${_changes.length}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Sheet sections
                              Expanded(
                                child: ListView.separated(
                                  itemCount: sheetNames.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (context, idx) {
                                    final sheet = sheetNames[idx];
                                    final items = grouped[sheet] ?? const [];

                                    return SheetChangesCard(
                                      sheetName: sheet,
                                      items: items,
                                      fmtTs: _fmtTs,
                                      displayValueOrFormula:
                                          _displayValueOrFormula,
                                    );
                                  },
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
