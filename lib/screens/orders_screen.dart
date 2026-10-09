import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';

// Colores de marca GOGO — naranja, azul y blanco, mismos que ya usa la app
// móvil de GOGO Food. El naranja no cambia con el tema (es la marca); lo
// demás (fondos, texto) sí cambia entre claro/oscuro.
const _gogoOrange = Color(0xFFFF5722);
const _gogoBlue = Color(0xFF2196F3);

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String? _restaurantId;
  String _restaurantName = '';
  String? _restaurantLogoUrl;
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  RealtimeChannel? _channel;
  Timer? _pollTimer;
  bool _isDark = false;

  // Llamar a un repartidor de flota (botón flotante azul) — ver
  // supabase/migrations/20261008000000_rider_calls.sql en fercadi-delivery.
  String? _activeCallId;
  String? _callStatus; // null = sin llamada activa, 'pendiente' | 'aceptado'
  RealtimeChannel? _callChannel;
  Timer? _callPollTimer;

  Color get _bg => _isDark ? const Color(0xFF121212) : Colors.white;
  Color get _textMain => _isDark ? Colors.white : const Color(0xFF1A1A1A);
  Color get _textMuted => _isDark ? Colors.white54 : Colors.black45;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _pollTimer?.cancel();
    _callChannel?.unsubscribe();
    _callPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _callRider() async {
    if (_restaurantId == null || _activeCallId != null) return;
    final id = await SupabaseService.callRider(_restaurantId!, _restaurantName);
    if (!mounted) return;
    setState(() { _activeCallId = id; _callStatus = 'pendiente'; });
    _callChannel?.unsubscribe();
    _callChannel = SupabaseService.subscribeToRiderCall(id, _checkCallStatus);
    // Respaldo por si el realtime se queda callado, mismo patrón que ya se
    // usa para los pedidos.
    _callPollTimer?.cancel();
    _callPollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkCallStatus());
  }

  Future<void> _checkCallStatus() async {
    if (_activeCallId == null) return;
    final data = await SupabaseService.getRiderCall(_activeCallId!);
    if (!mounted || data == null) return;
    final status = data['status'] as String? ?? 'pendiente';
    if (status == _callStatus) return;
    setState(() => _callStatus = status);
    if (status != 'pendiente') {
      _callChannel?.unsubscribe(); _callChannel = null;
      _callPollTimer?.cancel();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == 'aceptado'
            ? '¡Un repartidor va en camino a recoger! 🏍️'
            : 'La llamada se canceló.'),
        backgroundColor: status == 'aceptado' ? Colors.green : Colors.orange,
      ));
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) setState(() { _activeCallId = null; _callStatus = null; });
      });
    }
  }

  Future<void> _init() async {
    final restaurantId = SupabaseService.getRestaurantId();
    if (restaurantId == null) return;
    _restaurantId = restaurantId;
    final info = await SupabaseService.getRestaurantInfo(restaurantId);
    if (mounted) {
      setState(() {
        _restaurantName = info?['name'] as String? ?? 'Mi restaurante';
        _restaurantLogoUrl = info?['image_url'] as String?;
      });
    }
    await _loadOrders();
    _channel = SupabaseService.subscribeToOrders(restaurantId, _loadOrders);
    // Respaldo por si el realtime se queda callado — mismo patrón que ya
    // usa la app móvil de GOGO Food.
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _loadOrders());
  }

  Future<void> _loadOrders() async {
    if (_restaurantId == null) return;
    try {
      final data = await SupabaseService.getOrders(_restaurantId!);
      if (mounted) setState(() { _orders = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _aceptar(String orderId) async {
    await SupabaseService.aceptarPedido(orderId);
    _loadOrders();
  }

  Future<void> _rechazar(String orderId) async {
    await SupabaseService.rechazarPedido(orderId);
    _loadOrders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(child: _buildOrdersPanel()),
      floatingActionButton: _buildCallRiderButton(),
    );
  }

  // Botón flotante tipo burbuja de WhatsApp (pero azul) — llama a todos los
  // repartidores de flota en línea; el primero que acepte se lo queda.
  Widget _buildCallRiderButton() {
    final isPending = _callStatus == 'pendiente';
    final isAccepted = _callStatus == 'aceptado';
    return Tooltip(
      message: isPending ? 'Esperando que un repartidor acepte…' : 'Llamar a un repartidor',
      child: FloatingActionButton(
        onPressed: isPending ? null : _callRider,
        backgroundColor: isAccepted ? Colors.green : (isPending ? Colors.orange : _gogoBlue),
        elevation: 6,
        shape: const CircleBorder(),
        child: isPending
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
              )
            : Icon(isAccepted ? Icons.check_rounded : Icons.delivery_dining_rounded,
                color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildOrdersPanel() {
    final pendientes = _orders.where((o) => o['status'] == 'pending').toList();
    final enProceso = _orders.where((o) =>
        o['status'] == 'restaurant_accepted' ||
        o['status'] == 'accepted' ||
        o['status'] == 'delivering').toList();
    final terminados = _orders.where((o) =>
        o['status'] == 'delivered' || o['status'] == 'cancelled').toList();

    return Column(children: [
      _buildHeader(pendientes.length),
      if (_loading)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _gogoOrange)))
      else
        Expanded(
          child: Container(
            color: _bg,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildWhatsAppPreview(),
                const SizedBox(height: 16),
                if (_orders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Text('Todavía no hay pedidos de GOGO',
                          style: TextStyle(color: _textMuted, fontSize: 14)),
                    ),
                  )
                else ...[
                  if (pendientes.isNotEmpty) ...[
                    _sectionLabel('Nuevos — esperando confirmación (${pendientes.length})'),
                    ...pendientes.map((o) => _OrderCard(
                          order: o,
                          isDark: _isDark,
                          onAceptar: () => _aceptar(o['id'] as String),
                          onRechazar: () => _rechazar(o['id'] as String),
                        )),
                    const SizedBox(height: 16),
                  ],
                  if (enProceso.isNotEmpty) ...[
                    _sectionLabel('En proceso (${enProceso.length})'),
                    ...enProceso.map((o) => _OrderCard(order: o, isDark: _isDark)),
                    const SizedBox(height: 16),
                  ],
                  if (terminados.isNotEmpty) ...[
                    _sectionLabel('Terminados hoy (${terminados.length})'),
                    ...terminados.map((o) => _OrderCard(order: o, isDark: _isDark)),
                  ],
                ],
              ],
            ),
          ),
        ),
    ]);
  }

  // Solo un ejemplo de cómo se vería un pedido que llega escrito por
  // WhatsApp — todavía no está conectado de verdad (falta la API de Meta),
  // así que a propósito no tiene botones de aceptar/rechazar, es nada más
  // para ver el diseño.
  Widget _buildWhatsAppPreview() {
    const whatsappGreen = Color(0xFF25D366);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: whatsappGreen.withValues(alpha: _isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: whatsappGreen.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 6,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.chat, color: whatsappGreen, size: 18),
              const SizedBox(width: 8),
              Text('Pedidos por WhatsApp',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _textMain, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(width: 8),
            ]),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: whatsappGreen, borderRadius: BorderRadius.circular(8)),
              child: const Text('VISTA PREVIA',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ejemplo — 55 1234 5678',
                style: TextStyle(color: _textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Hola, quiero 2 tacos de asada y una coca, mi domicilio es Calle Falsa 123',
                style: TextStyle(color: _textMain, fontSize: 13)),
          ]),
        ),
        const SizedBox(height: 8),
        Text('Cuando esté conectada la API de WhatsApp, mensajes como este llegarán aquí solos.',
            style: TextStyle(color: _textMuted, fontSize: 11)),
      ]),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Text(text,
            style: TextStyle(color: _textMuted, fontWeight: FontWeight.bold, fontSize: 12)),
      );

  Widget _buildHeader(int pendientesCount) {
    return Container(
      color: _gogoOrange,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(children: [
        SvgPicture.asset('assets/images/logo.svg', height: 46,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
        const SizedBox(width: 14),
        Container(width: 1, height: 34, color: Colors.white.withValues(alpha: 0.3)),
        const SizedBox(width: 14),
        Container(
          width: 38, height: 38,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
          child: (_restaurantLogoUrl != null && _restaurantLogoUrl!.isNotEmpty)
              ? Image.network(_restaurantLogoUrl!, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.storefront_rounded, color: Colors.white, size: 18))
              : const Icon(Icons.storefront_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(_restaurantName,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              overflow: TextOverflow.ellipsis),
        ),
        if (pendientesCount > 0)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Text('$pendientesCount',
                style: const TextStyle(color: _gogoOrange, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        IconButton(
          icon: Icon(_isDark ? Icons.wb_sunny_rounded : Icons.nightlight_round, color: Colors.white70, size: 20),
          tooltip: _isDark ? 'Modo claro' : 'Modo oscuro',
          onPressed: () => setState(() => _isDark = !_isDark),
        ),
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white70, size: 20),
          tooltip: 'Cerrar sesión',
          onPressed: () => SupabaseService.signOut(),
        ),
      ]),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool isDark;
  final VoidCallback? onAceptar;
  final VoidCallback? onRechazar;
  const _OrderCard({required this.order, required this.isDark, this.onAceptar, this.onRechazar});

  static const _statusLabels = {
    'pending': ('Pendiente', Color(0xFFFFB300)),
    'restaurant_accepted': ('Confirmado', _gogoBlue),
    'accepted': ('Repartidor asignado', _gogoOrange),
    'delivering': ('En camino', _gogoBlue),
    'delivered': ('Entregado', Colors.green),
    'cancelled': ('Cancelado', Colors.red),
  };

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String? ?? 'pending';
    final (label, color) = _statusLabels[status] ?? ('Desconocido', Colors.grey);
    final delivery = SupabaseService.parseDelivery(order['customer_name']);
    final name = delivery['name'] as String? ?? 'Cliente';
    final address = delivery['address'] as String? ?? '';
    final total = (order['total'] as num?)?.toDouble() ?? 0;
    final items = (order['order_items'] as List<dynamic>? ?? []);

    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textMain = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textMuted = isDark ? Colors.white54 : Colors.black45;
    final textBody = isDark ? Colors.white70 : Colors.black.withValues(alpha: 0.7);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textMain, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
            child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ]),
        if (address.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(address, style: TextStyle(color: textMuted, fontSize: 11)),
        ],
        const SizedBox(height: 8),
        ...items.map((i) {
          final qty = i['quantity'] as int? ?? 1;
          final product = i['products'] as Map<String, dynamic>?;
          final pname = product?['name'] as String? ?? 'Producto';
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('$qty× $pname', style: TextStyle(color: textBody, fontSize: 12)),
          );
        }),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text('\$${total.toStringAsFixed(0)} MXN',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textMain, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          if (onRechazar != null)
            OutlinedButton(
              onPressed: onRechazar,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: const Text('Rechazar', style: TextStyle(fontSize: 12)),
            ),
          if (onAceptar != null) ...[
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: onAceptar,
              style: ElevatedButton.styleFrom(backgroundColor: _gogoOrange, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14)),
              child: const Text('Aceptar', style: TextStyle(fontSize: 12)),
            ),
          ],
        ]),
      ]),
    );
  }
}
