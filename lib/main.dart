import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

const Duration kHoldDuration = Duration(hours: 24);
const int kSpoilRate = 1;
const double kPointRadius = 50;
const int kBurnRate = 10;

class Streamer {
  final String name, platform, channel, password;
  final int minDonation;
  Streamer({required this.name, required this.platform, required this.channel, this.minDonation = 0, this.password = ''});
  
  String get qrData {
    String base = 'https://streamer-map-donate.app';
    if (Uri.base.scheme == 'http' || Uri.base.scheme == 'https') {
      base = Uri.base.origin;
    }
    return '$base/?streamer=${Uri.encodeComponent(name)}';
  }
}

class DonationPoint {
  String? id;
  LatLng position;
  String title;
  int totalAmount;
  DateTime lastTopUp;
  DateTime? zeroedAt;
  List<String> donors;

  DonationPoint({
    this.id,
    required this.position,
    required this.title,
    this.totalAmount = 0,
    DateTime? lastTopUp,
    this.zeroedAt,
    List<String>? donors,
  }) : lastTopUp = lastTopUp ?? DateTime.now(), donors = donors ?? [];

  bool get isSpoiled => DateTime.now().difference(lastTopUp) > kHoldDuration;

  int get currentAmount {
    final now = DateTime.now();
    final holdEnd = lastTopUp.add(kHoldDuration);
    if (now.isBefore(holdEnd)) return totalAmount;
    final secondsOver = now.difference(holdEnd).inSeconds;
    final burned = secondsOver * kSpoilRate;
    final remaining = totalAmount - burned;
    return remaining > 0 ? remaining : 0;
  }

  // Возвращаем случайно удаленный геттер
  Duration get timeToSpoil {
    final left = kHoldDuration - DateTime.now().difference(lastTopUp);
    return left.isNegative ? Duration.zero : left;
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title, 'totalAmount': totalAmount, 'latitude': position.latitude,
      'longitude': position.longitude, 'donors': donors, 'lastTopUp': lastTopUp.toIso8601String(),
    };
  }

  factory DonationPoint.fromMap(Map<String, dynamic> map, String docId) {
    return DonationPoint(
      id: docId, title: map['title'] ?? 'Без названия', totalAmount: map['totalAmount'] ?? 0,
      position: LatLng(map['latitude'] ?? 0.0, map['longitude'] ?? 0.0),
      donors: List<String>.from(map['donors'] ?? []), lastTopUp: DateTime.parse(map['lastTopUp'] ?? DateTime.now().toIso8601String()),
    );
  }
}

class LiveDonation {
  final String donorName, pointTitle;
  final int amount;
  final DateTime time;
  final String message;
  final LatLng? position;
  
  LiveDonation({required this.donorName, required this.pointTitle, required this.amount, required this.time, this.message = '', this.position});

  Map<String, dynamic> toMap() {
    return {
      'donorName': donorName, 'pointTitle': pointTitle, 'amount': amount,
      'time': time.toIso8601String(), 'message': message,
      'latitude': position?.latitude, 'longitude': position?.longitude,
    };
  }

  factory LiveDonation.fromMap(Map<String, dynamic> map) {
    return LiveDonation(
      donorName: map['donorName'] ?? 'Аноним', pointTitle: map['pointTitle'] ?? 'Неизвестно',
      amount: map['amount'] ?? 0, time: DateTime.parse(map['time'] ?? DateTime.now().toIso8601String()),
      message: map['message'] ?? '', position: map['latitude'] != null ? LatLng(map['latitude'], map['longitude']) : null,
    );
  }
}

class EarningRecord {
  final String title;
  int amount;
  final DateTime time;
  final bool isWithdrawal;
  int seconds;
  EarningRecord({required this.title, required this.amount, required this.time, this.isWithdrawal = false, this.seconds = 1});
}

final List<Streamer> allStreamers = [
  Streamer(name: 'StreamerX', platform: 'Twitch', channel: 'twitch.tv/streamerx', password: '123'),
  Streamer(name: 'GamerPro', platform: 'YouTube', channel: 'youtube.com/@gamerpro', password: '123'),
];

final Map<String, List<DonationPoint>> streamerPoints = {};
final Map<String, int> streamerWallet = {'StreamerX': 500, 'GamerPro': 0};
final Map<String, List<EarningRecord>> streamerHistory = {};
final Map<String, List<LiveDonation>> streamerFeed = {};

int appBalance = 0;

Future<void> uploadPointToCloud(String streamerName, DonationPoint p) async {
  try { await FirebaseFirestore.instance.collection('points').add({...p.toMap(), 'streamerName': streamerName}); } catch (e) {}
}
Future<void> deletePointFromCloud(String docId) async {
  try { await FirebaseFirestore.instance.collection('points').doc(docId).delete(); } catch (e) {}
}
Future<void> uploadDonationToCloud(String streamerName, LiveDonation d) async {
  try { await FirebaseFirestore.instance.collection('donations').add({...d.toMap(), 'streamerName': streamerName}); } catch (e) {}
}

List<StreamSubscription> getRealtimeListeners(String streamerName, void Function() onUpdate) {
  if (Firebase.apps.isEmpty) {
    print('Firebase НЕ ЗАПУЩЕН! Работаем в локальном режиме.');
    return [];
  }
  final pointsSub = FirebaseFirestore.instance.collection('points').where('streamerName', isEqualTo: streamerName).snapshots().listen((snapshot) {
    final cloudPoints = snapshot.docs.map((doc) => DonationPoint.fromMap(doc.data(), doc.id)).toList();
    streamerPoints[streamerName] = cloudPoints; onUpdate();
  });
  final donationsSub = FirebaseFirestore.instance.collection('donations').where('streamerName', isEqualTo: streamerName).snapshots().listen((snapshot) {
    final cloudDonations = snapshot.docs.map((doc) => LiveDonation.fromMap(doc.data())).toList();
    cloudDonations.sort((a, b) => b.time.compareTo(a.time));
    streamerFeed[streamerName] = cloudDonations; onUpdate();
  });
  return [pointsSub, donationsSub];
}

Color nameColor(String name) {
  const colors = [Color(0xFFFF4500), Color(0xFF1E90FF), Color(0xFF00BFFF), Color(0xFF32CD32), Color(0xFFFFD700), Color(0xFF9370DB), Color(0xFF00CED1), Color(0xFFFF69B4), Color(0xFFFF6347), Color(0xFFDA70D6)];
  return colors[name.hashCode.abs() % colors.length];
}
String pointsWord(int n) { if (n % 10 == 1 && n % 100 != 11) return 'точка'; if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) return 'точки'; return 'точек'; }
String donorsWord(int n) { if (n % 10 == 1 && n % 100 != 11) return 'донатер'; if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) return 'донатера'; return 'донатеров'; }

Future<String> getLocationName(LatLng pos) async {
  try {
    final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=${pos.latitude}&lon=${pos.longitude}&zoom=18&accept-language=ru');
    final res = await http.get(url, headers: {'User-Agent': 'StreamerMapDonate/1.0'});
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final a = data['address'] as Map<String, dynamic>?;
    if (a != null) { final name = a['road'] ?? a['pedestrian'] ?? a['park'] ?? a['neighbourhood'] ?? a['suburb'] ?? a['city_district'] ?? a['city']; if (name != null) return name.toString(); }
    return 'Донат';
  } catch (e) { return 'Донат'; }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Заменяем серый экран на текст ошибки
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              'ОШИБКА ПРИЛОЖЕНИЯ:\n${details.exceptionAsString()}',
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  };

  try { await Firebase.initializeApp(); } catch (e) { print('FIREBASE ERROR: $e'); }
  final params = Uri.base.queryParameters;
  runApp(StreamerMapApp(initialStreamerName: params['streamer']));
}

class StreamerMapApp extends StatelessWidget {
  final String? initialStreamerName;
  const StreamerMapApp({super.key, this.initialStreamerName});
  @override
  Widget build(BuildContext context) {
    Widget home = const RoleSelectionScreen();
    if (initialStreamerName != null) {
      final found = allStreamers.where((s) => s.name == initialStreamerName).toList();
      home = found.isNotEmpty ? DonaterMapScreen(streamer: found.first) : const StreamerListScreen();
    }
    return MaterialApp(
      title: 'Квест донат', debugShowCheckedModeBanner: false,
      theme: ThemeData(primaryColor: const Color(0xFF2AABEE), scaffoldBackgroundColor: const Color(0xFFF0F2F5), colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2AABEE), primary: const Color(0xFF2AABEE), surface: Colors.white), useMaterial3: true),
      home: home,
    );
  }
}

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), body: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 100, height: 100, decoration: BoxDecoration(color: const Color(0xFF2AABEE), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF2AABEE).withOpacity(0.35), blurRadius: 20, offset: const Offset(0, 8))]), child: const Icon(Icons.location_on, color: Colors.white, size: 55)),
        const SizedBox(height: 28), const Text('Квест донат', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
        const Text('Выберите свою роль', style: TextStyle(fontSize: 15, color: Colors.grey)), const SizedBox(height: 48),
        _card(context, 'Я стример', 'Войти или зарегистрироваться', Icons.videocam, const Color(0xFF2AABEE), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerAuthScreen()))),
        const SizedBox(height: 16),
        _card(context, 'Я донатер', 'Выберите стримера и скиньте донат', Icons.favorite, const Color(0xFFE5875B), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerListScreen()))),
      ]))),
    );
  }
  Widget _card(BuildContext context, String t, String s, IconData i, Color c, VoidCallback tap) {
    return Material(color: Colors.white, borderRadius: BorderRadius.circular(20), child: InkWell(borderRadius: BorderRadius.circular(20), onTap: tap,
      child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [
        Container(width: 56, height: 56, decoration: BoxDecoration(color: c.withOpacity(0.12), shape: BoxShape.circle), child: Icon(i, color: c, size: 28)), const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)), const SizedBox(height: 4), Text(s, style: const TextStyle(fontSize: 13, color: Colors.grey))])),
        const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 16),
      ]))));
  }
}

class StreamerAuthScreen extends StatelessWidget {
  const StreamerAuthScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87, title: const Text('Вход для стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const SizedBox(height: 20), Container(width: 100, height: 100, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.12), shape: BoxShape.circle), child: const Icon(Icons.videocam, color: Color(0xFF2AABEE), size: 55)),
        const SizedBox(height: 24), const Text('Вы уже зарегистрированы?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 40),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerLoginScreen())), icon: const Icon(Icons.login), label: const Text('Войти', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerRegistrationScreen())), icon: const Icon(Icons.person_add), label: const Text('Зарегистрироваться', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF2AABEE), side: const BorderSide(color: Color(0xFF2AABEE), width: 1.5), padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
      ]))),
    );
  }
}

class StreamerLoginScreen extends StatefulWidget {
  const StreamerLoginScreen({super.key});
  @override
  State<StreamerLoginScreen> createState() => _StreamerLoginScreenState();
}

class _StreamerLoginScreenState extends State<StreamerLoginScreen> {
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  void _login() {
    final name = _nameController.text.trim(); final pass = _passwordController.text.trim();
    if (name.isEmpty || pass.isEmpty) { _showError('Введите ник и пароль'); return; }
    final found = allStreamers.where((s) => s.name.toLowerCase() == name.toLowerCase()).toList();
    if (found.isNotEmpty) { if (found.first.password == pass) { Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => StreamerDashboardScreen(streamer: found.first))); } else { _showError('Неверный пароль'); } } else { _showError('Стример с таким ником не найден'); }
  }
  void _showError(String msg) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg, style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red)); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87, title: const Text('Вход', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const SizedBox(height: 20), Container(width: 100, height: 100, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.12), shape: BoxShape.circle), child: const Icon(Icons.person, color: Color(0xFF2AABEE), size: 55)),
        const SizedBox(height: 24), TextField(controller: _nameController, decoration: _dec('Ваш ник')), const SizedBox(height: 12), TextField(controller: _passwordController, obscureText: true, decoration: _dec('Пароль')), const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _login, icon: const Icon(Icons.login), label: const Text('Войти', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
      ])))),
    );
  }
  InputDecoration _dec(String h) => InputDecoration(hintText: h, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));
}

class StreamerRegistrationScreen extends StatefulWidget {
  const StreamerRegistrationScreen({super.key});
  @override
  State<StreamerRegistrationScreen> createState() => _RegState();
}

class _RegState extends State<StreamerRegistrationScreen> {
  final _name = TextEditingController();
  final _ch = TextEditingController();
  final _pass = TextEditingController();
  final _min = TextEditingController(text: '0');
  bool _ok = false;
  String _plat = 'Twitch';

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87, title: const Text('Регистрация стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 100, height: 100, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.15), shape: BoxShape.circle), child: const Icon(Icons.person, size: 55, color: Color(0xFF2AABEE)))), const SizedBox(height: 24),
        const Text('Имя / ник', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 8), TextField(controller: _name, decoration: _dec('Например, StreamerX')), const SizedBox(height: 16),
        const Text('Пароль', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 8), TextField(controller: _pass, obscureText: true, decoration: _dec('Придумайте пароль')), const SizedBox(height: 16),
        const Text('Платформа', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)), child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: _plat, isExpanded: true, items: ['Twitch', 'YouTube', 'VK Play', 'Kick'].map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(), onChanged: (v) => setState(() => _plat = v!)))),
        const SizedBox(height: 16), const Text('Ссылка на канал', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 8), TextField(controller: _ch, decoration: _dec('twitch.tv/your_channel')), const SizedBox(height: 24),
        Material(color: Colors.white, borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => setState(() => _ok = !_ok), child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
          Container(width: 24, height: 24, decoration: BoxDecoration(color: _ok ? const Color(0xFF2AABEE) : Colors.transparent, border: Border.all(color: _ok ? const Color(0xFF2AABEE) : Colors.grey.shade400, width: 2), borderRadius: BorderRadius.circular(6)), child: _ok ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
          const SizedBox(width: 12), const Expanded(child: Text('Я подтверждаю, что этот канал принадлежит мне', style: TextStyle(fontSize: 13.5))),
        ])))),
        const SizedBox(height: 24), SizedBox(width: double.infinity, child: ElevatedButton(onPressed: (_ok && _name.text.isNotEmpty && _ch.text.isNotEmpty) ? () {
          final s = Streamer(name: _name.text, platform: _plat, channel: _ch.text, minDonation: int.tryParse(_min.text.trim()) ?? 0, password: _pass.text);
          allStreamers.add(s); Navigator.push(context, MaterialPageRoute(builder: (_) => StreamerQRCodeScreen(streamer: s)));
        } : null, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, disabledBackgroundColor: Colors.grey.shade300, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), child: const Text('Продолжить', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))),
      ]))),
    );
  }
  InputDecoration _dec(String h) => InputDecoration(hintText: h, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));
}

class StreamerQRCodeScreen extends StatelessWidget {
  final Streamer streamer;
  const StreamerQRCodeScreen({super.key, required this.streamer});
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: const Text('Ваш QR-код', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(children: [
        const SizedBox(height: 16), const Text('Готово! Канал подтверждён', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 32),
        Container(color: Colors.white, padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 200, height: 200, child: FutureBuilder<Widget>(future: Future.microtask(() => PrettyQrView.data(data: streamer.qrData, decoration: const PrettyQrDecoration(shape: PrettyQrSmoothSymbol(color: Colors.black)))), builder: (context, snapshot) {
              if (snapshot.hasData) return snapshot.data!; if (snapshot.hasError) return const Icon(Icons.qr_code_2, size: 200, color: Colors.grey); return const Center(child: CircularProgressIndicator(color: Color(0xFF2AABEE)));
          })),
          const SizedBox(height: 16), Text(streamer.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), Text('${streamer.platform} • ${streamer.channel}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ])),
        const Spacer(), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => StreamerDashboardScreen(streamer: streamer))), icon: const Icon(Icons.map), label: const Text('Квест', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
        const SizedBox(height: 16),
      ]))),
    );
  }
}

class LiveFeedScreen extends StatefulWidget {
  final Streamer streamer;
  const LiveFeedScreen({super.key, required this.streamer});
  @override
  State<LiveFeedScreen> createState() => _LiveFeedScreenState();
}

class _LiveFeedScreenState extends State<LiveFeedScreen> {
  List<StreamSubscription> _subs = [];
  @override
  void initState() { super.initState(); _subs = getRealtimeListeners(widget.streamer.name, () { if (mounted) setState(() {}); }); }
  @override
  void dispose() { for (var sub in _subs) { sub.cancel(); } super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final feed = streamerFeed[widget.streamer.name] ?? [];
    final Map<String, List<LiveDonation>> byPoint = {};
    for (final d in feed) { byPoint.putIfAbsent(d.pointTitle, () => []).add(d); }
    final points = byPoint.entries.toList()..sort((a, b) { final sumA = a.value.fold<int>(0, (s, x) => s + x.amount); final sumB = b.value.fold<int>(0, (s, x) => s + x.amount); return sumB.compareTo(sumA); });
    
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: Row(children: [Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)), const SizedBox(width: 8), const Text('LIVE — донаты', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))])),
      body: feed.isEmpty 
        ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.inbox, size: 60, color: Colors.grey), SizedBox(height: 16), Text('Пока нет донатов', style: TextStyle(fontSize: 16, color: Colors.grey))])) 
        : ListView.builder(
            padding: const EdgeInsets.all(12), 
            itemCount: points.length, 
            itemBuilder: (ctx, i) {
              final title = points[i].key; 
              final donations = points[i].value; 
              final sum = donations.fold<int>(0, (s, x) => s + x.amount);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8), 
                child: Material(
                  color: Colors.white, 
                  borderRadius: BorderRadius.circular(14), 
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14), 
                    onTap: () async {
                      final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => PointDetailsScreen(streamer: widget.streamer, pointTitle: title)));
                      if (result != null && mounted) {
                        Navigator.pop(context, result); // Возвращаем координаты на карту
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(14), 
                      child: Row(children: [
                        Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.1), shape: BoxShape.circle), child: const Icon(Icons.location_on, color: Color(0xFF2AABEE), size: 22)), 
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), overflow: TextOverflow.ellipsis), const SizedBox(height: 2), Text('${donations.length} ${donorsWord(donations.length)}', style: const TextStyle(fontSize: 12, color: Colors.grey))])),
                        Text('$sum ₽', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF2AABEE))), 
                        const SizedBox(width: 2), 
                        const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
                      ]),
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

class PointDetailsScreen extends StatefulWidget {
  final Streamer streamer;
  final String pointTitle;
  const PointDetailsScreen({super.key, required this.streamer, required this.pointTitle});
  @override
  State<PointDetailsScreen> createState() => _PointDetailsScreenState();
}

class _PointDetailsScreenState extends State<PointDetailsScreen> {
  List<StreamSubscription> _subs = [];
  @override
  void initState() { super.initState(); _subs = getRealtimeListeners(widget.streamer.name, () { if (mounted) setState(() {}); }); }
  @override
  void dispose() { for (var sub in _subs) { sub.cancel(); } super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final feed = streamerFeed[widget.streamer.name] ?? [];
    final donations = feed.where((d) => d.pointTitle == widget.pointTitle).toList()..sort((a, b) => b.amount.compareTo(a.amount));
    final total = donations.fold<int>(0, (s, x) => s + x.amount);
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: Text(widget.pointTitle, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18), overflow: TextOverflow.ellipsis)),
      body: Column(children: [
        Container(width: double.infinity, margin: const EdgeInsets.all(12), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))]),
          child: Row(children: [const Icon(Icons.savings, color: Color(0xFF2AABEE), size: 22), const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Всего собрано', style: TextStyle(fontSize: 11, color: Colors.grey)), Text('$total ₽', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.black87))]), const Spacer(), Text('${donations.length} ${donorsWord(donations.length)}', style: const TextStyle(fontSize: 12, color: Colors.grey))])),
        Expanded(child: donations.isEmpty ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.chat_bubble_outline, size: 60, color: Colors.grey), SizedBox(height: 16), Text('Пока нет донатов', style: TextStyle(fontSize: 16, color: Colors.grey))])) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), itemCount: donations.length, itemBuilder: (ctx, i) {
          final d = donations[i];
          return Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Flexible(child: Text(d.donorName, style: TextStyle(color: nameColor(d.donorName), fontWeight: FontWeight.w700, fontSize: 14), overflow: TextOverflow.ellipsis)), const SizedBox(width: 6), Text(_ago(d.time), style: const TextStyle(fontSize: 11, color: Colors.grey))]), if (d.message.isNotEmpty) ...[const SizedBox(height: 2), Text(d.message, style: const TextStyle(fontSize: 13.5, color: Colors.black87, height: 1.3))]])),
            const SizedBox(width: 8), Text('+${d.amount} ₽', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF2AABEE))),
          ]));
        })),
      ]),
    );
  }
  String _ago(DateTime t) { final d = DateTime.now().difference(t); if (d.inSeconds < 60) return 'только что'; if (d.inMinutes < 60) return '${d.inMinutes} мин назад'; if (d.inHours < 24) return '${d.inHours} ч назад'; return '${d.inDays} дн назад'; }
}

class StreamerDashboardScreen extends StatefulWidget {
  final Streamer streamer;
  const StreamerDashboardScreen({super.key, required this.streamer});
  @override
  State<StreamerDashboardScreen> createState() => _DashState();
}

class _DashState extends State<StreamerDashboardScreen> {
  DonationPoint? _selectedPoint;
  DonationPoint? _miningPoint;
  bool _isShiftActive = false;
  Position? _myPos;
  StreamSubscription<Position>? _sub;
  Timer? _miningTimer;
  Timer? _spoilTimer;
  int _earnedNow = 0;
  int _spoiledIdx = 0;
  final MapController _mapCtrl = MapController();
  List<StreamSubscription> _fbSubs = [];

  List<DonationPoint> get points { streamerPoints.putIfAbsent(widget.streamer.name, () => []); return streamerPoints[widget.streamer.name]!; }
  int get totalEarned => points.fold(0, (s, p) => s + p.currentAmount);
  int get walletBalance => streamerWallet[widget.streamer.name] ?? 0;
  int get spoiledTotal => points.where((p) => p.isSpoiled).length;

  @override
  void initState() {
    super.initState(); _fbSubs = getRealtimeListeners(widget.streamer.name, () { if (mounted) setState(() {}); });
    _spoilTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return; bool changed = false; final toRemove = <DonationPoint>[];
      for (final p in points) { if (p.isSpoiled && p.currentAmount > 0) changed = true; if (p.currentAmount == 0) { p.zeroedAt ??= DateTime.now(); if (DateTime.now().difference(p.zeroedAt!) > const Duration(seconds: 5)) { toRemove.add(p); } } else { p.zeroedAt = null; } }
      if (toRemove.isNotEmpty) { for (var p in toRemove) { points.remove(p); if (p.id != null) deletePointFromCloud(p.id!); } changed = true; }
      if (changed) setState(() {});
    });
  }

  @override
  void dispose() { for (var s in _fbSubs) { s.cancel(); } _sub?.cancel(); _miningTimer?.cancel(); _spoilTimer?.cancel(); super.dispose(); }

  Future<void> _toggleShift() async {
    try {
      if (_isShiftActive) {
        await _sub?.cancel();
        _miningTimer?.cancel();
        setState(() { _isShiftActive = false; _miningPoint = null; });
        _snack('Квест остановлен', Colors.grey.shade700);
        return;
      }

      bool serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) {
        _snack('Включите геолокацию на телефоне!', Colors.red);
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _snack('Нет разрешения на GPS. Разрешите в настройках!', Colors.red);
        return;
      }

      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((pos) {
        setState(() => _myPos = pos);
        _checkPoints(pos);
      });

      setState(() => _isShiftActive = true);
      _snack('Квест начат! Ищем точки...', const Color(0xFF2AABEE));
    } catch (e) {
      _snack('Ошибка GPS: $e', Colors.red);
    }
  }

  void _checkPoints(Position pos) {
    const dist = Distance(); final me = LatLng(pos.latitude, pos.longitude); DonationPoint? nearest; double nd = double.infinity;
    for (final p in points) { final d = dist.as(LengthUnit.Meter, me, p.position); if (d < kPointRadius && d < nd) { nearest = p; nd = d; } }
    if (nearest != _miningPoint) { _miningTimer?.cancel(); setState(() => _miningPoint = nearest); if (nearest != null && nearest.currentAmount > 0) _startMining(nearest); }
  }

  void _startMining(DonationPoint point) {
    _miningTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final current = point.currentAmount; if (current <= 0) { t.cancel(); setState(() => _miningPoint = null); return; }
      final burn = current < kBurnRate ? current : kBurnRate;
      setState(() {
        point.totalAmount = current - burn; point.lastTopUp = DateTime.now(); _earnedNow += burn; streamerWallet[widget.streamer.name] = (streamerWallet[widget.streamer.name] ?? 0) + burn;
        streamerHistory.putIfAbsent(widget.streamer.name, () => []);
        if (streamerHistory[widget.streamer.name]!.isNotEmpty && streamerHistory[widget.streamer.name]!.first.title == point.title && DateTime.now().difference(streamerHistory[widget.streamer.name]!.first.time).inSeconds < 15) { streamerHistory[widget.streamer.name]!.first.amount += burn; streamerHistory[widget.streamer.name]!.first.seconds += 1; } else { streamerHistory[widget.streamer.name]!.insert(0, EarningRecord(title: point.title, amount: burn, time: DateTime.now())); }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      FlutterMap(mapController: _mapCtrl, options: MapOptions(
        initialCenter: _myPos != null ? LatLng(_myPos!.latitude, _myPos!.longitude) : const LatLng(56.0184, 92.8672),
        initialZoom: 13, minZoom: 4.0, maxZoom: 19.0,
        onTap: (pos, latlng) { if (_selectedPoint != null) setState(() => _selectedPoint = null); }),
        children: [
          TileLayer(
            urlTemplate: 'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c'],
            userAgentPackageName: 'ru.dimamasss.streamermapdonate',
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
          MarkerLayer(markers: points.map((p) => Marker(point: p.position, width: 120, height: 140, child: GestureDetector(onTap: () => setState(() => _selectedPoint = p), child: _goldCoin(p)))).toList()),
          if (_myPos != null) MarkerLayer(markers: [Marker(point: LatLng(_myPos!.latitude, _myPos!.longitude), width: 40, height: 40, child: Container(decoration: BoxDecoration(color: const Color(0xFF2AABEE), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: const Color(0xFF2AABEE).withOpacity(0.6), blurRadius: 12, spreadRadius: 4)])))]),
        ],
      ),
      SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 0), child: Container(
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.95), borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: const Offset(0, 4))]),
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            _circleBtn(Icons.arrow_back, () => Navigator.pop(context)), const SizedBox(width: 8),
            Expanded(child: Row(children: [CircleAvatar(radius: 18, backgroundColor: const Color(0xFF2AABEE), child: Text(widget.streamer.name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.streamer.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black87), overflow: TextOverflow.ellipsis), Text('стример', style: TextStyle(fontSize: 11, color: Colors.grey.shade500))]))])),
            GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveFeedScreen(streamer: widget.streamer))), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(20)), child: Row(children: [Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)), const SizedBox(width: 6), const Text('LIVE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 11))]))),
            const SizedBox(width: 6), _circleBtn(Icons.history, () => Navigator.push(context, MaterialPageRoute(builder: (_) => EarningsHistoryScreen(streamer: widget.streamer))).then((_) => setState(() {}))),
          ]),
          const SizedBox(height: 10), Container(height: 1, color: Colors.grey.shade200), const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Всего на донатах', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              Row(children: [Text('$totalEarned ₽', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.black87)), if (_earnedNow > 0) ...[const SizedBox(width: 6), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: const Color(0xFF2AABEE), borderRadius: BorderRadius.circular(20)), child: Text('+$_earnedNow', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))] ]),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Кошелёк', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)), Text('$walletBalance ₽', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.black87))])),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: walletBalance > 0 ? () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => WithdrawScreen(streamer: widget.streamer))); setState(() {}); } : null, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, disabledBackgroundColor: Colors.grey.shade300, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Вывести', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          ]),
          if (points.isNotEmpty) ...[
            const SizedBox(height: 9),
            GestureDetector(onTap: () { final hot = points.where((p) => p.isSpoiled).toList()..sort((a, b) => b.currentAmount.compareTo(a.currentAmount)); final warm = points.where((p) => !p.isSpoiled).toList()..sort((a, b) => b.currentAmount.compareTo(a.currentAmount)); final order = [...hot, ...warm]; if (order.isEmpty) return; if (_spoiledIdx >= order.length) _spoiledIdx = 0; final target = order[_spoiledIdx]; _mapCtrl.move(target.position, 16); setState(() => _selectedPoint = target); _spoiledIdx++; },
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: spoiledTotal > 0 ? Colors.red.withOpacity(0.08) : const Color(0xFF2AABEE).withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: spoiledTotal > 0 ? Colors.red.withOpacity(0.25) : const Color(0xFF2AABEE).withOpacity(0.25), width: 1)),
                child: Row(children: [Icon(spoiledTotal > 0 ? Icons.local_fire_department : Icons.location_on, color: spoiledTotal > 0 ? Colors.red : const Color(0xFF2AABEE), size: 18), const SizedBox(width: 8), Expanded(child: Text(spoiledTotal > 0 ? _spoiledText(spoiledTotal) : '${points.length} ${pointsWord(points.length)}', style: TextStyle(color: spoiledTotal > 0 ? Colors.red : const Color(0xFF2AABEE), fontWeight: FontWeight.w600, fontSize: 12.5))), const Icon(Icons.touch_app, color: Colors.black54, size: 14), const SizedBox(width: 4), const Text('следующая', style: TextStyle(color: Colors.black54, fontSize: 11.5, fontWeight: FontWeight.w500))]),
              )),
          ],
        ]),
      ))),
      if (_miningPoint != null && _isShiftActive) Positioned(left: 20, right: 20, bottom: _selectedPoint != null ? 340 : 110, child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20)]),
        child: Row(children: [Container(width: 44, height: 44, decoration: const BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1])), child: const Icon(Icons.attach_money, color: Color(0xFF4A3200))), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_miningPoint!.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)), Text('+$kBurnRate ₽/сек · осталось ${_miningPoint!.currentAmount} ₽', style: const TextStyle(color: Colors.white70, fontSize: 12))])), const Icon(Icons.bolt, color: Color(0xFFFFD700), size: 28)]))),
      Positioned(left: 20, right: 20, bottom: _selectedPoint != null ? 20 : 30, child: ElevatedButton.icon(onPressed: _toggleShift, icon: Icon(_isShiftActive ? Icons.stop_circle : Icons.play_circle_filled), label: Text(_isShiftActive ? 'Остановить квест' : 'Начать квест', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: _isShiftActive ? Colors.red.shade400 : const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 6, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
      if (_selectedPoint != null) Positioned(left: 0, right: 0, bottom: 0, child: _infoPanel(_selectedPoint!)),
    ]));
  }

  Widget _circleBtn(IconData i, VoidCallback tap) => Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]), child: IconButton(icon: Icon(i, color: Colors.black87), onPressed: tap));
  Widget _goldCoin(DonationPoint p) { final isSpoiled = p.isSpoiled; final isMining = p == _miningPoint; final isHot = p.currentAmount >= 1000; return Column(mainAxisSize: MainAxisSize.min, children: [Container(width: isHot ? 72 : 62, height: isHot ? 72 : 62, decoration: BoxDecoration(shape: BoxShape.circle, gradient: isSpoiled ? const RadialGradient(colors: [Color(0xFFFFAAAA), Color(0xFFE53935), Color(0xFF8B0000)], stops: [0, 0.6, 1]) : const RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1]), border: Border.all(color: isMining ? const Color(0xFF2AABEE) : (isSpoiled ? Colors.white : const Color(0xFFFFF8DC)), width: isMining ? 4 : 3), boxShadow: [BoxShadow(color: isSpoiled ? Colors.red.withOpacity(0.8) : const Color(0xFFFFD700).withOpacity(isMining ? 1 : (isHot ? 0.8 : 0.5)), blurRadius: isMining ? 25 : (isSpoiled ? 20 : (isHot ? 18 : 10)), spreadRadius: isMining ? 6 : (isHot ? 4 : 1)), BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3))]), child: Center(child: Text(_fmt(p.currentAmount), style: TextStyle(color: isSpoiled ? Colors.white : const Color(0xFF4A3200), fontWeight: FontWeight.w900, fontSize: isHot ? 14 : 13)))), const SizedBox(height: 2), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isSpoiled ? Colors.red.withOpacity(0.75) : const Color(0xFF2AABEE).withOpacity(0.75), borderRadius: BorderRadius.circular(8)), child: Text(isSpoiled ? '${p.title} · −$kSpoilRate₽/сек' : p.title, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)))]); }
  String _fmt(int a) { if (a >= 1000) { final v = a / 1000; return v == v.roundToDouble() ? '${v.toInt()}к' : '${v.toStringAsFixed(1)}к'; } return '$a'; }
  String _spoiledText(int n) { final word = (n % 10 == 1 && n % 100 != 11) ? 'донат сгорает' : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) ? 'доната сгорают' : 'донатов сгорают'; return '$n $word'; }
  String _fmtDur(Duration d) { if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин'; if (d.inMinutes > 0) return '${d.inMinutes} мин'; return '${d.inSeconds} сек'; }

  Widget _infoPanel(DonationPoint p) {
    final tts = p.timeToSpoil; final spoiled = p.isSpoiled; final mainColor = spoiled ? Colors.red : const Color(0xFFB8860B);
    final pointDonations = (streamerFeed[widget.streamer.name] ?? []).where((d) => d.pointTitle == p.title).take(3).toList();
    return Container(decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18))), padding: const EdgeInsets.fromLTRB(16, 5, 16, 10),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 34, height: 3, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 4),
        Row(children: [Expanded(child: Text(p.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))), GestureDetector(onTap: () => setState(() => _selectedPoint = null), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, color: Colors.grey, size: 18)))]), const SizedBox(height: 4),
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: mainColor.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: mainColor.withOpacity(0.3), width: 1)),
          child: Row(children: [Icon(spoiled ? Icons.local_fire_department : Icons.monetization_on, color: mainColor, size: 18), const SizedBox(width: 8), Expanded(child: Row(children: [Text('${p.currentAmount} ₽', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: mainColor)), const SizedBox(width: 8), Flexible(child: Text(spoiled ? '· −$kSpoilRate ₽/сек' : '· ещё ${_fmtDur(tts)}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: spoiled ? Colors.red : const Color(0xFF2AABEE)), overflow: TextOverflow.ellipsis))])), Text('${p.donors.length} ${donorsWord(p.donors.length)}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: mainColor))])),
        if (pointDonations.isNotEmpty) ...[const SizedBox(height: 10), const Text('Последние донаты:', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)), const SizedBox(height: 4), ...pointDonations.map((d) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${d.donorName}: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: nameColor(d.donorName))), Expanded(child: Text(d.message.isNotEmpty ? d.message : '+${d.amount} ₽', style: const TextStyle(fontSize: 12, color: Colors.black87), maxLines: 1, overflow: TextOverflow.ellipsis))])))],
      ]),
    );
  }
  void _snack(String t, Color c) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)), backgroundColor: c, behavior: SnackBarBehavior.floating, margin: const EdgeInsets.fromLTRB(60, 0, 60, 200), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)))); }
}

class EarningsHistoryScreen extends StatelessWidget {
  final Streamer streamer;
  const EarningsHistoryScreen({super.key, required this.streamer});
  @override
  Widget build(BuildContext context) {
    final history = streamerHistory[streamer.name] ?? [];
    final total = history.where((r) => !r.isWithdrawal).fold(0, (s, r) => s + r.amount);
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: const Text('История заработка', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: Column(children: [
        Container(width: double.infinity, margin: const EdgeInsets.all(12), padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Всего заработано', style: TextStyle(fontSize: 12, color: Colors.grey)), const SizedBox(height: 2), Text('$total ₽', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.black87))])),
        Expanded(child: history.isEmpty ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.receipt_long, size: 60, color: Colors.grey), SizedBox(height: 16), Text('Пока нет операций', style: TextStyle(fontSize: 16, color: Colors.grey))])) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 12), itemCount: history.length, itemBuilder: (ctx, i) {
          final r = history[i];
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: Material(color: Colors.white, borderRadius: BorderRadius.circular(14), child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: (r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE)).withOpacity(0.12), shape: BoxShape.circle), child: Icon(r.isWithdrawal ? Icons.arrow_upward : Icons.arrow_downward, color: r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE), size: 22)),
            const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r.isWithdrawal ? 'Вывод средств' : 'Добыча: ${r.title}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), overflow: TextOverflow.ellipsis), const SizedBox(height: 2), Text(_ago(r.time), style: const TextStyle(fontSize: 12, color: Colors.grey))])),
            Text('${r.isWithdrawal ? '-' : '+'}${r.amount} ₽', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE))),
          ]))));
        })),
      ]),
    );
  }
  String _ago(DateTime t) { final d = DateTime.now().difference(t); if (d.inMinutes < 1) return 'только что'; if (d.inMinutes < 60) return '${d.inMinutes} мин назад'; if (d.inHours < 24) return '${d.inHours} ч назад'; return '${t.day}.${t.month.toString().padLeft(2, '0')} ${t.hour}:${t.minute.toString().padLeft(2, '0')}'; }
}

class WithdrawScreen extends StatefulWidget {
  final Streamer streamer;
  const WithdrawScreen({super.key, required this.streamer});
  @override
  State<WithdrawScreen> createState() => _WDState();
}

class _WDState extends State<WithdrawScreen> {
  final _amount = TextEditingController(); String _method = 'Карта';
  int get balance => streamerWallet[widget.streamer.name] ?? 0;
  @override
  void dispose() { _amount.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: const Text('Вывод средств', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: double.infinity, padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))]),
          child: Column(children: [const Icon(Icons.account_balance_wallet, size: 40, color: Color(0xFF2AABEE)), const SizedBox(height: 8), const Text('Доступно к выводу', style: TextStyle(fontSize: 13, color: Colors.grey)), Text('$balance ₽', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.black87))])),
        const SizedBox(height: 24), const Text('Сумма вывода', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 8), TextField(controller: _amount, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: '0', suffixText: '₽', filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
        const SizedBox(height: 12), Row(children: [_quickBtn('Всё', balance), const SizedBox(width: 8), _quickBtn('${balance ~/ 2}', balance ~/ 2), const SizedBox(width: 8), _quickBtn('500', 500)]), const SizedBox(height: 24),
        const Text('Способ вывода', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), const SizedBox(height: 10), _methodTile('Карта', 'Visa / MasterCard / МИР', Icons.credit_card), const SizedBox(height: 8), _methodTile('СБП', 'По номеру телефона', Icons.phone_iphone), const SizedBox(height: 8), _methodTile('USDT', 'TRC-20', Icons.currency_bitcoin), const SizedBox(height: 32),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _withdraw, icon: const Icon(Icons.arrow_upward), label: const Text('Вывести', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
      ]))),
    );
  }
  Widget _quickBtn(String label, int val) => Expanded(child: Material(color: Colors.white, borderRadius: BorderRadius.circular(12), child: InkWell(borderRadius: BorderRadius.circular(12), onTap: val > 0 ? () => setState(() => _amount.text = '$val') : null, child: Container(padding: const EdgeInsets.symmetric(vertical: 12), alignment: Alignment.center, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))))));
  Widget _methodTile(String name, String subtitle, IconData icon) { final selected = _method == name; return Material(color: Colors.white, borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => setState(() => _method = name), child: Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: selected ? const Color(0xFF2AABEE) : Colors.transparent, width: 2)), child: Row(children: [Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.12), shape: BoxShape.circle), child: Icon(icon, color: const Color(0xFF2AABEE), size: 22)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)), Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey))])), Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? const Color(0xFF2AABEE) : Colors.grey, size: 22)])))); }
  void _withdraw() { final amt = int.tryParse(_amount.text.trim()); if (amt == null || amt <= 0) { _snack('Введите сумму больше нуля', Colors.red); return; } if (amt < 100) { _snack('Минимум 100 ₽', Colors.red); return; } if (amt > balance) { _snack('Недостаточно средств. Доступно: $balance ₽', Colors.red); return; } setState(() { streamerWallet[widget.streamer.name] = balance - amt; streamerHistory.putIfAbsent(widget.streamer.name, () => []); streamerHistory[widget.streamer.name]!.insert(0, EarningRecord(title: 'Вывод на $_method', amount: amt, time: DateTime.now(), isWithdrawal: true)); _amount.clear(); }); _snack('Заявка на вывод $amt ₽ принята!', const Color(0xFF2AABEE)); }
  void _snack(String t, Color c) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), backgroundColor: c, behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))); }
}

class StreamerListScreen extends StatefulWidget {
  const StreamerListScreen({super.key});
  @override
  State<StreamerListScreen> createState() => _StreamerListScreenState();
}

class _StreamerListScreenState extends State<StreamerListScreen> {
  final TextEditingController _searchController = TextEditingController(); String _query = '';
  @override
  void dispose() { _searchController.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final filtered = allStreamers.where((s) => s.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(backgroundColor: const Color(0xFFF0F2F5), appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0, title: const Text('Выберите стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(controller: _searchController, onChanged: (val) => setState(() => _query = val), decoration: InputDecoration(hintText: 'Поиск стримера...', prefixIcon: const Icon(Icons.search, color: Colors.grey), suffixIcon: _query.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, color: Colors.grey), onPressed: () { _searchController.clear(); setState(() => _query = ''); }) : null, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)))),
        Expanded(child: filtered.isEmpty ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.person_search, size: 60, color: Colors.grey), SizedBox(height: 16), Text('Стримеры не найдены', style: TextStyle(fontSize: 16, color: Colors.grey))])) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 12), itemCount: filtered.length, itemBuilder: (context, i) {
          final s = filtered[i];
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: Material(color: Colors.white, borderRadius: BorderRadius.circular(16), child: InkWell(borderRadius: BorderRadius.circular(16), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DonaterMapScreen(streamer: s))),
            child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [CircleAvatar(radius: 28, backgroundColor: const Color(0xFF2AABEE), child: Text(s.name.isNotEmpty ? s.name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22))), const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)), const SizedBox(height: 4), Text(s.channel, style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis)])), const Icon(Icons.chevron_right, color: Colors.grey, size: 20)])))));
        })),
      ]),
    );
  }
}

class DonaterMapScreen extends StatefulWidget {
  final Streamer streamer;
  const DonaterMapScreen({super.key, required this.streamer});
  @override
  State<DonaterMapScreen> createState() => _DonState();
}

class _DonState extends State<DonaterMapScreen> {
  bool _placing = false; DonationPoint? _sel; final _amount = TextEditingController(); final _msg = TextEditingController(); final _nameController = TextEditingController();
  Timer? _spoilTimer; bool _isCreating = false; List<StreamSubscription> _fbSubs = [];
  List<DonationPoint> get points { streamerPoints.putIfAbsent(widget.streamer.name, () => []); return streamerPoints[widget.streamer.name]!; }

  @override
  void initState() {
    super.initState(); _fbSubs = getRealtimeListeners(widget.streamer.name, () { if (mounted) setState(() {}); });
    _spoilTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return; bool changed = false;
      for (final p in points) { if (p.isSpoiled && p.currentAmount > 0) { changed = true; } }
      if (changed) setState(() {});
    });
  }

  @override
  void dispose() { for (var sub in _fbSubs) { sub.cancel(); } _spoilTimer?.cancel(); _amount.dispose(); _msg.dispose(); _nameController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      FlutterMap(options: MapOptions(
        initialCenter: const LatLng(56.0184, 92.8672), initialZoom: 13, minZoom: 4.0, maxZoom: 19.0,
        onTap: (pos, latlng) { if (_placing) { _newPointDialog(latlng); } else { setState(() { _sel = null; _isCreating = false; }); } }),
        children: [
          TileLayer(
            urlTemplate: 'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c'],
            userAgentPackageName: 'ru.dimamasss.streamermapdonate',
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
          MarkerLayer(markers: points.map((p) => Marker(point: p.position, width: 100, height: 110, child: GestureDetector(onTap: _placing ? null : () => setState(() { _sel = p; _amount.clear(); }), child: _goldCoin(p)))).toList()),
        ],
      ),
      SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]), child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.black87), onPressed: () { if (_placing) { setState(() => _placing = false); } else { Navigator.pop(context); } })),
        const SizedBox(width: 10),
        Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]), child: Row(children: [CircleAvatar(radius: 18, backgroundColor: const Color(0xFF2AABEE), child: Text(widget.streamer.name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))), const SizedBox(width: 10), Expanded(child: Text(widget.streamer.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14), overflow: TextOverflow.ellipsis))]))),
        const SizedBox(width: 8),
        GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveFeedScreen(streamer: widget.streamer))), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]), child: Row(children: [Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)), const SizedBox(width: 6), const Text('LIVE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))]))),
      ]))),
      if (_placing) Positioned(top: 100, left: 20, right: 20, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(14)), child: const Row(children: [Icon(Icons.touch_app, color: Colors.white, size: 18), SizedBox(width: 8), Expanded(child: Text('Тапните по карте, чтобы поставить точку', style: TextStyle(color: Colors.white, fontSize: 13)))]))),
      if (_sel == null && !_placing) Positioned(bottom: 30, right: 20, child: FloatingActionButton.extended(onPressed: () => setState(() => _placing = true), backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, icon: const Icon(Icons.add_location_alt), label: const Text('Создать точку'))),
      if (_sel != null) Positioned(left: 0, right: 0, bottom: 0, child: _donateSheet(_sel!)),
    ]));
  }

  Widget _goldCoin(DonationPoint p) { final isHot = p.currentAmount >= 1000; final isSpoiled = p.isSpoiled; return Column(mainAxisSize: MainAxisSize.min, children: [Container(width: isHot ? 72 : 62, height: isHot ? 72 : 62, decoration: BoxDecoration(shape: BoxShape.circle, gradient: isSpoiled ? const RadialGradient(colors: [Color(0xFFFFAAAA), Color(0xFFE53935), Color(0xFF8B0000)], stops: [0, 0.6, 1]) : const RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1]), border: Border.all(color: isSpoiled ? Colors.white : const Color(0xFFFFF8DC), width: 3), boxShadow: [BoxShadow(color: isSpoiled ? Colors.red.withOpacity(0.8) : const Color(0xFFFFD700).withOpacity(isHot ? 0.8 : 0.5), blurRadius: isSpoiled ? 20 : (isHot ? 18 : 10), spreadRadius: isHot ? 4 : 1), BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3))]), child: Center(child: Text(_fmt(p.currentAmount), style: TextStyle(color: isSpoiled ? Colors.white : const Color(0xFF4A3200), fontWeight: FontWeight.w900, fontSize: isHot ? 14 : 13)))), const SizedBox(height: 2), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isSpoiled ? Colors.red.withOpacity(0.75) : const Color(0xFF2AABEE).withOpacity(0.75), borderRadius: BorderRadius.circular(8)), child: Text(p.title, style: const TextStyle(color: Colors.white, fontSize: 10)))]); }
  String _fmt(int a) { if (a >= 1000) { final v = a / 1000; return v == v.roundToDouble() ? '${v.toInt()}к' : '${v.toStringAsFixed(1)}к'; } return '$a'; }

  Widget _donateSheet(DonationPoint p) {
    return Container(decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18))), padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 32, height: 3, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 4),
        Row(children: [Expanded(child: Text(p.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)), GestureDetector(onTap: () => setState(() { _sel = null; _isCreating = false; }), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, color: Colors.grey, size: 16)))]), const SizedBox(height: 6),
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFFFFD700).withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4))),
          child: Row(children: [const Icon(Icons.monetization_on, color: Color(0xFFB8860B), size: 18), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text('${p.currentAmount} ₽', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFFB8860B))), if (p.isSpoiled) const Text('🔥 Сгорает: -1 ₽/сек', style: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.w600)) else Text('⏳ Ждёт: ${_fmtDur(p.timeToSpoil)}', style: const TextStyle(fontSize: 10, color: Color(0xFF2AABEE), fontWeight: FontWeight.w600))])), Text('${p.donors.length} ${donorsWord(p.donors.length)}', style: TextStyle(fontSize: 10, color: Colors.grey.shade600))])),
        const SizedBox(height: 8),
        Row(children: [100, 300, 500, 1000].map((a) { final isDisabled = (_isCreating && a != 1000) || (p.isSpoiled && a != 1000); return Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Opacity(opacity: isDisabled ? 0.3 : 1.0, child: Material(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(10), child: InkWell(borderRadius: BorderRadius.circular(10), onTap: isDisabled ? null : () => setState(() => _amount.text = '$a'), child: Container(padding: const EdgeInsets.symmetric(vertical: 8), alignment: Alignment.center, child: Text('$a', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)))))))); }).toList()),
        const SizedBox(height: 8), TextField(controller: _amount, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: 'Своя сумма', suffixText: '₽', prefixIcon: const Icon(Icons.edit, color: Color(0xFF2AABEE), size: 18), isDense: true, filled: true, fillColor: const Color(0xFFF0F2F5), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
        const SizedBox(height: 6), TextField(controller: _nameController, maxLength: 20, style: const TextStyle(fontSize: 13), decoration: InputDecoration(hintText: 'Ваш ник (необязательно)', prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF2AABEE), size: 18), isDense: true, filled: true, fillColor: const Color(0xFFF0F2F5), counterText: '', contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
        const SizedBox(height: 6), TextField(controller: _msg, maxLength: 100, style: const TextStyle(fontSize: 13), decoration: InputDecoration(hintText: 'Сообщение (необязательно)', prefixIcon: const Icon(Icons.chat_bubble_outline, color: Color(0xFF2AABEE), size: 18), isDense: true, filled: true, fillColor: const Color(0xFFF0F2F5), counterText: '', contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
        const SizedBox(height: 8), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: () => _send(p), icon: const Icon(Icons.send, size: 16), label: Text(_isCreating ? 'Создать за 1000 ₽' : (p.isSpoiled ? 'Заморозить за 1000 ₽' : 'Скинуть донат'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD700), foregroundColor: const Color(0xFF4A3200), elevation: 0, padding: const EdgeInsets.symmetric(vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))))),
      ]),
    );
  }
  String _fmtDur(Duration d) { if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин'; if (d.inMinutes > 0) return '${d.inMinutes} мин'; return '${d.inSeconds} сек'; }

  void _send(DonationPoint p) {
    final a = int.tryParse(_amount.text.trim());
    if (a == null || a <= 0) { _snack('Введите сумму больше нуля', Colors.red); return; }
    final isNew = _isCreating; final isBurning = p.isSpoiled;
    if (isNew && a != 1000) { _snack('Создание точки стоит 1000 ₽', Colors.red); return; }
    if (isBurning && !isNew && a != 1000) { _snack('Чтобы остановить сгорание, нужно закинуть ровно 1000 ₽', Colors.red); return; }
    String rawName = _nameController.text.trim(); String displayName = rawName.isEmpty ? 'Аноним' : filterBadWords(rawName);
    setState(() {
      if (isBurning) { p.totalAmount = p.currentAmount + a; p.lastTopUp = DateTime.now(); } else { p.totalAmount += a; p.lastTopUp = DateTime.now(); }
      p.donors.add(displayName);
      if (isNew) { points.add(p); uploadPointToCloud(widget.streamer.name, p); _isCreating = false; }
      final newDonation = LiveDonation(donorName: displayName, pointTitle: p.title, amount: a, time: DateTime.now(), message: filterBadWords(_msg.text.trim()), position: p.position);
      streamerFeed.putIfAbsent(widget.streamer.name, () => []); streamerFeed[widget.streamer.name]!.insert(0, newDonation); uploadDonationToCloud(widget.streamer.name, newDonation);
      _sel = null; _amount.clear(); _msg.clear(); _nameController.clear();
    });
    _snack(isNew ? 'Точка создана!' : (isBurning ? 'Точка заморожена!' : 'Донат $a ₽ отправлен!'), const Color(0xFF2AABEE));
  }

  void _newPointDialog(LatLng pos) async {
    _snack('Определяю место...', const Color(0xFF2AABEE));
    final name = await getLocationName(pos);
    if (!mounted) return;
    setState(() { _isCreating = true; _placing = false; _sel = DonationPoint(position: pos, title: name); _amount.text = '1000'; _msg.clear(); _nameController.clear(); });
  }
  void _snack(String t, Color c) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t, style: const TextStyle(color: Colors.white)), backgroundColor: c, behavior: SnackBarBehavior.floating, margin: const EdgeInsets.fromLTRB(80, 0, 80, 100), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)))); }
}

String filterBadWords(String text) {
  if (text.isEmpty) return text;
  const badWords = ['хуй', 'хуе', 'хуё', 'пизд', 'бляд', 'еба', 'еби', 'ебa', 'сукa', 'муда', 'долбо'];
  String result = text;
  for (final w in badWords) { result = result.replaceAll(RegExp(w, caseSensitive: false), '***'); }
  return result;
}
