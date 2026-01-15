import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Required for MethodChannel
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// PDF Rendering for UI Preview only
import 'package:printing/printing.dart';

import '../services/printer_service.dart'; // Kept for Android compatibility if needed, or removing dependency if pure iOS
import '../services/language_service.dart';

class PdfViewerPage extends StatefulWidget {
  final String filePath;
  final PrinterService printerService; // We might keep this for queue counts or Android fallback
  final String? connectedMac;
  final bool autoPrint;

  const PdfViewerPage({
    Key? key,
    required this.filePath,
    required this.printerService,
    this.connectedMac,
    this.autoPrint = false,
  }) : super(key: key);

  @override
  _PdfViewerPageState createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  // Method Channel to talk to Swift
  static const platform = MethodChannel('com.example.epos/printer_sync');

  // State for UI Preview
  List<Uint8List> _previewBytes = []; 
  bool _isLoadingDoc = true;
  String _errorMessage = '';

  // State for Printing
  bool _isPrinting = false;

  // Controller for the Zoomable Viewer
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _processFileForPreview();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  /// 1. Process File ONLY for UI Preview
  Future<void> _processFileForPreview() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    String cleanPath = widget.filePath;
    File fileToProcess;

    try {
      // Download or Resolve File
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
        if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        try {
          cleanPath = Uri.decodeFull(cleanPath);
        } catch (e) {}
        fileToProcess = File(cleanPath);

        if (!await fileToProcess.exists()) {
          throw Exception("${lang.translate('err_file_not_found')} $cleanPath");
        }
      }

      final Uint8List rawBytes = await fileToProcess.readAsBytes();
      final String ext = fileToProcess.path.split('.').last.toLowerCase();

      _previewBytes.clear();

      // Render for UI Display
      if (ext == 'pdf' || fileToProcess.path.endsWith('pdf')) {
        // Rasterize PDF pages to images for the InteractiveViewer
        await for (var page in Printing.raster(rawBytes, dpi: 150)) { // Lower DPI is fine for screen preview
          if (!mounted) break;
          final pngBytes = await page.toPng();
          setState(() {
            _previewBytes.add(pngBytes);
          });
        }
      } else {
        // Just show the image directly
        setState(() {
          _previewBytes.add(rawBytes);
        });
      }

      if (mounted) {
        setState(() => _isLoadingDoc = false);
        if (widget.autoPrint) _doPrintNative();
      }

    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = "${lang.translate('msg_error_prefix')} $e";
          _isLoadingDoc = false;
        });
      }
    }
  }

  Future<File> _downloadFile(String url) async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    final http.Response response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath =
          '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File file = File(tempPath);
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception("${lang.translate('err_download')} ${response.statusCode}");
    }
  }

  /// 2. Call Native Swift Code to Print
  Future<void> _doPrintNative() async {
    final lang = Provider.of<LanguageService>(context, listen: false);

    if (_isLoadingDoc) {
      _showSnackBar("Please wait for document to load...", isError: false);
      return;
    }

    setState(() => _isPrinting = true);

    try {
      if (Platform.isIOS) {
        // --- NATIVE IOS CALL ---
        final String result = await platform.invokeMethod('printPdf', {
          'url': widget.filePath, // Pass the file path/URL
          'mac': widget.connectedMac // Pass the UUID if specific one needed
        });
        
        _showSnackBar(result == "Success" ? lang.translate('msg_added_queue') : result);
      } else {
        // Fallback for Android (if you still use Dart for Android)
        // Or implement Android native call here
        _showSnackBar("Android printing logic here");
      }
    } on PlatformException catch (e) {
      _showSnackBar("${lang.translate('msg_error_prefix')} ${e.message}", isError: true);
    } catch (e) {
      _showSnackBar("${lang.translate('msg_error_prefix')} $e", isError: true);
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.red : Colors.green,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);
    final Size screenSize = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: Text(lang.translate('preview_title')),
      ),
      backgroundColor: Colors.grey[200],
      body: Stack(
        children: [
          // 1. ZOOMABLE VIEWER
          if (_isLoadingDoc && _previewBytes.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (_errorMessage.isNotEmpty)
            Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Text(_errorMessage,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center),
                ))
          else
            InteractiveViewer(
              transformationController: _transformController,
              panEnabled: true,
              boundaryMargin: const EdgeInsets.symmetric(
                  vertical: 80, horizontal: 20),
              minScale: 0.5,
              maxScale: 4.0,
              constrained: false,
              child: SizedBox(
                width: screenSize.width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 20),
                    // Render preview pages
                    ..._previewBytes.map((bytes) => Container(
                          margin: const EdgeInsets.only(
                              bottom: 20, left: 16, right: 16),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black.withOpacity(0.15),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                    offset: const Offset(0, 4))
                              ]),
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.high,
                          ),
                        )),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),

          // 2. PRINT BUTTON (Bottom Overlay)
          if (!_isLoadingDoc && _errorMessage.isEmpty)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      icon: _isPrinting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.print),
                      label: Text(_isPrinting
                          ? lang.translate('btn_queueing')
                          : lang.translate('btn_print_receipt')),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _isPrinting
                                  ? Colors.grey
                                  : Colors.blueAccent),
                      onPressed: _isPrinting ? null : _doPrintNative,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}