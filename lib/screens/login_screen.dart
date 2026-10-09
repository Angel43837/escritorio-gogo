import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Escribe tu correo y contraseña.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    final error = await SupabaseService.signIn(email, password);
    if (error != null) {
      if (mounted) setState(() { _loading = false; _error = error; });
      return;
    }
    // Solo cuentas de dueño de restaurante pueden usar esta app.
    final currentUser = Supabase.instance.client.auth.currentUser;
    final role = (currentUser?.userMetadata?['role'] as String?) ??
        (currentUser?.appMetadata['role'] as String?);
    final restaurantId = SupabaseService.getRestaurantId();
    if (role != 'dueno' || restaurantId == null || restaurantId.isEmpty) {
      await SupabaseService.signOut();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Esta cuenta no es de un restaurante — usa tu cuenta de dueño de GOGO Food.';
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 380,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SvgPicture.asset(
                'assets/images/logo.svg',
                height: 72,
                colorFilter: const ColorFilter.mode(Color(0xFFFF5722), BlendMode.srcIn),
              ),
              const SizedBox(height: 12),
              const Text('GOGO Pedidos',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const Text('Panel de pedidos para tu restaurante',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 32),
              TextField(
                controller: _emailCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  labelStyle: TextStyle(color: Colors.white54),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                onSubmitted: (_) => _login(),
                decoration: const InputDecoration(
                  labelText: 'Contraseña',
                  labelStyle: TextStyle(color: Colors.white54),
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _login,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF5722)),
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('INICIAR SESIÓN', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
