import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../models/fair_location.dart';

class ParticipationEntry {
  final String fairName;
  final String venue;
  final int points;
  final String timestamp;
  final double latitude;
  final double longitude;

  ParticipationEntry({
    required this.fairName,
    required this.venue,
    required this.points,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
  });

  Map<String, dynamic> toJson() => {
        'fairName': fairName,
        'venue': venue,
        'points': points,
        'timestamp': timestamp,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory ParticipationEntry.fromJson(Map<String, dynamic> json) =>
      ParticipationEntry(
        fairName: json['fairName'] ?? '',
        venue: json['venue'] ?? '',
        points: json['points'] ?? 0,
        timestamp: json['timestamp'] ?? '',
        latitude: (json['latitude'] ?? 0).toDouble(),
        longitude: (json['longitude'] ?? 0).toDouble(),
      );
}

class ParticipationService {
  static const String _historyKey = 'participation_history';
  static const String _pointsKey = 'total_points';

  static Future<void> recordParticipation({
    required FairLocation fair,
    required double userLat,
    required double userLng,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_historyKey) ?? [];

    final formatted = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now());

    final entry = ParticipationEntry(
      fairName: fair.name,
      venue: fair.venue,
      points: fair.points,
      timestamp: formatted,
      latitude: userLat,
      longitude: userLng,
    );

    history.add(jsonEncode(entry.toJson()));
    await prefs.setStringList(_historyKey, history);

    final current = prefs.getInt(_pointsKey) ?? 0;
    await prefs.setInt(_pointsKey, current + fair.points);
  }

  static Future<List<ParticipationEntry>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_historyKey) ?? [];
    return history
        .map((e) => ParticipationEntry.fromJson(jsonDecode(e)))
        .toList()
        .reversed
        .toList();
  }

  static Future<int> getTotalPoints() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_pointsKey) ?? 0;
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    await prefs.remove(_pointsKey);
  }
}
