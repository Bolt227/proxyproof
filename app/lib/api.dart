import 'dart:convert';
import 'package:android_id/android_id.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiError implements Exception {
  final String code, message;
  ApiError(this.code, this.message);
  @override
  String toString() => message;
}

class Api {
  static String base = 'http://10.0.2.2:3000'; // emulator -> host. Use your PC's LAN IP on a real phone.
  static String? jwt;
  static String deviceId = '';
  static Map<String, dynamic>? user;
  static late SharedPreferences _p;

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    base = _p.getString('base') ?? base;
    jwt = _p.getString('jwt');
    final u = _p.getString('user');
    if (u != null) user = jsonDecode(u);
    deviceId = (await const AndroidId().getId()) ?? 'unknown-device';
  }

  static Future<void> setBase(String b) async {
    base = b.trim().replaceAll(RegExp(r'/+$'), '');
    await _p.setString('base', base);
  }

  static Future<void> _save(Map d) async {
    jwt = d['token'];
    user = Map<String, dynamic>.from(d['user']);
    await _p.setString('jwt', jwt!);
    await _p.setString('user', jsonEncode(user));
  }

  static Future<void> logout() async {
    jwt = null;
    user = null;
    await _p.remove('jwt');
    await _p.remove('user');
  }

  static Future<dynamic> _send(String method, String path, [Map? body]) async {
    final uri = Uri.parse('$base/api$path');
    final h = {
      'Content-Type': 'application/json',
      'X-Device-Id': deviceId,
      if (jwt != null) 'Authorization': 'Bearer $jwt',
    };
    final http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: h).timeout(const Duration(seconds: 10))
          : await http.post(uri, headers: h, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw ApiError('NETWORK', 'Cannot reach server at $base');
    }
    final data = r.body.isEmpty ? {} : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      throw ApiError(data['code'] ?? 'ERROR', data['error'] ?? 'Request failed (${r.statusCode})');
    }
    return data;
  }

  static Future<dynamic> get(String path) => _send('GET', path);
  static Future<dynamic> post(String path, [Map? body]) => _send('POST', path, body);

  static Future<void> login(String email, String password) async =>
      _save(await post('/auth/login', {'email': email, 'password': password, 'deviceId': deviceId}));

  static Future<void> register(Map body) async =>
      _save(await post('/auth/register', {...body, 'deviceId': deviceId}));
}
