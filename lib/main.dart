import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const MaterialApp(home: LuckysheetPocPage()));
}

class LuckysheetPocPage extends StatefulWidget {
  const LuckysheetPocPage({super.key});

  @override
  State<LuckysheetPocPage> createState() => _LuckysheetPocPageState();
}

class _LuckysheetPocPageState extends State<LuckysheetPocPage> {
  late final WebViewController _controller;

  String _status = 'Ready';
  String? _lastPickedName;
  Map<String, dynamic>? _lastExport;

  bool _pageReady = false;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageReady = true;
            setState(() => _status = 'Web page loaded.');
          },
          onWebResourceError: (e) {
            setState(() => _status = 'Web error: ${e.description}');
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (msg) {
          try {
            final obj = jsonDecode(msg.message) as Map<String, dynamic>;
            final type = obj['type'];

            switch (type) {
              case 'page_loaded':
                setState(() {
                  _status =
                      'Page loaded. luckysheet=${obj['luckysheet']} luckyexcel=${obj['luckyexcel']}';
                });
                return;

              case 'page_err':
                setState(() => _status = 'Page ERROR: ${obj['err']}');
                return;

              case 'import_ok':
                setState(
                  () => _status = 'Import OK. sheets=${obj['sheetCount']}',
                );
                return;

              case 'import_err':
                setState(() => _status = 'Import ERROR: ${obj['err']}');
                return;

              case 'export_json':
                setState(() {
                  _lastExport = obj;
                  _status = 'Export JSON OK (saved in memory).';
                });
                return;

              case 'export_err':
                setState(() => _status = 'Export ERROR: ${obj['err']}');
                return;

              default:
                setState(() => _status = 'Message: ${msg.message}');
                return;
            }
          } catch (e) {
            setState(() => _status = 'Bad message: ${msg.message}\n$e');
          }
        },
      );

    // ✅ Workaround macOS: load HTML via string (not loadFlutterAsset)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final html = await rootBundle.loadString('assets/web/index.html');
      await _controller.loadHtmlString(html, baseUrl: 'https://local.app/');
    });
  }

  Future<void> _pickAndImportXlsx() async {
    if (!_pageReady) {
      setState(() => _status = 'Web chưa load xong, đợi 1-2s rồi thử lại.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final f = result.files.single;
    final bytes = f.bytes ?? await File(f.path!).readAsBytes();

    final name = f.name;
    final b64 = base64Encode(bytes);

    setState(() {
      _lastPickedName = name;
      _status =
          'Importing $name ... (${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB)';
    });

    try {
      await _sendBase64InChunks(b64, name);
    } catch (e) {
      setState(() => _status = 'Send chunks error: $e');
    }
  }

  Future<void> _sendBase64InChunks(String b64, String name) async {
    const chunkSize = 200000; // 200k chars / chunk

    for (int i = 0; i < b64.length; i += chunkSize) {
      final end = (i + chunkSize < b64.length) ? i + chunkSize : b64.length;
      final chunk = b64.substring(i, end);
      final isLast = end == b64.length;

      final js =
          "window.pushB64Chunk(${jsonEncode(chunk)}, ${isLast ? 'true' : 'false'}, ${jsonEncode(name)});";

      await _controller.runJavaScript(js);
    }
  }

  Future<void> _saveExportJsonToFile() async {
    if (_lastExport == null) {
      _snack('Chưa có export JSON. Bấm Export JSON trong web trước.');
      return;
    }

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save exported JSON',
      fileName: 'luckysheet_export.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (savePath == null) return;

    final out = File(savePath.endsWith('.json') ? savePath : '$savePath.json');
    final pretty = const JsonEncoder.withIndent('  ').convert(_lastExport);
    await out.writeAsString(pretty, flush: true);

    _snack('Saved: ${p.basename(out.path)}');
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
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
            tooltip: 'Save exported JSON',
            onPressed: _saveExportJsonToFile,
            icon: const Icon(Icons.save),
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
              'Status: $_status'
              '${_lastPickedName != null ? ' | File: $_lastPickedName' : ''}',
            ),
          ),
          const Divider(height: 1),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
