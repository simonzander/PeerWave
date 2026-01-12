import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/api_service.dart';
import 'package:intl/intl.dart';
import 'dart:convert';

class AbuseCenterPage extends StatefulWidget {
  const AbuseCenterPage({super.key});

  @override
  State<AbuseCenterPage> createState() => _AbuseCenterPageState();
}

class _AbuseCenterPageState extends State<AbuseCenterPage> {
  List<Map<String, dynamic>> _reports = [];
  bool _isLoading = true;
  String _statusFilter =
      'pending'; // pending, under_review, resolved, dismissed, all

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  Future<void> _loadReports() async {
    setState(() => _isLoading = true);
    try {
      final url = _statusFilter == 'all'
          ? '/api/abuse-reports'
          : '/api/abuse-reports?status=$_statusFilter';
      final response = await ApiService.get(url);
      if (response.statusCode == 200) {
        setState(() {
          _reports = List<Map<String, dynamic>>.from(response.data);
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load reports: $e')));
      }
    }
  }

  Future<void> _updateStatus(String reportUuid, String newStatus) async {
    try {
      final response = await ApiService.put(
        '/api/abuse-reports/$reportUuid/status',
        data: {'status': newStatus},
      );

      if (response.statusCode == 200) {
        _loadReports();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Report status updated')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update status: $e')));
      }
    }
  }

  Future<void> _deleteReport(String reportUuid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Report'),
        content: const Text(
          'Are you sure you want to permanently delete this report? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final response = await ApiService.delete(
        '/api/abuse-reports/$reportUuid',
        data: {'confirmed': true},
      );

      if (response.statusCode == 200) {
        _loadReports();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Report deleted')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete report: $e')));
      }
    }
  }

  void _contactUser(String userUuid) {
    context.go('/app/messages/$userUuid');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Abuse Center'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _statusFilter,
            onSelected: (value) {
              setState(() => _statusFilter = value);
              _loadReports();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'pending', child: Text('Pending')),
              const PopupMenuItem(
                value: 'under_review',
                child: Text('Under Review'),
              ),
              const PopupMenuItem(value: 'resolved', child: Text('Resolved')),
              const PopupMenuItem(value: 'dismissed', child: Text('Dismissed')),
              const PopupMenuItem(value: 'all', child: Text('All')),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
          ? Center(
              child: Text(
                'No ${_statusFilter == 'all' ? '' : _statusFilter} reports',
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              itemCount: _reports.length,
              itemBuilder: (context, index) {
                final report = _reports[index];
                final reporter = report['reporter'];
                final reported = report['reported'];
                final createdAt = DateTime.parse(report['created_at']);
                final photos = report['photos'] != null
                    ? List<String>.from(jsonDecode(report['photos']))
                    : <String>[];

                return Card(
                  margin: const EdgeInsets.all(8),
                  child: ExpansionTile(
                    leading: Icon(
                      Icons.report,
                      color: report['status'] == 'pending'
                          ? Colors.red
                          : Colors.orange,
                    ),
                    title: Text(
                      '${reporter['displayName']} reported ${reported['displayName']}',
                    ),
                    subtitle: Text(
                      '${DateFormat.yMMMd().add_jm().format(createdAt)} • ${report['status']}',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Description:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Text(report['description']),
                            if (photos.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              const Text(
                                'Photos:',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: photos.map((photo) {
                                  return Image.memory(
                                    base64Decode(photo),
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                  );
                                }).toList(),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.message, size: 16),
                                  label: const Text('Contact Reporter'),
                                  onPressed: () =>
                                      _contactUser(reporter['uuid']),
                                ),
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.message, size: 16),
                                  label: const Text('Contact Reported'),
                                  onPressed: () =>
                                      _contactUser(reported['uuid']),
                                ),
                                DropdownButton<String>(
                                  value: report['status'],
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'pending',
                                      child: Text('Pending'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'under_review',
                                      child: Text('Under Review'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'resolved',
                                      child: Text('Resolved'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'dismissed',
                                      child: Text('Dismissed'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value != null) {
                                      _updateStatus(
                                        report['report_uuid'],
                                        value,
                                      );
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                  ),
                                  onPressed: () =>
                                      _deleteReport(report['report_uuid']),
                                  tooltip: 'Delete Report',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
