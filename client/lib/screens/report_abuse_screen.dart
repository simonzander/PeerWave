import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../services/api_service.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:intl/intl.dart';

class ReportAbuseScreen extends StatefulWidget {
  final String reportedUuid;
  final String reportedDisplayName;

  const ReportAbuseScreen({
    required this.reportedUuid,
    required this.reportedDisplayName,
    super.key,
  });

  @override
  State<ReportAbuseScreen> createState() => _ReportAbuseScreenState();
}

class _ReportAbuseScreenState extends State<ReportAbuseScreen> {
  final TextEditingController _descriptionController = TextEditingController();
  final List<String> _photos = []; // Base64 strings
  bool _isSubmitting = false;
  bool _reportSubmitted = false;
  String? _reportUuid;
  DateTime? _submissionTime;

  Future<void> _pickPhoto() async {
    if (_photos.length >= 5) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Maximum 5 photos allowed')));
      return;
    }

    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1080,
    );

    if (image == null) return;

    Uint8List compressed;

    if (kIsWeb) {
      // On web, just read the bytes directly (ImagePicker already limits size)
      compressed = await image.readAsBytes();
    } else {
      // On mobile/desktop, use flutter_image_compress
      final result = await FlutterImageCompress.compressWithFile(
        image.path,
        minWidth: 1920,
        minHeight: 1080,
        quality: 85,
      );

      if (result == null) return;
      compressed = result;
    }

    // Check size (max 5MB)
    if (compressed.length > 5 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo too large (max 5MB)')),
        );
      }
      return;
    }

    setState(() {
      _photos.add(base64Encode(compressed));
    });
  }

  Future<void> _submitReport() async {
    if (_descriptionController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please describe the issue')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final response = await ApiService.instance.post(
        '/api/report-abuse',
        data: {
          'reportedUuid': widget.reportedUuid,
          'description': _descriptionController.text,
          'photos': _photos,
        },
      );

      if (response.statusCode == 200) {
        setState(() {
          _reportSubmitted = true;
          _reportUuid = response.data['reportUuid'];
          _submissionTime = DateTime.now();
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Report submitted successfully. User has been blocked.',
              ),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to submit report: $e')));
      }
    } finally {
      setState(() => _isSubmitting = false);
    }
  }

  Future<void> _downloadReportAsPdf() async {
    if (_submissionTime == null) return;

    final pdf = pw.Document();

    // Convert base64 images to memory images for PDF
    final List<pw.MemoryImage> pdfImages = [];
    for (final photoBase64 in _photos) {
      try {
        final bytes = base64Decode(photoBase64);
        pdfImages.add(pw.MemoryImage(bytes));
      } catch (e) {
        print('Error decoding image: $e');
      }
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          // Header
          pw.Header(
            level: 0,
            child: pw.Text(
              'Abuse Report',
              style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 20),

          // Report metadata
          pw.Container(
            padding: const pw.EdgeInsets.all(16),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Report ID:',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(_reportUuid ?? 'N/A'),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Submitted:',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(
                      DateFormat(
                        'MMM d, yyyy - h:mm a',
                      ).format(_submissionTime!),
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Reported User:',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(widget.reportedDisplayName),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 20),

          // Description section
          pw.Text(
            'Description:',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Text(
              _descriptionController.text,
              style: const pw.TextStyle(fontSize: 12),
            ),
          ),
          pw.SizedBox(height: 20),

          // Photos section
          if (pdfImages.isNotEmpty) ...[
            pw.Text(
              'Attached Photos (${pdfImages.length}):',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
            ...pdfImages.asMap().entries.map((entry) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Photo ${entry.key + 1}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 8),
                  pw.Container(
                    constraints: const pw.BoxConstraints(maxHeight: 400),
                    child: pw.Image(entry.value),
                  ),
                  pw.SizedBox(height: 16),
                ],
              );
            }),
          ],

          // Footer
          pw.SizedBox(height: 20),
          pw.Divider(),
          pw.SizedBox(height: 8),
          pw.Text(
            'This report has been submitted to the server administrators. The reported user has been automatically blocked.',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    // Save or share the PDF
    try {
      await Printing.sharePdf(
        bytes: await pdf.save(),
        filename:
            'abuse_report_${DateFormat('yyyyMMdd_HHmmss').format(_submissionTime!)}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save PDF: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: const Text('Report Abuse')),
      body: _reportSubmitted ? _buildSuccessView() : _buildFormView(),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
              size: 80,
            ),
            const SizedBox(height: 24),
            const Text(
              'Report Submitted Successfully',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'The user ${widget.reportedDisplayName} has been blocked and your report has been sent to the administrators.',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _downloadReportAsPdf,
              icon: const Icon(Icons.download),
              label: const Text('Download Report as PDF'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Report ${widget.reportedDisplayName}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            'Please describe what happened. Include any relevant context.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descriptionController,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Describe the issue...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Add Photos (Optional)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._photos.asMap().entries.map((entry) {
                return Stack(
                  children: [
                    Image.memory(
                      base64Decode(entry.value),
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                        onPressed: () {
                          setState(() => _photos.removeAt(entry.key));
                        },
                      ),
                    ),
                  ],
                );
              }),
              if (_photos.length < 5)
                InkWell(
                  onTap: _pickPhoto,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    child: const Icon(Icons.add_photo_alternate, size: 40),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '⚠️ Note: Submitting this report will also block this user. You won\'t be able to message each other. You can download a PDF copy of this report after submission.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitReport,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isSubmitting
                  ? const CircularProgressIndicator()
                  : const Text('Submit Report & Block User'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }
}
