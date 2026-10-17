import 'package:flutter/material.dart';
import 'api.dart';
import 'screens/auth.dart';
import 'screens/organiser.dart';
import 'screens/student.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.init();
  runApp(const ProxyProofApp());
}

class ProxyProofApp extends StatelessWidget {
  const ProxyProofApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxyProof',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6C8CFF), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF6C8CFF), brightness: Brightness.dark, useMaterial3: true),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (Api.jwt == null || Api.user == null) return AuthScreen(onDone: _refresh);
    final role = Api.user!['role'];
    return role == 'student'
        ? StudentHome(onLogout: _refresh)
        : OrganiserHome(onLogout: _refresh);
  }
}
