import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
            tooltip: 'Export & Save .xlsx (data-only)',
            onPressed: _requestExportAndSaveXlsx,
            icon: const Icon(Icons.save_as),
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
                    child: changesList.isEmpty
                        ? const Center(
                            child: Text(
                              'No changes yet.\nEdit some cells to see logs.',
                            ),
                          )
                        : ListView.separated(
                            itemCount: changesList.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final ch = changesList[i];
                              final sheet = (ch['sheetName'] ?? '').toString();
                              final a1 = (ch['a1'] ?? '').toString();
                              final oldObj =
                                  (ch['old'] as Map?)
                                      ?.cast<String, dynamic>() ??
                                  {};
                              final newObj =
                                  (ch['new'] as Map?)
                                      ?.cast<String, dynamic>() ??
                                  {};
                              final oldV = oldObj['value'];
                              final newV = newObj['value'];
                              final oldF = oldObj['formula'];
                              final newF = newObj['formula'];
                              final count = ch['count'];

                              return ListTile(
                                dense: true,
                                title: Text('$sheet · $a1  (x$count)'),
                                subtitle: Text(
                                  'old: ${oldF ?? oldV}\nnew: ${newF ?? newV}',
                                ),
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
