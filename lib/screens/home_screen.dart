import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/fair_location.dart';
import '../services/location_service.dart';
import '../services/participation_service.dart';
import 'history_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final LocationService _locationService = LocationService();
  final MapController _mapController = MapController();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  Position? _currentPosition;
  String _addressText = 'Locating you...';

  // The "selected" fair — starts as nearest, changes when user taps a list item
  FairLocation? _selectedFair;
  String _selectedFairAddress = 'Fetching address...';
  double? _distanceToSelectedFair;
  bool _isAtSelectedFair = false;

  int _selectFairToken = 0; // incremented on each _selectFair call to cancel stale results
  bool _isLoading = true;
  bool _isAddressLoading = false;     // user's own address is being fetched
  bool _isFairAddressLoading = false; // selected fair address is being fetched
  int _totalPoints = 0;
  bool _isJoining = false;
  String? _errorMessage;

  double _currentZoom = 13.0;
  double _sheetSize = 0.42;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _sheetController.addListener(_onSheetChanged);
    _loadData();
  }

  void _onSheetChanged() {
    if (_sheetController.isAttached) {
      setState(() => _sheetSize = _sheetController.size);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sheetController.removeListener(_onSheetChanged);
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    await _fetchLocation();
    await _refreshPoints();
  }

  Future<void> _fetchLocation() async {
    setState(() {
      _isLoading = true;
      _isAddressLoading = true;
      _isFairAddressLoading = true;
      _errorMessage = null;
      _addressText = 'Fetching location...';
      _selectedFairAddress = 'Fetching address...';
    });
    try {
      final position = await _locationService.getCurrentLocation();
      final nearest = _locationService.nearestFair(position, kCareerFairs);
      final distance = _locationService.distanceTo(position, nearest);
      final atFair = _locationService.isWithinRadius(position, nearest);

      // Show coordinates and fair immediately — don't wait for address fetches
      setState(() {
        _currentPosition = position;
        _selectedFair = nearest;
        _distanceToSelectedFair = distance;
        _isAtSelectedFair = atFair;
        _isLoading = false;
      });

      // Fetch addresses in parallel, update UI as each completes
      _locationService.getAddressFromCoordinates(position).then((address) {
        if (mounted) {
          setState(() {
            _addressText = address;
            _isAddressLoading = false;
          });
        }
      });

      _locationService.getAddressForFair(nearest).then((fairAddress) {
        if (mounted && _selectedFair == nearest) {
          setState(() {
            _selectedFairAddress = fairAddress;
            _isFairAddressLoading = false;
          });
        }
      });

      _mapController.move(
        LatLng(position.latitude, position.longitude),
        _currentZoom,
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
        _isAddressLoading = false;
        _isFairAddressLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _addressText = 'Location unavailable';
      });
    }
  }

  Future<void> _refreshPoints() async {
    final pts = await ParticipationService.getTotalPoints();
    setState(() => _totalPoints = pts);
  }

  Future<void> _joinFair() async {
    if (_currentPosition == null || _selectedFair == null) return;
    if (!_isAtSelectedFair) {
      _showSnack('You are not within the fair radius.', isError: true);
      return;
    }
    setState(() => _isJoining = true);
    await ParticipationService.recordParticipation(
      fair: _selectedFair!,
      userLat: _currentPosition!.latitude,
      userLng: _currentPosition!.longitude,
    );
    await _refreshPoints();
    setState(() => _isJoining = false);
    _showSnack(
      '🎉 Joined ${_selectedFair!.name}! +${_selectedFair!.points} pts',
      isError: false,
    );
  }

  /// Called when the user taps a fair in the list.
  /// Flies the map to that fair AND updates the fair card data.
  Future<void> _selectFair(FairLocation fair) async {
    _mapController.move(LatLng(fair.latitude, fair.longitude), 15.0);

    // Increment token so any in-flight address fetch for a previous fair
    // will see a stale token and discard its result.
    final token = ++_selectFairToken;

    setState(() {
      _currentZoom = 15.0;
      _selectedFair = fair;
      _selectedFairAddress = 'Fetching address...';
      _isFairAddressLoading = true;
      if (_currentPosition != null) {
        _distanceToSelectedFair =
            _locationService.distanceTo(_currentPosition!, fair);
        _isAtSelectedFair =
            _locationService.isWithinRadius(_currentPosition!, fair);
      } else {
        _distanceToSelectedFair = null;
        _isAtSelectedFair = false;
      }
    });

    // Reverse-geocode the fair location in the background
    final fairAddress = await _locationService.getAddressForFair(fair);
    if (mounted && token == _selectFairToken) {
      // Only apply if no newer selection has been made
      setState(() {
        _selectedFairAddress = fairAddress;
        _isFairAddressLoading = false;
      });
    }
  }

  void _zoomIn() {
    final newZoom = (_currentZoom + 1).clamp(1.0, 18.0);
    _mapController.move(_mapController.camera.center, newZoom);
    setState(() => _currentZoom = newZoom);
  }

  void _zoomOut() {
    final newZoom = (_currentZoom - 1).clamp(1.0, 18.0);
    _mapController.move(_mapController.camera.center, newZoom);
    setState(() => _currentZoom = newZoom);
  }

  String _formatDistance(double? meters) {
    if (meters == null) return '-- km';
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  void _showSnack(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        backgroundColor:
            isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── NAVIGATION TO MAPS ────────────────────────────────────────────────────
  void _openNavigationSheet() {
    if (_selectedFair == null) return;
    final lat = _selectedFair!.latitude;
    final lng = _selectedFair!.longitude;
    final label = Uri.encodeComponent(_selectedFair!.name);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1B2A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Navigate to Fair',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _selectedFair!.name,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _NavOption(
              icon: Icons.map_rounded,
              label: 'Google Maps',
              color: const Color(0xFF4285F4),
              onTap: () async {
                Navigator.pop(context);
                final uri = Uri.parse(
                    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
            ),
            const SizedBox(height: 10),
            _NavOption(
              icon: Icons.navigation_rounded,
              label: 'Waze',
              color: const Color(0xFF33CCFF),
              onTap: () async {
                Navigator.pop(context);
                final uri = Uri.parse(
                    'https://waze.com/ul?ll=$lat,$lng&navigate=yes');
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
            ),
            const SizedBox(height: 10),
            _NavOption(
              icon: Icons.apple_rounded,
              label: 'Apple Maps',
              color: const Color(0xFF64D2FF),
              onTap: () async {
                Navigator.pop(context);
                final uri = Uri.parse(
                    'https://maps.apple.com/?daddr=$lat,$lng&dirflg=d&t=m');
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final zoomButtonBottom = (screenHeight * _sheetSize) + 12;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Stack(
        children: [
          Positioned.fill(child: _buildMap()),
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.42,
            minChildSize: 0.12,
            maxChildSize: 0.75,
            snap: true,
            snapSizes: const [0.12, 0.42, 0.75],
            builder: (context, scrollController) =>
                _buildBottomPanel(scrollController),
          ),
          Positioned(
            right: 14,
            bottom: zoomButtonBottom,
            child: Column(
              children: [
                _ZoomButton(icon: Icons.add, onTap: _zoomIn, tooltip: 'Zoom in'),
                const SizedBox(height: 6),
                _ZoomButton(
                    icon: Icons.remove, onTap: _zoomOut, tooltip: 'Zoom out'),
              ],
            ),
          ),
          _buildTopBar(),
        ],
      ),
    );
  }

  // ── MAP ───────────────────────────────────────────────────────────────────
  Widget _buildMap() {
    final userLat = _currentPosition?.latitude ?? 3.1570;
    final userLng = _currentPosition?.longitude ?? 101.7110;
    final fairLat = _selectedFair?.latitude ?? 3.1570;
    final fairLng = _selectedFair?.longitude ?? 101.7110;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: LatLng(fairLat, fairLng),
        initialZoom: _currentZoom,
        onPositionChanged: (position, hasGesture) {
          if (hasGesture) setState(() => _currentZoom = position.zoom);
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.pinchMove |
              InteractiveFlag.scrollWheelZoom,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.internship_checkin',
        ),
        if (_selectedFair != null)
          CircleLayer(
            circles: [
              CircleMarker(
                point: LatLng(fairLat, fairLng),
                radius: _selectedFair!.radius,
                useRadiusInMeter: true,
                color: (_isAtSelectedFair ? Colors.green : Colors.blue)
                    .withOpacity(0.15),
                borderColor:
                    _isAtSelectedFair ? Colors.green : Colors.blue,
                borderStrokeWidth: 2.5,
              ),
            ],
          ),
        MarkerLayer(
          markers: kCareerFairs
              .map(
                (fair) => Marker(
                  point: LatLng(fair.latitude, fair.longitude),
                  width: 52,
                  height: 52,
                  child: GestureDetector(
                    onTap: () => _selectFair(fair),
                    child: _FairMarker(
                        fair: fair, isSelected: fair == _selectedFair),
                  ),
                ),
              )
              .toList(),
        ),
        if (_currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(userLat, userLng),
                width: 48,
                height: 48,
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (_, __) => Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withOpacity(0.5),
                            blurRadius: 10,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.my_location,
                          color: Colors.blue, size: 28),
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ── TOP BAR ───────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF0D1B2A).withOpacity(0.95),
              const Color(0xFF0D1B2A).withOpacity(0.0),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E3A5F),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.work_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Career Fair Tracker',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      'BTPR2043 · Lab Assignment II',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const HistoryScreen()),
                  ).then((_) => _refreshPoints()),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC107),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.amber.withOpacity(0.4),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.stars_rounded,
                            color: Color(0xFF5D4037), size: 16),
                        const SizedBox(width: 4),
                        Text(
                          '$_totalPoints pts',
                          style: const TextStyle(
                            color: Color(0xFF3E2723),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _isLoading ? null : _fetchLocation,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A5F),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.refresh_rounded,
                            color: Colors.white, size: 22),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── BOTTOM PANEL ──────────────────────────────────────────────────────────
  Widget _buildBottomPanel(ScrollController scrollController) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: CustomScrollView(
        controller: scrollController,
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 4),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildAddressRow(),
                      const SizedBox(height: 12),
                      if (_selectedFair != null) _buildFairCard(),
                      if (_errorMessage != null) _buildErrorCard(),
                      const SizedBox(height: 12),
                      if (_selectedFair != null) _buildStatusRow(),
                      const SizedBox(height: 14),
                      _buildActionButtons(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
                _buildFairsQuickList(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── REUSABLE INFO ROW ─────────────────────────────────────────────────────
  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    bool isLoading = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 13),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      style: TextStyle(
                        color: color == Colors.white38
                            ? Colors.white54
                            : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 1.45,
                      ),
                    ),
                  ),
                  if (isLoading) ...[
                    const SizedBox(width: 6),
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── MY CURRENT LOCATION CARD ──────────────────────────────────────────────
  Widget _buildAddressRow() {
    final lat = _currentPosition?.latitude;
    final lng = _currentPosition?.longitude;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1628),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.lightBlueAccent.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.lightBlueAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.person_pin_circle_rounded,
                    color: Colors.lightBlueAccent, size: 16),
              ),
              const SizedBox(width: 8),
              const Text(
                'MY CURRENT LOCATION',
                style: TextStyle(
                  color: Colors.lightBlueAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 10),
          _buildInfoRow(
            icon: Icons.location_on_rounded,
            label: 'Address',
            value: _addressText,
            color: Colors.orangeAccent,
            isLoading: _isAddressLoading,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildInfoRow(
                  icon: Icons.straighten_rounded,
                  label: 'Latitude',
                  value: lat != null ? lat.toStringAsFixed(6) : '--',
                  color: Colors.greenAccent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInfoRow(
                  icon: Icons.straighten_rounded,
                  label: 'Longitude',
                  value: lng != null ? lng.toStringAsFixed(6) : '--',
                  color: Colors.greenAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── SELECTED FAIR CARD ────────────────────────────────────────────────────
  Widget _buildFairCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E3A5F), Color(0xFF0D2137)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isAtSelectedFair
              ? Colors.green.withOpacity(0.4)
              : Colors.blue.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.event_rounded,
                    color: Colors.lightBlueAccent, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _selectedFair!.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFFFFC107).withOpacity(0.5)),
                ),
                child: Text(
                  '+${_selectedFair!.points} pts',
                  style: const TextStyle(
                    color: Color(0xFFFFC107),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 10),

          // Venue
          _buildInfoRow(
            icon: Icons.place_rounded,
            label: 'Venue',
            value: _selectedFair!.venue,
            color: Colors.orangeAccent,
          ),
          const SizedBox(height: 10),

          // Address (reverse-geocoded)
          _buildInfoRow(
            icon: Icons.location_on_outlined,
            label: 'Address',
            value: _selectedFairAddress,
            color: Colors.orangeAccent,
            isLoading: _isFairAddressLoading,
          ),
          const SizedBox(height: 10),

          // About
          _buildInfoRow(
            icon: Icons.info_outline_rounded,
            label: 'About',
            value: _selectedFair!.description,
            color: Colors.white38,
          ),
          const SizedBox(height: 10),

          // Coordinates side by side
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildInfoRow(
                  icon: Icons.straighten_rounded,
                  label: 'Latitude',
                  value: _selectedFair!.latitude.toStringAsFixed(6),
                  color: Colors.greenAccent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInfoRow(
                  icon: Icons.straighten_rounded,
                  label: 'Longitude',
                  value: _selectedFair!.longitude.toStringAsFixed(6),
                  color: Colors.greenAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade700.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow() {
    final distDisplay = _distanceToSelectedFair != null
        ? _distanceToSelectedFair! < 1000
            ? '${_distanceToSelectedFair!.toStringAsFixed(0)} m away'
            : '${(_distanceToSelectedFair! / 1000).toStringAsFixed(1)} km away'
        : '--';

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: (_isAtSelectedFair ? Colors.green : Colors.orange)
                  .withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (_isAtSelectedFair ? Colors.green : Colors.orange)
                    .withOpacity(0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isAtSelectedFair
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  color:
                      _isAtSelectedFair ? Colors.greenAccent : Colors.orange,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  _isAtSelectedFair ? 'At Fair' : 'Not At Fair',
                  style: TextStyle(
                    color:
                        _isAtSelectedFair ? Colors.greenAccent : Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E3A5F),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.near_me_rounded,
                    color: Colors.lightBlueAccent, size: 16),
                const SizedBox(width: 6),
                Text(
                  distDisplay,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        // Join Fair
        Expanded(
          flex: 3,
          child: GestureDetector(
            onTap: (_isLoading || _isJoining || !_isAtSelectedFair)
                ? null
                : _joinFair,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 52,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: (_isAtSelectedFair && !_isLoading)
                      ? [const Color(0xFF00C853), const Color(0xFF1B5E20)]
                      : [Colors.grey.shade800, Colors.grey.shade900],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: _isAtSelectedFair
                    ? [
                        BoxShadow(
                          color: Colors.green.withOpacity(0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                        )
                      ]
                    : [],
              ),
              child: Center(
                child: _isJoining
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.how_to_reg_rounded,
                              color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Join Fair',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Navigate button
        Expanded(
          flex: 2,
          child: GestureDetector(
            onTap: _openNavigationSheet,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF1A3A2A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.directions_rounded,
                      color: Colors.greenAccent, size: 20),
                  SizedBox(width: 6),
                  Text(
                    'Navigate',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),

        // History
        Expanded(
          flex: 2,
          child: GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ).then((_) => _refreshPoints()),
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A5F),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history_rounded,
                      color: Colors.lightBlueAccent, size: 20),
                  SizedBox(width: 6),
                  Text(
                    'History',
                    style: TextStyle(
                      color: Colors.lightBlueAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── ALL FAIRS LIST ────────────────────────────────────────────────────────
  Widget _buildFairsQuickList() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1628),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Text(
                'ALL FAIRS',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              Spacer(),
              Icon(Icons.touch_app_rounded, color: Colors.white24, size: 13),
              SizedBox(width: 4),
              Text(
                'tap to select & view on map',
                style: TextStyle(color: Colors.white24, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...kCareerFairs.map((fair) {
            final double? distMeters = _currentPosition != null
                ? _locationService.distanceTo(_currentPosition!, fair)
                : null;
            final String distLabel = _formatDistance(distMeters);
            final bool isSelected = fair == _selectedFair;

            return GestureDetector(
              onTap: () => _selectFair(fair),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF1E3A5F).withOpacity(0.6)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: isSelected
                      ? Border.all(
                          color: Colors.lightBlueAccent.withOpacity(0.3))
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? Colors.lightBlueAccent
                            : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        fair.name,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white54,
                          fontSize: 12.5,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D2137),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.lightBlueAccent.withOpacity(0.2)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.near_me_rounded,
                              color: Colors.lightBlueAccent, size: 10),
                          const SizedBox(width: 3),
                          Text(
                            distLabel,
                            style: const TextStyle(
                              color: Colors.lightBlueAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E3A5F),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '+${fair.points}',
                        style: const TextStyle(
                          color: Color(0xFFFFC107),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ── NAVIGATION OPTION TILE ────────────────────────────────────────────────────
class _NavOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _NavOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Icon(Icons.arrow_forward_ios_rounded, color: color, size: 14),
          ],
        ),
      ),
    );
  }
}

// ── ZOOM BUTTON WIDGET ────────────────────────────────────────────────────────
class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ZoomButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF1E3A5F),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
            border: Border.all(color: Colors.white12),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// Custom fair pin widget
class _FairMarker extends StatelessWidget {
  final FairLocation fair;
  final bool isSelected;

  const _FairMarker({required this.fair, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.location_pin,
      color: isSelected ? Colors.blue : Colors.blueGrey,
      size: 40,
      shadows: const [
        Shadow(color: Colors.black38, blurRadius: 6, offset: Offset(1, 2)),
      ],
    );
  }
}