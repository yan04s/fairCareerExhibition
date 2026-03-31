import 'package:flutter/material.dart';
import '../services/participation_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ParticipationEntry> _history = [];
  int _totalPoints = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final history = await ParticipationService.getHistory();
    final points = await ParticipationService.getTotalPoints();
    setState(() {
      _history = history;
      _totalPoints = points;
      _isLoading = false;
    });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E3A5F),
        title: const Text('Clear History',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will remove all participation records and reset points to 0.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ParticipationService.clearAll();
      _load();
    }
  }

  Color _pointColor(int points) {
    if (points >= 50) return Colors.amber;
    if (points >= 30) return Colors.lightBlueAccent;
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Participation History',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent),
              onPressed: _confirmClear,
              tooltip: 'Clear all',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.lightBlueAccent))
          : Column(
              children: [
                _buildSummaryBanner(),
                Expanded(
                  child: _history.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _history.length,
                          itemBuilder: (_, i) =>
                              _buildEntryCard(_history[i], i),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummaryBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E3A5F), Color(0xFF0D2137)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.stars_rounded, color: Color(0xFFFFC107), size: 36),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Total Points Earned',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Text(
                '$_totalPoints points',
                style: const TextStyle(
                  color: Color(0xFFFFC107),
                  fontWeight: FontWeight.bold,
                  fontSize: 26,
                ),
              ),
            ],
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${_history.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 24,
                ),
              ),
              const Text(
                'fairs attended',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(ParticipationEntry entry, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A5F).withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _pointColor(entry.points).withOpacity(0.15),
            shape: BoxShape.circle,
            border: Border.all(
                color: _pointColor(entry.points).withOpacity(0.5)),
          ),
          child: Icon(Icons.business_center_rounded,
              color: _pointColor(entry.points), size: 22),
        ),
        title: Text(
          entry.fairName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.place_rounded,
                    color: Colors.white38, size: 12),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    entry.venue,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11.5),
                    softWrap: true,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.access_time_rounded,
                    color: Colors.white38, size: 12),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    entry.timestamp,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _pointColor(entry.points).withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: _pointColor(entry.points).withOpacity(0.4)),
          ),
          child: Text(
            '+${entry.points}',
            style: TextStyle(
              color: _pointColor(entry.points),
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.event_busy_rounded,
              color: Colors.white24, size: 72),
          const SizedBox(height: 16),
          const Text(
            'No participation yet',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(height: 6),
          const Text(
            'Attend a fair to earn points!',
            style: TextStyle(color: Colors.white24, fontSize: 13),
          ),
        ],
      ),
    );
  }
}