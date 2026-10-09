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

  // Llama a todos los repartidores de flota en línea — el primero que
  // acepte se queda el pedido (ver respond_rider_call en la base, valida
  // del lado del servidor que solo uno pueda aceptar).
  static Future<String> callRider(String restaurantId, String restaurantName) async {
    final data = await _client.from('rider_calls').insert({
      'restaurant_id': restaurantId,
      'restaurant_name': restaurantName,
    }).select('id').single();
    return data['id'] as String;
  }

  static Future<Map<String, dynamic>?> getRiderCall(String callId) async {
    return await _client.from('rider_calls').select().eq('id', callId).maybeSingle();
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
