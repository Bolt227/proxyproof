import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';
import '../api.dart';
import '../ble_consts.dart';

class OrganiserHome extends StatefulWidget {
  final VoidCallback onLogout;
  const OrganiserHome({super.key, required this.onLogout});
  @override
  State<OrganiserHome> createState() => _OrganiserHomeState();
}

class _OrganiserHomeState extends State<OrganiserHome> {
  final title = TextEditingController(text: 'Lecture');
  final minutes = TextEditingController(text: '5');
  final ble = FlutterBlePeripheral();
  int? sessionId;
  int endsAt = 0;
  int left = 0;
  String token = '';
  String status = 'Idle';
  Timer? poll, clock;
  String? error;

  @override
  void dispose() {
    poll?.cancel();
    clock?.cancel();
    ble.stop();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => error = null);
    final st = await [Permission.bluetoothAdvertise, Permission.bluetoothConnect].request();
    if (st.values.any((s) => !s.isGranted)) {
      setState(() => error = 'Bluetooth permission is required to broadcast.');
      return;
    }
    try {
      final r = await Api.post('/sessions', {
        'title': title.text.trim().isEmpty ? 'Session' : title.text.trim(),
        'durationMinutes': int.tryParse(minutes.text) ?? 5,
      });
      sessionId = r['id'];
      endsAt = r['endsAt'];
      status = 'Broadcasting';
      await _tick();
      poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
      clock = Timer.periodic(const Duration(seconds: 1), (_) {
        final l = endsAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (l <= 0) { _stop('Session ended'); } else if (mounted) { setState(() => left = l); }
      });
      setState(() {});
    } on ApiError catch (e) {
      setState(() => error = e.message);
    }
  }

  Future<void> _tick() async {
    if (sessionId == null) return;
    try {
      final r = await Api.get('/sessions/$sessionId/token');
      final t = r['token'] as String;
      if (t != token) {
        token = t;
        await _advertise(sessionId!, t);
        if (mounted) setState(() {});
      }
    } on ApiError catch (e) {
      if (e.code == 'SESSION_CLOSED') _stop('Session ended');
    }
  }

  Future<void> _advertise(int sid, String tokenHex) async {
    final b = ByteData(8)..setUint32(0, sid);
    for (var i = 0; i < 4; i++) {
      b.setUint8(4 + i, int.parse(tokenHex.substring(i * 2, i * 2 + 2), radix: 16));
    }
    await ble.stop();
    await ble.start(
      advertiseData: AdvertiseDataCore(
        serviceUuid: kServiceUuid,
        manufacturerId: kCompanyId,
        manufacturerData: b.buffer.asUint8List(),
      ),
      androidSettings: const AndroidAdvertiseSettings(
        advertiseSettings: AdvertiseSettings(
          advertiseMode: AdvertiseMode.advertiseModeLowLatency,
          txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium, // medium power keeps range roughly room-sized
          connectable: false,
          timeout: 0,
        ),
      ),
    );
  }

  Future<void> _stop(String why, {bool closeOnServer = false}) async {
    poll?.cancel();
    clock?.cancel();
    await ble.stop();
    if (closeOnServer && sessionId != null) {
      try { await Api.post('/sessions/$sessionId/close'); } catch (_) {}
    }
    if (mounted) setState(() { sessionId = null; token = ''; status = why; left = 0; });
  }

  String get _mmss => '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final active = sessionId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text('Organiser · ${Api.user!['name']}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              if (active) await _stop('Stopped', closeOnServer: true);
              await Api.logout();
              widget.onLogout();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: active
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.podcasts, size: 96),
                const SizedBox(height: 12),
                Text(status, style: Theme.of(context).textTheme.headlineSmall),
                Text(_mmss, style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 8),
                Text('Session #$sessionId · rotating code: $token', style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 8),
                const Text('Keep this screen open. Students nearby are marked automatically.\nWatch live on the web dashboard.', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.tonal(onPressed: () => _stop('Session closed', closeOnServer: true), child: const Text('Close session now')),
              ])
            : ListView(children: [
                Text(status, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Session title', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: minutes, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)', border: OutlineInputBorder())),
                if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_arrow), label: const Text('Start session & broadcast')),
              ]),
      ),
    );
  }
}
