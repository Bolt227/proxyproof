import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import '../api.dart';
import '../ble_consts.dart';

class StudentHome extends StatefulWidget {
  final VoidCallback onLogout;
  const StudentHome({super.key, required this.onLogout});
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
  int tab = 0;
  String status = 'Starting scanner…';
  bool ok = false, busy = false;
  final marked = <int>{};
  DateTime lastSend = DateTime(2000);
  final rssiWindow = <int, List<int>>{}; // last few RSSI readings per session, averaged to smooth out spikes
  StreamSubscription? sub;
  Map<String, dynamic>? history;

  @override
  void initState() {
    super.initState();
    _startScan();
    _loadHistory();
  }

  @override
  void dispose() {
    sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    final st = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    if (st.values.any((s) => !s.isGranted)) {
      setState(() => status = 'Bluetooth + location permission is required to detect the class.');
      return;
    }
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try { await FlutterBluePlus.turnOn(); } catch (_) {}
    }
    sub = FlutterBluePlus.scanResults.listen(_onResults);
    await FlutterBluePlus.startScan(
      withServices: [Guid(kServiceShort)],
      continuousUpdates: true,
      androidUsesFineLocation: true,
    );
    if (mounted) setState(() => status = 'Looking for your class… just keep this app open near the organiser.');
  }

  void _onResults(List<ScanResult> list) {
    for (final r in list) {
      final m = r.advertisementData.manufacturerData[kCompanyId];
      if (m == null || m.length < 8) continue;
      final sid = ByteData.sublistView(Uint8List.fromList(m)).getUint32(0);
      final token = m.sublist(4, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final w = rssiWindow.putIfAbsent(sid, () => <int>[])..add(r.rssi);
      if (w.length > 5) w.removeAt(0);
      _submit(sid, token, (w.reduce((a, b) => a + b) / w.length).round());
    }
  }

  Future<void> _submit(int sid, String token, int rssi) async {
    if (marked.contains(sid) || busy) return;
    // Server allows 20 attempts/min; 4 s spacing keeps us well under it even while the signal is weak.
    if (DateTime.now().difference(lastSend) < const Duration(seconds: 4)) return;
    lastSend = DateTime.now();
    busy = true;
    try {
      final r = await Api.post('/attendance/mark', {'sessionId': sid, 'token': token, 'rssi': rssi});
      if (r['ok'] == true) {
        marked.add(sid);
        if (mounted) setState(() { ok = true; status = 'Attendance marked ✓'; });
        _loadHistory();
      }
    } on ApiError catch (e) {
      if (e.code == 'STALE_TOKEN') {
        // token rotated while the request was in flight; next advertisement will carry a fresh one
      } else if (e.code == 'SESSION_CLOSED') {
        marked.add(sid);
      } else if (mounted) {
        setState(() { ok = false; status = e.message; });
      }
    } finally {
      busy = false;
    }
  }

  Future<void> _loadHistory() async {
    try {
      final h = await Api.get('/me/attendance');
      if (mounted) setState(() => history = Map<String, dynamic>.from(h));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final u = Api.user!;
    return Scaffold(
      appBar: AppBar(
        title: Text(u['name'] ?? 'Student'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FlutterBluePlus.stopScan();
              await Api.logout();
              widget.onLogout();
            },
          ),
        ],
      ),
      body: tab == 0 ? _scanTab() : _historyTab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) { setState(() => tab = i); if (i == 1) _loadHistory(); },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: 'Attendance'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }

  Widget _scanTab() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(ok ? Icons.check_circle : Icons.radar, size: 96, color: ok ? Colors.green : null),
            const SizedBox(height: 16),
            Text(status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            if (!ok) const LinearProgressIndicator(),
          ]),
        ),
      );

  Widget _historyTab() {
    final h = history;
    if (h == null) return const Center(child: CircularProgressIndicator());
    final sessions = (h['sessions'] as List);
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Text('${h['percentage']}%', style: Theme.of(context).textTheme.displaySmall),
              Text('${h['present']} of ${h['total']} sessions attended'),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        for (final s in sessions)
          ListTile(
            leading: Icon(s['present'] ? Icons.check_circle : Icons.cancel_outlined, color: s['present'] ? Colors.green : Colors.redAccent),
            title: Text(s['title']),
            subtitle: Text(DateFormat('d MMM y, h:mm a').format(DateTime.fromMillisecondsSinceEpoch((s['startedAt'] as int) * 1000))),
            trailing: s['method'] == 'manual' ? const Chip(label: Text('manual')) : null,
          ),
      ]),
    );
  }
}
