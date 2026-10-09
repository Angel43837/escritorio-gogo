import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';
import 'screens/orders_screen.dart';

// Mismo backend que la app GOGO Food real (oct 2026: se separó de
// GOGO-Pruebas, ver CLAUDE.md de fercadi-delivery) — esta es una ventana
// aparte para ver/gestionar pedidos desde una computadora, no una copia de
// la app completa. Usa las mismas cuentas de dueño que ya existen.
const supabaseUrl = 'https://dlukaxbcyetcdbdjjgct.supabase.co';
const supabaseAnonKey = 'sb_publishable_MH72EXetLYHXKgklsUJ2Lw_zGLRohVY';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  runApp(const GogoPedidosApp());
}

class GogoPedidosApp extends StatelessWidget {
  const GogoPedidosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GOGO Pedidos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFFF5722),
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final Stream<AuthState> _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = Supabase.instance.client.auth.onAuthStateChange;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _authSub,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        return session != null ? const OrdersScreen() : const LoginScreen();
      },
    );
  }
}
