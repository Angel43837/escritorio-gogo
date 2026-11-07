import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../services/supabase_service.dart';

// Colores de marca GOGO — naranja, azul y blanco, mismos que ya usa la app
// móvil de GOGO Food. El naranja no cambia con el tema (es la marca); lo
// demás (fondos, texto) sí cambia entre claro/oscuro.
const _gogoOrange = Color(0xFFFF5722);
// Tono más oscuro que _gogoOrange — así la tarjeta del pedido se distingue
// del fondo naranja de la pantalla en vez de perderse en él.
const _cardOrange = Color(0xFFE64A19);
const _gogoBlue = Color(0xFF2196F3);
const _whatsappGreen = Color(0xFF25D366);

class _ActiveCall {
  final String id;
  String status = 'pendiente'; // 'pendiente' | 'aceptado'
  RealtimeChannel? channel;
  Timer? pollTimer;
  _ActiveCall(this.id);
}

// Un pedido que llegó escrito por WhatsApp (fuera de la app) — cada uno
// con su propio número y mensaje, para contestarle a varios a la vez.
class _WaMessageCard {
  final TextEditingController phoneCtrl = TextEditingController();
  final TextEditingController messageCtrl = TextEditingController();
  void dispose() {
    phoneCtrl.dispose();
    messageCtrl.dispose();
  }
}

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
  // El botón siempre llama a uno nuevo (puede haber varios pedidos
  // esperando motociclista distinto al mismo tiempo) — el estado de cada
  // llamada vive en su propia tarjeta en la lista, no en el botón.
  final List<_ActiveCall> _activeCalls = [];
  final Set<String> _marcandoEntregadoIds = {};

  // Varios pedidos pueden llegar por WhatsApp a la vez — cada uno es su
  // propio rectángulo con su propio número, para no tener que elegir la
  // conversación a mano cada vez que se le picka enviar.
  final List<_WaMessageCard> _waMessages = [];

  Color get _bg => _isDark ? const Color(0xFF121212) : _gogoOrange;
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
    for (final call in _activeCalls) {
      call.channel?.unsubscribe();
      call.pollTimer?.cancel();
    }
    for (final card in _waMessages) {
      card.dispose();
    }
    super.dispose();
  }

  void _addWaMessage() {
    setState(() => _waMessages.add(_WaMessageCard()));
  }

  void _removeWaMessage(_WaMessageCard card) {
    card.dispose();
    setState(() => _waMessages.remove(card));
  }

  Future<bool> _confirm({required String title, required String message, required String confirmLabel}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _gogoOrange, foregroundColor: Colors.white),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _snack(String msg, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : Colors.green,
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _confirmAndCallRider() async {
    // Antes esto podía quedarse callado del todo si algo fallaba (sin
    // tarjeta nueva, sin cobro, sin ningún aviso) — ahora CUALQUIER salida
    // de esta función antes de llegar al cobro real avisa algo, nunca
    // queda en silencio.
    if (_restaurantId == null) {
      _snack('No se pudo pedir el repartidor: no se encontró tu restaurante. Cierra sesión y vuelve a entrar.');
      return;
    }
    final hasCard = await _ensurePaymentMethod();
    if (!mounted) return;
    if (!hasCard) return; // _ensurePaymentMethod ya avisó qué pasó.
    final ok = await _confirm(
      title: '¿Pedir un repartidor?',
      message: 'Se cobrarán \$38 MXN a tu tarjeta (\$3 de cuota + \$35 de envío para el repartidor). '
          'Si nadie acepta en 3 horas, se reembolsa solo.',
      confirmLabel: 'Sí, pedir',
    );
    if (ok) _callRider();
  }

  // Antes de dejar que pida un repartidor, checa si el restaurante ya tiene
  // una tarjeta guardada en Stripe — si no, lo manda a agregarla en el
  // navegador (Stripe Checkout en modo 'setup', no se maneja ninguna
  // tarjeta a mano aquí). Regresa true solo si YA tiene tarjeta y puede
  // seguir directo al cobro — en cualquier otro caso regresa false, pero
  // siempre avisando por qué (antes algunos caminos se quedaban mudos).
  Future<bool> _ensurePaymentMethod() async {
    if (_restaurantId == null) return false;
    try {
      final status = await SupabaseService.getPaymentMethodStatus(_restaurantId!);
      if (status['hasCard'] == true) return true;
    } catch (e) {
      _snack('No se pudo revisar tu método de pago: $e');
      return false;
    }
    if (!mounted) return false;
    final addNow = await _confirm(
      title: 'Agrega tu tarjeta',
      message: 'Para pedir repartidores necesitas una tarjeta guardada. Se abrirá en tu navegador — es seguro, '
          'Stripe la guarda directo, GOGO nunca ve el número completo.',
      confirmLabel: 'Agregar tarjeta',
    );
    if (!addNow || !mounted) return false;
    try {
      final url = await SupabaseService.startPaymentMethodSetup(_restaurantId!);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      _snack('Agrega tu tarjeta en el navegador y vuelve a darle a "Pedir un repartidor".', isError: false);
    } catch (e) {
      _snack('No se pudo abrir el pago: $e');
    }
    return false;
  }

  Future<void> _confirmAndCancelCall(String id) async {
    final ok = await _confirm(
      title: '¿Cancelar la llamada?',
      message: 'Ya no se le avisará a ningún repartidor de este pedido.',
      confirmLabel: 'Sí, cancelar',
    );
    if (ok) _cancelCall(id);
  }

  // Siempre crea una llamada nueva — no se bloquea si ya hay otra en curso,
  // porque puede haber más de un pedido esperando motociclista a la vez.
  Future<void> _callRider() async {
    if (_restaurantId == null) return;
    String id;
    try {
      id = await SupabaseService.callRider(_restaurantId!, _restaurantName);
    } catch (e) {
      _snack('No se pudo cobrar ni pedir el repartidor: $e');
      return;
    }
    if (!mounted) return;
    final call = _ActiveCall(id);
    call.channel = SupabaseService.subscribeToRiderCall(id, () => _checkCallStatus(id));
    call.pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkCallStatus(id));
    setState(() => _activeCalls.add(call));
    _snack('¡Listo! Se cobraron \$38 MXN y ya se le avisó a los repartidores.', isError: false);
  }

  Future<void> _checkCallStatus(String id) async {
    final call = _activeCalls.where((c) => c.id == id).firstOrNull;
    if (call == null) return;
    final data = await SupabaseService.getRiderCall(id);
    if (!mounted || data == null) return;
    final status = data['status'] as String? ?? 'pendiente';
    if (status == call.status) return;
    setState(() => call.status = status);
    if (status != 'pendiente') {
      call.channel?.unsubscribe(); call.channel = null;
      call.pollTimer?.cancel();
      // "Aceptado" se queda visible (su tarjeta en la lista) hasta que el
      // dueño la cierre a mano — es información que importa, no algo para
      // que parpadee y desaparezca solo. "Cancelado"/"rechazado" sí se
      // puede quitar solo, no hay nada que seguir viendo.
      if (status != 'aceptado') {
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted) setState(() => _activeCalls.removeWhere((c) => c.id == id));
        });
      }
    }
  }

  void _dismissCall(String id) {
    setState(() => _activeCalls.removeWhere((c) => c.id == id));
  }

  Future<void> _cancelCall(String id) async {
    final call = _activeCalls.where((c) => c.id == id).firstOrNull;
    if (call == null) return;
    call.channel?.unsubscribe();
    call.pollTimer?.cancel();
    setState(() => _activeCalls.removeWhere((c) => c.id == id));
    await SupabaseService.cancelRiderCall(id);
  }

  Future<void> _marcarEntregado(String id) async {
    if (_marcandoEntregadoIds.contains(id)) return;
    setState(() => _marcandoEntregadoIds.add(id));
    try {
      await SupabaseService.markRiderCallDelivered(id);
      if (!mounted) return;
      setState(() {
        _activeCalls.removeWhere((c) => c.id == id);
        _marcandoEntregadoIds.remove(id);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _marcandoEntregadoIds.remove(id));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo marcar como entregado. Intenta de nuevo.'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // Una tarjeta por cada llamada activa — viven en la misma lista que los
  // pedidos (justo abajo del aviso de WhatsApp), no como un banner fijo
  // arriba de todo. El botón flotante solo dispara llamadas nuevas; aquí se
  // ve el estado de cada una y aquí mismo se puede cancelar.
  List<Widget> _buildCallStatusCards() {
    return _activeCalls.map((call) {
      final isPending = call.status == 'pendiente';
      final statusColor = isPending ? Colors.orange : Colors.green;
      return Container(
        key: ValueKey(call.id),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: statusColor.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          Icon(isPending ? Icons.two_wheeler_rounded : Icons.check_circle_rounded, color: statusColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isPending
                  ? 'Pediste un repartidor — esperando que alguien acepte…'
                  : '¡Han aceptado tu pedido! El repartidor llega en un momento.',
              style: TextStyle(color: _textMain, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          if (isPending)
            ElevatedButton(
              onPressed: () => _confirmAndCancelCall(call.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
            )
          else ...[
            ElevatedButton(
              onPressed: _marcandoEntregadoIds.contains(call.id) ? null : () => _marcarEntregado(call.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: _marcandoEntregadoIds.contains(call.id)
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Entregado', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              icon: Icon(Icons.close, color: _textMuted, size: 18),
              tooltip: 'Cerrar',
              onPressed: () => _dismissCall(call.id),
            ),
          ],
        ]),
      );
    }).toList();
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
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // Botón flotante tipo burbuja de WhatsApp (pero azul) — llama a todos los
  // repartidores de flota en línea; el primero que acepte se lo queda.
  // Siempre está disponible para llamar a otro (puede haber varios pedidos
  // necesitando motociclista distinto a la vez) — el estado de cada llamada
  // se ve en su propia tarjeta en la lista, no aquí.
  Widget _buildCallRiderButton() {
    return Tooltip(
      message: 'Llamar a un repartidor',
      child: FloatingActionButton(
        onPressed: _confirmAndCallRider,
        backgroundColor: _gogoBlue,
        elevation: 6,
        shape: const CircleBorder(),
        child: const Icon(Icons.delivery_dining_rounded, color: Colors.white, size: 28),
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

    final callCards = _buildCallStatusCards();

    return Column(children: [
      _buildHeader(pendientes.length),
      if (_loading)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _gogoOrange)))
      else
        Expanded(
          child: Container(
            color: _bg,
            child: DefaultTabController(
              length: 5,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TabBar(
                    indicatorColor: Colors.white,
                    indicatorWeight: 3,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(
                        child: Text('Todos (${_orders.length})',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                      Tab(
                        child: Text('Nuevos (${pendientes.length})',
                            style: const TextStyle(color: Color(0xFFFFB300), fontWeight: FontWeight.bold)),
                      ),
                      Tab(
                        child: Text('En proceso (${enProceso.length})',
                            style: const TextStyle(color: _gogoBlue, fontWeight: FontWeight.bold)),
                      ),
                      Tab(
                        child: Text('Terminados (${terminados.length})',
                            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                      ),
                      const Tab(
                        child: Text('WhatsApp',
                            style: TextStyle(color: _whatsappGreen, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                if (callCards.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Column(children: callCards),
                  ),
                Expanded(
                  child: TabBarView(children: [
                    _buildOrderListView(_orders),
                    _buildOrderListView(pendientes),
                    _buildOrderListView(enProceso),
                    _buildOrderListView(terminados),
                    Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _buildWhatsAppPreview(),
                            const SizedBox(height: 16),
                            Text('Pedidos por WhatsApp (${_waMessages.length})',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 8),
                            ..._waMessages.map(_buildWaMessageCard),
                            OutlinedButton.icon(
                              onPressed: _addWaMessage,
                              icon: const Icon(Icons.add_rounded, size: 16, color: Colors.white),
                              label: const Text('Agregar mensaje', style: TextStyle(color: Colors.white, fontSize: 12)),
                              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }

  // Cada estado tiene ya su propio apartado (pestaña) en vez de ir todos
  // apilados en una sola lista larga — así "Terminados" no queda enterrado
  // hasta abajo del scroll.
  Widget _buildOrderListView(List<Map<String, dynamic>> orders) {
    if (orders.isEmpty) {
      return const Center(
        child: Text('Nada por aquí todavía', style: TextStyle(color: Colors.white70, fontSize: 14)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: orders.map((o) {
        final esPendiente = o['status'] == 'pending';
        return _OrderCard(
          order: o,
          isDark: _isDark,
          onAceptar: esPendiente ? () => _aceptar(o['id'] as String) : null,
          onRechazar: esPendiente ? () => _rechazar(o['id'] as String) : null,
        );
      }).toList(),
    );
  }

  // El mensaje de ejemplo de arriba sigue siendo solo eso, un ejemplo (falta
  // la API de Meta para que los pedidos por WhatsApp lleguen solos aquí) —
  // pero los botones de abajo sí funcionan de verdad: son para cuando un
  // pedido llega escrito directo por WhatsApp (fuera de la app), y el dueño
  // quiere responder rápido sin escribir nada.
  Widget _buildWhatsAppPreview() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _whatsappGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const FaIcon(FontAwesomeIcons.whatsapp, color: Colors.white, size: 15),
              const SizedBox(width: 6),
              const Text('Pedidos por WhatsApp',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
              const SizedBox(width: 6),
            ]),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
              child: const Text('VISTA PREVIA',
                  style: TextStyle(color: _whatsappGreen, fontSize: 8, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ejemplo — 55 1234 5678',
                style: TextStyle(color: _textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Text('Hola, quiero 2 tacos de asada y una coca, mi domicilio es Calle Falsa 123',
                style: TextStyle(color: _textMain, fontSize: 11)),
          ]),
        ),
        const SizedBox(height: 10),
        // Pedidos que llegan escritos directo por WhatsApp (no por la app)
        // no tienen un número guardado en ningún lado de nuestra base — por
        // eso estos botones no mandan a un número fijo: abren WhatsApp con
        // el mensaje ya escrito y el propio dueño elige a quién, desde su
        // conversación real.
        Wrap(spacing: 8, runSpacing: 8, children: [
          _whatsAppPreviewChip('Preparando', () => _sendWhatsAppGeneric('Tu pedido ya se está preparando 👨‍🍳')),
          _whatsAppPreviewChip('Recibido', () => _sendWhatsAppGeneric('Ya recibimos tu pedido, gracias por tu compra 👍')),
          _whatsAppPreviewChip('Ya va para allá', () => _sendWhatsAppGeneric('Tu pedido ya va en camino 🛵')),
        ]),
        const SizedBox(height: 6),
        const Text('Mensajes predeterminados — ábrelos y elige la conversación en WhatsApp.',
            style: TextStyle(color: Colors.white70, fontSize: 9)),
      ]),
    );
  }

  Future<void> _sendWhatsAppGeneric(String message) async {
    final uri = Uri.parse('https://api.whatsapp.com/send?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _sendWhatsAppTo(String phone, String message) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    // Los teléfonos se guardan a 10 dígitos locales — wa.me necesita el
    // código de país (52, México) adelante para abrir el chat correcto.
    final full = digits.length == 10 ? '52$digits' : digits;
    final uri = Uri.parse('https://wa.me/$full?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // Un rectángulo por cada pedido que llega por WhatsApp — cada uno con su
  // propio número, para que "enviar" le llegue directo a ese cliente sin
  // tener que elegir la conversación a mano cada vez.
  Widget _buildWaMessageCard(_WaMessageCard card) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _whatsappGreen.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: card.phoneCtrl,
              keyboardType: TextInputType.phone,
              style: TextStyle(color: _textMain, fontSize: 12, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: 'Número de WhatsApp',
                hintStyle: TextStyle(color: _textMuted, fontSize: 12),
                isDense: true,
                prefixIcon: const Icon(Icons.phone, size: 16, color: _whatsappGreen),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: _textMuted),
            tooltip: 'Quitar',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _removeWaMessage(card),
          ),
        ]),
        const Divider(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: card.messageCtrl,
              style: TextStyle(color: _textMain, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Escribe tu mensaje…',
                hintStyle: TextStyle(color: _textMuted, fontSize: 12),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: _isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF2F2F2),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: () {
              final phone = card.phoneCtrl.text.trim();
              final msg = card.messageCtrl.text.trim();
              if (phone.isEmpty || msg.isEmpty) return;
              _sendWhatsAppTo(phone, msg);
              card.messageCtrl.clear();
            },
            icon: const Icon(Icons.send_rounded, size: 16),
            style: IconButton.styleFrom(backgroundColor: _whatsappGreen, foregroundColor: Colors.white),
          ),
        ]),
      ]),
    );
  }

  Widget _whatsAppPreviewChip(String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.chat, size: 14, color: _whatsappGreen),
      label: Text(label, style: const TextStyle(fontSize: 11, color: _whatsappGreen, fontWeight: FontWeight.bold)),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildHeader(int pendientesCount) {
    return Container(
      color: _gogoOrange,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(children: [
        SvgPicture.asset('assets/images/logo.svg', height: 38,
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
    'pending': ('Pendiente', Color(0xFFFFB300), Icons.schedule_rounded),
    'restaurant_accepted': ('Confirmado', _gogoBlue, Icons.check_circle_outline_rounded),
    'accepted': ('Repartidor asignado', _gogoOrange, Icons.two_wheeler_rounded),
    'delivering': ('En camino', _gogoBlue, Icons.delivery_dining_rounded),
    'delivered': ('Entregado', Colors.green, Icons.check_circle_rounded),
    'cancelled': ('Cancelado', Colors.red, Icons.cancel_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String? ?? 'pending';
    final (label, color, statusIcon) = _statusLabels[status] ?? ('Desconocido', Colors.grey, Icons.help_outline_rounded);
    final delivery = SupabaseService.parseDelivery(order['customer_name']);
    final name = delivery['name'] as String? ?? 'Cliente';
    final address = delivery['address'] as String? ?? '';
    final total = (order['total'] as num?)?.toDouble() ?? 0;
    final items = (order['order_items'] as List<dynamic>? ?? []);

    final cardBg = isDark ? const Color(0xFF1E1E1E) : _cardOrange;
    final textMain = Colors.white;
    final textMuted = isDark ? Colors.white54 : Colors.white70;
    final textBody = isDark ? Colors.white70 : Colors.white.withValues(alpha: 0.85);

    // Mini-resumen del proceso del pedido — mismos 4 pasos y mismos iconos
    // que ya usa la app del cliente en tracking_screen.dart (Recibido →
    // Preparando → En camino → Entregado). "Cancelado" no tiene un lugar en
    // esa línea (no es un paso, es que se salió del proceso), así que ahí
    // no se dibuja.
    final stage = switch (status) {
      'pending' => 0,
      'restaurant_accepted' || 'accepted' => 1,
      'delivering' => 2,
      'delivered' => 3,
      _ => -1,
    };

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
        Image.asset('assets/images/gogo_watermark.png', width: 100, fit: BoxFit.contain),
        const SizedBox(height: 8),
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
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(statusIcon, size: 11, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
            ]),
          ),
        ]),
        if (stage >= 0) ...[
          const SizedBox(height: 10),
          _buildMiniStepper(stage, textMuted),
        ],
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
            ElevatedButton(
              onPressed: onRechazar,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12)),
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

  // Mismos 4 pasos, mismos colores e iconos (SVG) que ya usa el stepper de
  // la app del cliente (tracking_screen.dart) — a propósito el mismo look,
  // para que el dueño/el de escritorio vean exactamente el mismo proceso
  // que ve el cliente en su celular.
  static const _stageInfo = [
    (Color(0xFFFFB300), 'assets/images/step_recibido.svg'),    // Recibido (pending)
    (_gogoOrange,       'assets/images/step_preparando.svg'),  // Preparando (restaurant_accepted/accepted)
    (_gogoBlue,         'assets/images/step_en_camino.svg'),   // En camino (delivering)
    (Colors.green,      'assets/images/step_entregado.svg'),   // Entregado
  ];

  Widget _buildMiniStepper(int stage, Color textMuted) {
    const labels = ['RECIBIDO', 'PREPARANDO', 'EN CAMINO', 'ENTREGADO'];

    Widget dot(int i) {
      final on = i <= stage;
      final (_, iconAsset) = _stageInfo[i];
      return Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: on ? _gogoBlue : Colors.white,
          shape: BoxShape.circle,
          // El círculo "todavía no llegado" siempre es blanco (sin importar
          // el tema de la tarjeta) — el icono y el borde de adentro van en
          // un gris fijo a propósito, no en textMuted (ese cambia según la
          // tarjeta y en las naranjas es blanco, quedando invisible sobre
          // este mismo círculo blanco).
          border: on ? null : Border.all(color: Colors.black26),
        ),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: SvgPicture.asset(
            iconAsset,
            colorFilter: ColorFilter.mode(on ? Colors.white : Colors.black38, BlendMode.srcIn),
          ),
        ),
      );
    }

    Widget line(int i) {
      final on = i <= stage;
      return Expanded(
        child: Container(height: 4, color: on ? _gogoBlue : textMuted.withValues(alpha: 0.2)),
      );
    }

    return Row(
      children: List.generate(4, (i) {
        final on = i <= stage;
        final (stageColor, _) = _stageInfo[i];
        return Expanded(
          child: Column(children: [
            Row(children: [
              if (i > 0) line(i) else const Spacer(),
              dot(i),
              if (i < 3) line(i + 1) else const Spacer(),
            ]),
            const SizedBox(height: 3),
            Text(labels[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  color: on ? stageColor : textMuted,
                )),
          ]),
        );
      }),
    );
  }
}
