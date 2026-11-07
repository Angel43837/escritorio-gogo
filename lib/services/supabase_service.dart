import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

// Capa mínima de acceso a datos — solo lo que necesita esta app (pedidos de
// un restaurante). No es una copia del supabase_service.dart de GOGO Food,
// a propósito: esta app es aparte y solo hace una cosa.
class SupabaseService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<String?> signIn(String email, String password) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<void> signOut() => _client.auth.signOut();

  // El restaurante de esta cuenta dueño se guarda en user_metadata.restaurant_id
  // en la mayoría de las cuentas (mismo campo que ya usa la app de GOGO Food),
  // pero algunas cuentas viejas solo lo tienen en app_metadata — se revisan
  // los dos por si acaso.
  static String? getRestaurantId() {
    final user = _client.auth.currentUser;
    final fromUser = user?.userMetadata?['restaurant_id'] as String?;
    if (fromUser != null && fromUser.isNotEmpty) return fromUser;
    return user?.appMetadata['restaurant_id'] as String?;
  }

  static Future<String?> getRestaurantDisplayName(String restaurantId) async {
    final data = await _client
        .from('restaurants')
        .select('name')
        .eq('id', restaurantId)
        .maybeSingle();
    return data?['name'] as String?;
  }

  static Future<Map<String, dynamic>?> getRestaurantInfo(String restaurantId) async {
    final data = await _client
        .from('restaurants')
        .select('name, image_url')
        .eq('id', restaurantId)
        .maybeSingle();
    return data;
  }

  static Future<List<Map<String, dynamic>>> getOrders(String restaurantId) async {
    final data = await _client
        .from('orders')
        .select('*, order_items(quantity, price, notes, products(id, name))')
        .eq('restaurant_id', restaurantId)
        .inFilter('status', [
          'pending',
          'restaurant_accepted',
          'accepted',
          'delivering',
          'delivered',
          'cancelled',
        ])
        .order('created_at', ascending: false)
        .limit(100);
    return (data as List).cast<Map<String, dynamic>>();
  }

  static RealtimeChannel subscribeToOrders(String restaurantId, void Function() onUpdate) {
    final channel = _client.channel('desktop_orders_$restaurantId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'restaurant_id',
            value: restaurantId,
          ),
          callback: (_) => onUpdate(),
        )
        .subscribe();
    return channel;
  }

  // Confirma el pedido de parte del restaurante — a partir de aquí ya se
  // vuelve visible/tomable para repartidores (mismo flujo de 2 pasos que ya
  // usa la app de GOGO Food: primero confirma el restaurante, luego un
  // repartidor lo reclama).
  static Future<void> aceptarPedido(String orderId) async {
    await _client.from('orders').update({'status': 'restaurant_accepted'}).eq('id', orderId);
  }

  static Future<void> rechazarPedido(String orderId) async {
    await _client.from('orders').update({'status': 'cancelled'}).eq('id', orderId);
  }

  // Llama a todos los repartidores en línea — el primero que acepte se
  // queda el pedido (ver respond_rider_call en la base, valida del lado
  // del servidor que solo uno pueda aceptar). Ahora cobra $38 MXN ($3
  // cuota + $35 de envío para quien acepte) a la tarjeta guardada del
  // restaurante antes de crear la llamada — todo en un solo paso del lado
  // del servidor (ver restaurant-call-rider) para que nunca quede un
  // cobro sin llamada, ni una llamada sin cobro.
  static Future<String> callRider(String restaurantId, String restaurantName) async {
    try {
      final res = await _client.functions.invoke('restaurant-call-rider', body: {
        'restaurantId': restaurantId,
        'restaurantName': restaurantName,
      });
      final data = res.data as Map<String, dynamic>;
      return data['id'] as String;
    } catch (e) {
      throw Exception(_functionErrorMessage(e));
    }
  }

  static String _functionErrorMessage(Object e) {
    if (e is FunctionException) {
      final details = e.details;
      if (details is Map && details['error'] != null) return details['error'].toString();
      return e.reasonPhrase ?? 'Error de Stripe';
    }
    return e.toString();
  }

  static Future<Map<String, dynamic>?> getRiderCall(String callId) async {
    return await _client.from('rider_calls').select().eq('id', callId).maybeSingle();
  }

  // Si nadie acepta, el dueño puede desistir en vez de quedarse esperando
  // para siempre (ver cancel_rider_call en la base) — y ahora también se
  // le reembolsa de inmediato, sin esperar las 3h del reembolso automático.
  static Future<void> cancelRiderCall(String callId) async {
    await _client.rpc('cancel_rider_call', params: {'p_call_id': callId});
    try {
      await _client.functions.invoke('rider-call-expire-check', body: {'callId': callId});
    } catch (_) {}
  }

  // Marca la llamada como entregada — hasta aquí se queda cobrado de
  // verdad el restaurante y hasta aquí se suma al saldo retirable del
  // rider (ver mark_rider_call_delivered). Lo puede hacer el dueño desde
  // aquí o el propio rider desde su app.
  static Future<bool> markRiderCallDelivered(String callId) async {
    final res = await _client.rpc('mark_rider_call_delivered', params: {'p_call_id': callId});
    return res == true;
  }

  // ── Método de pago del restaurante (tarjeta guardada en Stripe) ────────────

  static Future<Map<String, dynamic>> getPaymentMethodStatus(String restaurantId) async {
    try {
      final res = await _client.functions.invoke('restaurant-payment-method', body: {
        'action': 'status',
        'restaurantId': restaurantId,
      });
      return res.data as Map<String, dynamic>;
    } catch (e) {
      throw Exception(_functionErrorMessage(e));
    }
  }

  static Future<String> startPaymentMethodSetup(String restaurantId) async {
    try {
      final res = await _client.functions.invoke('restaurant-payment-method', body: {
        'action': 'setup',
        'restaurantId': restaurantId,
      });
      final data = res.data as Map<String, dynamic>;
      return data['url'] as String;
    } catch (e) {
      throw Exception(_functionErrorMessage(e));
    }
  }

  static RealtimeChannel subscribeToRiderCall(String callId, void Function() onUpdate) {
    final channel = _client.channel('rider_call_$callId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rider_calls',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: callId),
          callback: (_) => onUpdate(),
        )
        .subscribe();
    return channel;
  }

  static Map<String, dynamic> parseDelivery(dynamic customerNameField) {
    try {
      return jsonDecode(customerNameField as String? ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
