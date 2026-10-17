import 'package:flutter/material.dart';
import '../api.dart';

class AuthScreen extends StatefulWidget {
  final VoidCallback onDone;
  const AuthScreen({super.key, required this.onDone});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final server = TextEditingController(text: Api.base);
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final roll = TextEditingController();
  final invite = TextEditingController();
  bool register = false, organiser = false, busy = false;
  String? error;

  Future<void> _submit() async {
    setState(() { busy = true; error = null; });
    try {
      await Api.setBase(server.text);
      if (register) {
        await Api.register({
          'name': name.text.trim(),
          'email': email.text.trim(),
          'password': password.text,
          'role': organiser ? 'organiser' : 'student',
          'rollNo': roll.text.trim(),
          'inviteCode': invite.text.trim(),
        });
      } else {
        await Api.login(email.text.trim(), password.text);
      }
      widget.onDone();
    } on ApiError catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.bluetooth_connected, size: 56),
                const SizedBox(height: 8),
                Text('ProxyProof', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 20),
                TextField(controller: server, decoration: const InputDecoration(labelText: 'Server URL', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                if (register) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Student')),
                      ButtonSegment(value: true, label: Text('Organiser')),
                    ],
                    selected: {organiser},
                    onSelectionChanged: (s) => setState(() => organiser = s.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  if (!organiser) ...[
                    TextField(controller: roll, decoration: const InputDecoration(labelText: 'Roll number', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                  ] else ...[
                    TextField(controller: invite, decoration: const InputDecoration(labelText: 'Organiser invite code', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                  ],
                ],
                TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 16),
                FilledButton(onPressed: busy ? null : _submit, child: Text(busy ? 'Please wait…' : (register ? 'Create account' : 'Log in'))),
                TextButton(onPressed: () => setState(() => register = !register), child: Text(register ? 'Have an account? Log in' : 'New here? Register')),
                if (register && !organiser)
                  const Text('Your phone is bound to this account. Changing phones later needs admin approval.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
