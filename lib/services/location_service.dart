import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_ai/firebase_ai.dart';
import '../models/fair_location.dart';

class LocationService {
  // ── API KEYS ─────────────────────────────────────────────────────────────
  static const String _googleApiKey = 'AIzaSyAhrwn4WOQrtWf-3vSiMPk6OCpVNRu0Qtw';

  // ── GEMINI MODEL ──────────────────────────────────────────────────────────
  GenerativeModel? _model;
  GenerativeModel get _gemini {
    _model ??= FirebaseAI.googleAI().generativeModel(model: 'gemini-2.5-pro');
    return _model!;
  }

  // ── PERMISSIONS / GPS ────────────────────────────────────────────────────

  Future<Position> getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled. Please enable GPS.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception(
          'Location permissions are permanently denied. Please enable in settings.');
    }

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  // ── REVERSE GEOCODING ────────────────────────────────────────────────────

  /// Returns a clean address for [position] (user location — no venue hint).
  Future<String> getAddressFromCoordinates(Position position) async {
    return _resolveAddress(position.latitude, position.longitude);
  }

  /// Returns a clean address for any lat/lng pair (no venue hint).
  Future<String> getAddressFromLatLng(double lat, double lng) async {
    return _resolveAddress(lat, lng);
  }

  /// Returns the best address for a known fair venue.
  /// Passes [fair.name] and [fair.venue] to Gemini as context so it can
  /// cross-reference the Google Geocoding result against the known venue
  /// and produce the most accurate address.
  Future<String> getAddressForFair(FairLocation fair) async {
    return _resolveAddress(
      fair.latitude,
      fair.longitude,
      venueName: fair.name,
      venueHall: fair.venue,
    );
  }

  /// Address resolution pipeline:
  /// 1. Geocoding package  — fast, device-side, good for clear urban roads.
  /// 2. Google Geocoding API — accurate database fallback when Step 1 is poor.
  /// 3. Gemini refinement  — uses the Google result + optional venue context
  ///    (name/hall) to produce the most accurate final address.
  /// 4. Last resort        — return whatever we got from Step 1 or 2.
  Future<String> _resolveAddress(
    double lat,
    double lng, {
    String? venueName,
    String? venueHall,
  }) async {
    String candidate = '';

    // ── Step 1: geocoding package ────────────────────────────────────────
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;

        // subThoroughfare = house/unit number; thoroughfare = road name.
        // Omit p.name — on Android it duplicates the road name, causing
        // "Jalan X, Jalan X" results.
        final roadSegment = [
          p.subThoroughfare ?? '',
          p.thoroughfare    ?? '',
        ].where((e) => e.isNotEmpty).join(', ');

        final parts = <String>[
          roadSegment,
          p.subLocality        ?? '',
          p.locality           ?? '',
          p.postalCode         ?? '',
          p.administrativeArea ?? '',
        ].where((e) => e.isNotEmpty).toList();

        // Remove consecutive duplicates
        final deduped = <String>[];
        for (final part in parts) {
          if (deduped.isEmpty || deduped.last != part) deduped.add(part);
        }

        candidate = deduped.join(', ');
      }
    } catch (_) {
      // geocoding failed entirely — continue to Step 2
    }

    // ── Step 2: for fair locations, always go to Google API + Gemini ───────
    // Even if the geocoding package returned something with a road name, it
    // may still be the wrong road (e.g. a nearby street instead of the venue).
    // Gemini needs the Google result as a base to cross-reference the venue.
    if (venueName != null) {
      // null = OVER_QUERY_LIMIT → skip straight to Gemini
      final googleAddress = await _googleReverseGeocode(lat, lng);
      final baseAddress = (googleAddress != null && googleAddress.isNotEmpty)
          ? googleAddress
          : candidate;
      return _geminiRefineAddress(
        lat: lat,
        lng: lng,
        baseAddress: baseAddress,
        venueName: venueName,
        venueHall: venueHall,
        fallback: baseAddress.isNotEmpty ? baseAddress : 'Address unavailable',
      );
    }

    // ── Step 3: user location — Google API only if geocoding package was poor
    if (candidate.isEmpty || _hasDuplicateSegment(candidate) || !_hasRoadName(candidate)) {
      final googleAddress = await _googleReverseGeocode(lat, lng);
      // null = OVER_QUERY_LIMIT; fall back to Gemini with candidate as base
      if (googleAddress == null) {
        return _geminiRefineAddress(
          lat: lat,
          lng: lng,
          baseAddress: candidate,
          venueName: null,
          fallback: candidate.isNotEmpty ? candidate : 'Address unavailable',
        );
      }
      if (googleAddress.isNotEmpty) return googleAddress;
    }
    return candidate.isNotEmpty ? candidate : 'Address unavailable';
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────

  bool _hasDuplicateSegment(String address) {
    final tokens = address.split(', ').map((t) => t.trim().toLowerCase()).toList();
    return tokens.length != tokens.toSet().length;
  }

  bool _hasRoadName(String address) {
    final roadKeywords = RegExp(
      r'\b(jalan|jln|lorong|lrg|persiaran|lebuh|lebuhraya|highway|avenue|street|road|ptd|plot|km\s*\d|off\b)',
      caseSensitive: false,
    );
    return roadKeywords.hasMatch(address);
  }

  // ── GOOGLE GEOCODING API ──────────────────────────────────────────────────

  /// Returns the formatted address, empty string on normal failure, or
  /// null specifically when OVER_QUERY_LIMIT is hit (so the caller can
  /// fall through to Gemini instead of giving up).
  Future<String?> _googleReverseGeocode(
    double lat,
    double lng,
  ) async {
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/geocode/json',
        {
          'latlng': '$lat,$lng',
          'key': _googleApiKey,
          'language': 'en',
          'region': 'MY',
        },
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return '';

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final status = json['status'] as String;
      if (status == 'OVER_QUERY_LIMIT') {
        debugPrint('Geocoding API: OVER_QUERY_LIMIT — falling back to Gemini');
        return null; // signal to caller: skip to Gemini
      }
      if (status != 'OK') {
        debugPrint('Geocoding API status: $status');
        return '';
      }

      final results = json['results'] as List<dynamic>;
      if (results.isEmpty) return '';

      // Prefer a street-address result; fall back to the first result.
      final streetResult = results.firstWhere(
        (r) => (r['types'] as List).contains('street_address'),
        orElse: () => results.first,
      );

      final formatted = (streetResult['formatted_address'] as String).trim();
      // Strip trailing ", Malaysia" — redundant for a local app.
      return formatted
          .replaceAll(RegExp(r',?\s*Malaysia\s*$', caseSensitive: false), '')
          .trim();
    } catch (e) {
      debugPrint('Google Geocoding API error: $e');
      return '';
    }
  }

  // ── GEMINI REFINEMENT ─────────────────────────────────────────────────────

  /// Uses Gemini to produce the most accurate address by combining the
  /// Google Geocoding result with the known venue name and hall.
  /// This catches cases where the API returns a nearby road instead of the
  /// exact venue address (e.g. PTD-style rural addresses in Johor).
  Future<String> _geminiRefineAddress({
    required double lat,
    required double lng,
    required String baseAddress,
    String? venueName,
    String? venueHall,
    String fallback = 'Address unavailable',
  }) async {
    try {
      // Build venue context lines only when available (omitted for user locations)
      // venueLines carries only the hall — venueName is placed separately in the prompt.
      final venueLines = venueHall != null && venueHall.isNotEmpty
          ? '\n  Hall/Building : $venueHall'
          : '';

      final prompt = venueName != null
          // ── Fair location: give Gemini the venue name + hall as the primary
          //    source of truth, with the Google result as a supporting hint.
          //    The geocoded candidate is intentionally excluded — it comes from
          //    device reverse-geocoding the coordinates and may be wrong.
          ? 'You are a Malaysian address accuracy assistant.\n\n'
            'Find the correct full street address for this venue:\n'
            '  Venue name    : $venueName$venueLines\n'
            '  Coordinates   : $lat, $lng\n'
            '  Google result : ${baseAddress.isNotEmpty ? baseAddress : 'unavailable'} (may be inaccurate)\n\n'
            'Use the venue name and hall as the primary reference. '
            'The Google result is a hint only — correct it if it is wrong.\n'
            'Return ONLY the full street address as one plain-text line:\n'
            '  <house/unit number>, <road name>, <taman/neighbourhood>, <postcode> <city>, <state>\n'
            'Rules:\n'
            '- Omit house/unit number only if unknown.\n'
            '- Omit country name.\n'
            '- Never repeat the same word or phrase.\n'
            '- No JSON, markdown, or explanation — address string only.'
          // ── User location: no venue context, just clean up the base result.
          : 'You are a Malaysian address accuracy assistant.\n\n'
            'A reverse geocoding lookup returned this address:\n'
            '  Base result   : ${baseAddress.isNotEmpty ? baseAddress : 'unavailable'}\n'
            '  Coordinates   : $lat, $lng\n\n'
            'Return ONLY the full street address as one plain-text line:\n'
            '  <house/unit number>, <road name>, <taman/neighbourhood>, <postcode> <city>, <state>\n'
            'Rules:\n'
            '- Omit house/unit number only if unknown.\n'
            '- Omit country name.\n'
            '- Never repeat the same word or phrase.\n'
            '- If the base result is already accurate, return it as-is.\n'
            '- No JSON, markdown, or explanation — address string only.';

      final response = await _gemini.generateContent([Content.text(prompt)]);
      final text = response.text?.trim() ?? '';
      return text.isNotEmpty ? text : fallback;
    } catch (e) {
      debugPrint('Gemini refine error: $e');
      return fallback;
    }
  }

  // ── DISTANCE / PROXIMITY ─────────────────────────────────────────────────

  double distanceTo(Position current, FairLocation fair) {
    return Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      fair.latitude,
      fair.longitude,
    );
  }

  FairLocation nearestFair(Position current, List<FairLocation> fairs) {
    FairLocation nearest = fairs.first;
    double minDist = double.infinity;
    for (final fair in fairs) {
      final d = distanceTo(current, fair);
      if (d < minDist) {
        minDist = d;
        nearest = fair;
      }
    }
    return nearest;
  }

  bool isWithinRadius(Position current, FairLocation fair) {
    return distanceTo(current, fair) <= fair.radius;
  }
}