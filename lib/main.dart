import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:geolocator/geolocator.dart';

const Duration kHoldDuration = Duration(hours: 24);
const int kSpoilRate = 1;
const double kPointRadius = 50;
const int kBurnRate = 10;

// Корни матерных слов для фильтра
const List<String> kBadRoots = [
  'хуй', 'хуе', 'хуё', 'хую', 'хуя', 'хуи',
  'пизд', 'пизж',
  'бляд', 'блят', 'бля ',
  'еба', 'ебa', 'еби', 'ебу', 'ебё', 'ебe', 'ебя',
  'ебан', 'ебал', 'ебуч',
  'сукa', 'суки', 'сучк', 'сучар',
  'муда', 'муди', 'мудо',
  'гандон', 'гондон',
  'долбо', 'долба',
  'залуп', 'залуп',
  'манда', 'манда',
  'пидор', 'пидар', 'пидр',
  'шлюх', 'шлюш',
  'мраз',
  'ублюд',
  'дебил', 'дебиль',
  'кретин', 'кретин',
  'идиот',
  'нахуй', 'нахуя',
];

Future<String> getLocationName(LatLng pos) async {
  try {
    final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=${pos.latitude}&lon=${pos.longitude}&zoom=18&accept-language=ru');
    final res = await html.HttpRequest.request(
      url.toString(),
      method: 'GET',
      requestHeaders: {'User-Agent': 'StreamerMapDonate/1.0'},
    );
    final text = res.responseText;
    if (text == null || text.isEmpty) return 'Донат';
    final data = jsonDecode(text) as Map<String, dynamic>;
    final a = data['address'] as Map<String, dynamic>?;
    if (a != null) {
      final name = a['road'] ?? a['pedestrian'] ?? a['park'] ?? a['neighbourhood'] ?? a['suburb'] ?? a['city_district'] ?? a['city'];
      if (name != null) return name.toString();
    }
    return (data['display_name'] as String?)?.split(',').first ?? 'Донат';
  } catch (e) {
    return 'Донат';
  }
}

String donorsWord(int n) {
  if (n % 10 == 1 && n % 100 != 11) return 'донатер';
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) return 'донатера';
  return 'донатеров';
}

String pointsWord(int n) {
  if (n % 10 == 1 && n % 100 != 11) return 'точка';
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) return 'точки';
  return 'точек';
}

String filterBadWords(String text) {
  if (text.isEmpty) return text;
  final lower = text.toLowerCase();
  final chars = text.split('');
  final lowerChars = lower.split('');

  for (final root in kBadRoots) {
    int start = 0;
    while (true) {
      final idx = lower.indexOf(root, start);
      if (idx < 0) break;
      // Заменяем всё слово целиком на звёздочки
      int wordStart = idx;
      while (wordStart > 0 && RegExp(r'[а-яa-zё]').hasMatch(lowerChars[wordStart - 1])) {
        wordStart--;
      }
      int wordEnd = idx + root.length;
      while (wordEnd < lower.length && RegExp(r'[а-яa-zё]').hasMatch(lowerChars[wordEnd])) {
        wordEnd++;
      }
      for (int i = wordStart; i < wordEnd; i++) {
        chars[i] = '*';
      }
      start = wordEnd;
    }
  }
  return chars.join();
}

class Streamer {
  final String name, platform, channel;
  final int minDonation;
  Streamer({required this.name, required this.platform, required this.channel, this.minDonation = 0});
  String get qrData {
    final base = Uri.base.origin;
    return '$base/?streamer=${Uri.encodeComponent(name)}';
  }
}

class DonationPoint {
  LatLng position;
  String title;
  int totalAmount;
  DateTime lastTopUp;
  DateTime? zeroedAt;
  List<String> donors;
  DonationPoint({
    required this.position,
    required this.title,
    this.totalAmount = 0,
    DateTime? lastTopUp,
    this.zeroedAt,
    List<String>? donors,
  })  : lastTopUp = lastTopUp ?? DateTime.now(),
        donors = donors ?? [];
  bool get isSpoiled => DateTime.now().difference(lastTopUp) > kHoldDuration;
  Duration get timeToSpoil {
    final left = kHoldDuration - DateTime.now().difference(lastTopUp);
    return left.isNegative ? Duration.zero : left;
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

class LiveDonation {
  final String donorName, pointTitle;
  final int amount;
  final DateTime time;
  final String message;
  final LatLng? position;
  LiveDonation({required this.donorName, required this.pointTitle, required this.amount, required this.time, this.message = '', this.position});
}

final List<Streamer> allStreamers = [
  Streamer(name: 'StreamerX', platform: 'Twitch', channel: 'twitch.tv/streamerx'),
  Streamer(name: 'GamerPro', platform: 'YouTube', channel: 'youtube.com/@gamerpro'),
];

final Map<String, List<DonationPoint>> streamerPoints = {
  'StreamerX': [
    DonationPoint(position: const LatLng(56.0184, 92.8672), title: 'о. Татышев', totalAmount: 500, lastTopUp: DateTime.now().subtract(const Duration(hours: 3)), donors: ['Иван', 'Аня']),
    DonationPoint(position: const LatLng(56.0280, 92.8500), title: 'Площадь Мира', totalAmount: 1200, lastTopUp: DateTime.now().subtract(const Duration(hours: 25)), donors: ['Макс', 'Оля']),
    DonationPoint(position: const LatLng(56.0130, 92.8800), title: 'Столбы', totalAmount: 2500, lastTopUp: DateTime.now().subtract(const Duration(minutes: 30)), donors: ['Кирилл']),
  ],
  'GamerPro': [
    DonationPoint(position: const LatLng(56.0100, 92.8900), title: 'Столбы', totalAmount: 300, donors: ['Кирилл']),
  ],
};

final Map<String, int> streamerWallet = {'StreamerX': 500, 'GamerPro': 0};
final Map<String, List<EarningRecord>> streamerHistory = {
  'StreamerX': [
    EarningRecord(title: 'о. Татышев', amount: 300, time: DateTime.now().subtract(const Duration(hours: 2))),
  ],
};
final Map<String, List<LiveDonation>> streamerFeed = {
  'StreamerX': [
    LiveDonation(donorName: 'Гоша', pointTitle: 'о. Татышев', amount: 200, time: DateTime.now().subtract(const Duration(minutes: 18)), message: 'Давай на Татышев, там красиво!'),
    LiveDonation(donorName: 'Петя', pointTitle: 'Площадь Мира', amount: 500, time: DateTime.now().subtract(const Duration(minutes: 45)), message: 'За Победу!'),
  ],
};

int appBalance = 0;

void main() {
  final params = Uri.base.queryParameters;
  final streamerName = params['streamer'];
  runApp(StreamerMapApp(initialStreamerName: streamerName));
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
      title: 'Streamer Map Donate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF2AABEE),
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2AABEE),
          primary: const Color(0xFF2AABEE),
          surface: Colors.white),
        useMaterial3: true),
      home: home,
    );
  }
}

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 100, height: 100,
            decoration: BoxDecoration(color: const Color(0xFF2AABEE), shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: const Color(0xFF2AABEE).withOpacity(0.35), blurRadius: 20, offset: const Offset(0, 8))]),
            child: const Icon(Icons.location_on, color: Colors.white, size: 55)),
          const SizedBox(height: 28),
          const Text('Карта донатов', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Выберите свою роль', style: TextStyle(fontSize: 15, color: Colors.grey)),
          const SizedBox(height: 48),
          _card(context, 'Я стример', 'Войти или зарегистрироваться', Icons.videocam, const Color(0xFF2AABEE),
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerAuthScreen()))),
          const SizedBox(height: 16),
          _card(context, 'Я донатер', 'Выберите стримера и скиньте донат', Icons.favorite, const Color(0xFFE5875B),
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerListScreen()))),
        ]))),
    );
  }
  Widget _card(BuildContext context, String t, String s, IconData i, Color c, VoidCallback tap) {
    return Material(color: Colors.white, borderRadius: BorderRadius.circular(20),
      child: InkWell(borderRadius: BorderRadius.circular(20), onTap: tap,
        child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [
          Container(width: 56, height: 56, decoration: BoxDecoration(color: c.withOpacity(0.12), shape: BoxShape.circle), child: Icon(i, color: c, size: 28)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(s, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ])),
          const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 16),
        ]))));
  }
}

class StreamerAuthScreen extends StatelessWidget {
  const StreamerAuthScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87,
        title: const Text('Вход для стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const SizedBox(height: 20),
        Container(width: 100, height: 100, decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.12), shape: BoxShape.circle),
          child: const Icon(Icons.videocam, color: Color(0xFF2AABEE), size: 55)),
        const SizedBox(height: 24),
        const Text('Вы уже зарегистрированы?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Войдите или создайте нового стримера', style: TextStyle(fontSize: 14, color: Colors.grey), textAlign: TextAlign.center),
        const SizedBox(height: 40),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerLoginScreen())),
          icon: const Icon(Icons.login), label: const Text('Войти', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamerRegistrationScreen())),
          icon: const Icon(Icons.person_add), label: const Text('Зарегистрироваться', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF2AABEE), side: const BorderSide(color: Color(0xFF2AABEE), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
      ]))),
    );
  }
}

class StreamerLoginScreen extends StatelessWidget {
  const StreamerLoginScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
        title: const Text('Выберите свой аккаунт', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: allStreamers.length,
        itemBuilder: (context, i) {
          final s = allStreamers[i];
          final cnt = streamerPoints[s.name]?.length ?? 0;
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Material(color: Colors.white, borderRadius: BorderRadius.circular(16),
              child: InkWell(borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StreamerDashboardScreen(streamer: s))),
                child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                  CircleAvatar(radius: 28, backgroundColor: const Color(0xFF2AABEE),
                    child: Text(s.name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22))),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    const SizedBox(height: 4),
                    Row(children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                        child: Text(s.platform, style: const TextStyle(fontSize: 11, color: Color(0xFF2AABEE), fontWeight: FontWeight.w600))),
                      const SizedBox(width: 8),
                      Text('$cnt ${pointsWord(cnt)}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ])),
                  const Icon(Icons.login, color: Color(0xFF2AABEE)),
                ])))),
          );
        }),
    );
  }
}

class StreamerRegistrationScreen extends StatefulWidget {
  const StreamerRegistrationScreen({super.key});
  @override
  State<StreamerRegistrationScreen> createState() => _RegState();
}

class _RegState extends State<StreamerRegistrationScreen> {
  final _name = TextEditingController();
  final _ch = TextEditingController();
  final _min = TextEditingController(text: '0');
  bool _ok = false;
  String _plat = 'Twitch';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87,
        title: const Text('Регистрация стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 100, height: 100,
            decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.15), shape: BoxShape.circle),
            child: const Icon(Icons.person, size: 55, color: Color(0xFF2AABEE)))),
          const SizedBox(height: 24),
          const Text('Имя / ник', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _name, decoration: _dec('Например, StreamerX')),
          const SizedBox(height: 16),
          const Text('Платформа', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: DropdownButtonHideUnderline(child: DropdownButton<String>(
              value: _plat, isExpanded: true,
              items: ['Twitch', 'YouTube', 'VK Play', 'Kick'].map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
              onChanged: (v) => setState(() => _plat = v!)))),
          const SizedBox(height: 16),
          const Text('Ссылка на канал', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _ch, decoration: _dec('twitch.tv/your_channel')),
          const SizedBox(height: 16),
          const Text('Минимальный донат (₽)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _min, keyboardType: TextInputType.number, decoration: _dec('Например, 100')),
          const SizedBox(height: 24),
          Material(color: Colors.white, borderRadius: BorderRadius.circular(14),
            child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => setState(() => _ok = !_ok),
              child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                Container(width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: _ok ? const Color(0xFF2AABEE) : Colors.transparent,
                    border: Border.all(color: _ok ? const Color(0xFF2AABEE) : Colors.grey.shade400, width: 2),
                    borderRadius: BorderRadius.circular(6)),
                  child: _ok ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                const SizedBox(width: 12),
                const Expanded(child: Text('Я подтверждаю, что этот канал принадлежит мне', style: TextStyle(fontSize: 13.5))),
              ])))),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: (_ok && _name.text.isNotEmpty && _ch.text.isNotEmpty) ? () {
              final s = Streamer(name: _name.text, platform: _plat, channel: _ch.text, minDonation: int.tryParse(_min.text.trim()) ?? 0);
              allStreamers.add(s);
              streamerPoints.putIfAbsent(s.name, () => []);
              streamerWallet.putIfAbsent(s.name, () => 0);
              streamerHistory.putIfAbsent(s.name, () => []);
              streamerFeed.putIfAbsent(s.name, () => []);
              Navigator.push(context, MaterialPageRoute(builder: (_) => StreamerQRCodeScreen(streamer: s)));
            } : null,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade300, elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: const Text('Продолжить', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))),
        ]),
      )),
    );
  }
  InputDecoration _dec(String h) => InputDecoration(hintText: h, filled: true, fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));
}

class StreamerQRCodeScreen extends StatelessWidget {
  final Streamer streamer;
  const StreamerQRCodeScreen({super.key, required this.streamer});

  Future<void> _downloadQr(BuildContext context) async {
    try {
      final painter = QrPainter(
        data: streamer.qrData,
        version: QrVersions.auto,
        color: Colors.black,
        emptyColor: Colors.white,
        gapless: true,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF2AABEE)),
        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black87),
      );
      final imageData = await painter.toImageData(1024);
      if (imageData == null) { _snack(context, 'Не удалось', Colors.red); return; }
      final bytes = imageData.buffer.asUint8List();
      final blob = html.Blob([bytes], 'image/png');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', 'qr_${streamer.name}.png')
        ..click();
      html.Url.revokeObjectUrl(url);
      _snack(context, 'QR-код скачан!', const Color(0xFF2AABEE));
    } catch (e) {
      _snack(context, 'Ошибка: $e', Colors.red);
    }
  }

  void _snack(BuildContext context, String t, Color c) {
    final isError = c == Colors.red || c == Colors.orange;
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + 70,
        left: 30, right: 30,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isError ? c : c.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Text(t,
                style: TextStyle(color: Colors.white, fontSize: isError ? 13 : 12, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(Duration(seconds: isError ? 2 : 1), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.black87,
        title: const Text('Ваш QR-код', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
      body: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
        child: SingleChildScrollView(child: Column(children: [
          const SizedBox(height: 8),
          const Text('Готово! Канал подтверждён', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Покажите QR зрителям или поставьте на IRL-трансляцию',
            style: TextStyle(fontSize: 13, color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Container(padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 8))]),
            child: Column(children: [
              QrImageView(data: streamer.qrData, version: QrVersions.auto, size: 220, backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF2AABEE)),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black87)),
              const SizedBox(height: 16),
              Text(streamer.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${streamer.platform} • ${streamer.channel}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ])),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () => _downloadQr(context),
            icon: const Icon(Icons.download),
            label: const Text('Скачать QR как PNG', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200)),
            child: Column(children: [
              const Row(children: [
                Icon(Icons.link, size: 18, color: Color(0xFF2AABEE)),
                SizedBox(width: 6),
                Text('Ссылка для донатеров', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
              const SizedBox(height: 8),
              Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(10)),
                child: SelectableText(streamer.qrData,
                  style: const TextStyle(fontSize: 12, color: Colors.black87, fontFamily: 'monospace'))),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: streamer.qrData));
                  _snack(context, 'Ссылка скопирована!', const Color(0xFF2AABEE));
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Скопировать ссылку'),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF2AABEE),
                  side: const BorderSide(color: Color(0xFF2AABEE)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
            ])),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () => Navigator.pushAndRemoveUntil(context,
                  MaterialPageRoute(builder: (_) => StreamerDashboardScreen(streamer: streamer)), (route) => route.isFirst),
              icon: const Icon(Icons.dashboard), label: const Text('В кабинет'),
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF2AABEE), side: const BorderSide(color: Color(0xFF2AABEE)),
                padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton.icon(
              onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
              icon: const Icon(Icons.home), label: const Text('На главную'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
          ]),
          const SizedBox(height: 24),
        ]))),
      ),
    );
  }
}

class LiveFeedScreen extends StatelessWidget {
  final Streamer streamer;
  const LiveFeedScreen({super.key, required this.streamer});

  @override
  Widget build(BuildContext context) {
    final feed = streamerFeed[streamer.name] ?? [];

    // Группируем донаты по точкам
    final Map<String, int> byPoint = {};
    final Map<String, int> countByPoint = {};
    for (final d in feed) {
      byPoint[d.pointTitle] = (byPoint[d.pointTitle] ?? 0) + d.amount;
      countByPoint[d.pointTitle] = (countByPoint[d.pointTitle] ?? 0) + 1;
    }

    // Сортируем по сумме (по убыванию)
    final points = byPoint.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2AABEE),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(children: [
          Container(width: 10, height: 10,
            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          const Text('LIVE — донаты',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19)),
        ]),
      ),
      body: feed.isEmpty
        ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.inbox, size: 60, color: Colors.grey),
            SizedBox(height: 16),
            Text('Пока нет донатов', style: TextStyle(fontSize: 16, color: Colors.grey)),
          ]))
        : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: points.length,
            itemBuilder: (ctx, i) {
              final entry = points[i];
              final title = entry.key;
              final sum = entry.value;
              final count = countByPoint[title] ?? 0;

              // Ищем позицию точки для перелёта
              final anyDonation = feed.firstWhere((d) => d.pointTitle == title);

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PointDetailsScreen(streamer: streamer, pointTitle: title))),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2AABEE).withOpacity(0.1),
                            shape: BoxShape.circle),
                          child: const Icon(Icons.location_on, color: Color(0xFF2AABEE), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                              overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text('$count ${donorsWord(count)}',
                              style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ]),
                        ),
                        Text('$sum ₽',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF2AABEE))),
                        const SizedBox(width: 2),
                        const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
                      ]),
                    ),
                  ),
                ),
              );
            }),
    );
  }
}

class PointDetailsScreen extends StatelessWidget {
  final Streamer streamer;
  final String pointTitle;
  const PointDetailsScreen({super.key, required this.streamer, required this.pointTitle});

  @override
  Widget build(BuildContext context) {
    final feed = streamerFeed[streamer.name] ?? [];
    final donations = feed.where((d) => d.pointTitle == pointTitle).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final total = donations.fold<int>(0, (s, x) => s + x.amount);

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2AABEE),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(pointTitle,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          overflow: TextOverflow.ellipsis),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Всего собрано', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 2),
            Row(children: [
              Text('$total ₽',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.black87)),
              const Spacer(),
              Text('${donations.length} ${donorsWord(donations.length)}',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
          ])),
        Expanded(child: donations.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.inbox, size: 60, color: Colors.grey),
              SizedBox(height: 16),
              Text('Пока нет донатов', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: donations.length,
              itemBuilder: (ctx, i) {
                final d = donations[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        CircleAvatar(radius: 22, backgroundColor: const Color(0xFFE5875B),
                          child: Text(d.donorName[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(d.donorName,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                          if (d.message.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(d.message,
                              style: const TextStyle(fontSize: 13, color: Colors.black87, fontStyle: FontStyle.italic)),
                          ],
                          const SizedBox(height: 2),
                          Text(_ago(d.time),
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ])),
                        Text('+${d.amount} ₽',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF2AABEE))),
                      ]),
                    ),
                  ),
                );
              })),
      ]),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'только что';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    if (d.inHours < 24) return '${d.inHours} ч назад';
    return '${d.inDays} дн назад';
  }
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
  int _browseIdx = 0;
  final MapController _mapCtrl = MapController();

  List<DonationPoint> get points {
    streamerPoints.putIfAbsent(widget.streamer.name, () => []);
    return streamerPoints[widget.streamer.name]!;
  }
  int get totalEarned => points.fold(0, (s, p) => s + p.totalAmount);
  int get walletBalance => streamerWallet[widget.streamer.name] ?? 0;
  int get spoiledTotal => points.where((p) => p.isSpoiled).length;

  @override
  void initState() {
    super.initState();
    _spoilTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      bool changed = false;
      final toRemove = <DonationPoint>[];
      for (final p in points) {
        if (p.isSpoiled && p.totalAmount > 0) {
          final take = p.totalAmount < kSpoilRate ? p.totalAmount : kSpoilRate;
          p.totalAmount -= take;
          appBalance += take;
          changed = true;
        }
        if (p.totalAmount == 0) {
          p.zeroedAt ??= DateTime.now();
          if (DateTime.now().difference(p.zeroedAt!) > const Duration(seconds: 15)) {
            toRemove.add(p);
          }
        } else {
          p.zeroedAt = null;
        }
      }
      if (toRemove.isNotEmpty) {
        points.removeWhere((p) => toRemove.contains(p));
        changed = true;
      }
      if (changed) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _miningTimer?.cancel();
    _spoilTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggleShift() async {
    if (_isShiftActive) {
      await _sub?.cancel();
      _miningTimer?.cancel();
      setState(() { _isShiftActive = false; _miningPoint = null; });
      _snack('Смена остановлена', Colors.grey.shade700);
      return;
    }
    bool serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) { _snack('Включите геолокацию', Colors.red); return; }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('Нет разрешения', Colors.red); return;
    }
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((pos) { setState(() => _myPos = pos); _checkPoints(pos); });
    setState(() => _isShiftActive = true);
    _snack('Смена начата!', const Color(0xFF2AABEE));
  }

  void _checkPoints(Position pos) {
    const dist = Distance();
    final me = LatLng(pos.latitude, pos.longitude);
    DonationPoint? nearest;
    double nd = double.infinity;
    for (final p in points) {
      final d = dist.as(LengthUnit.Meter, me, p.position);
      if (d < kPointRadius && d < nd) { nearest = p; nd = d; }
    }
    if (nearest != _miningPoint) {
      _miningTimer?.cancel();
      setState(() => _miningPoint = nearest);
      if (nearest != null && nearest.totalAmount > 0) _startMining(nearest);
    }
  }

  void _startMining(DonationPoint point) {
    _miningTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (point.totalAmount <= 0) { t.cancel(); setState(() => _miningPoint = null); return; }
      final burn = point.totalAmount < kBurnRate ? point.totalAmount : kBurnRate;
      setState(() {
        point.totalAmount -= burn;
        _earnedNow += burn;
        streamerWallet[widget.streamer.name] = (streamerWallet[widget.streamer.name] ?? 0) + burn;
        final hist = streamerHistory.putIfAbsent(widget.streamer.name, () => []);
        final now = DateTime.now();
        if (hist.isNotEmpty &&
            !hist.first.isWithdrawal &&
            hist.first.title == point.title &&
            now.difference(hist.first.time).inSeconds < 15) {
          hist.first.amount += burn;
          hist.first.seconds += 1;
        } else {
          hist.insert(0, EarningRecord(title: point.title, amount: burn, time: now, seconds: 1));
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _mapCtrl,
          options: MapOptions(
            initialCenter: _myPos != null ? LatLng(_myPos!.latitude, _myPos!.longitude) : const LatLng(56.0184, 92.8672),
            initialZoom: 13),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.streamer_map_donate'),
            MarkerLayer(markers: points.map((p) => Marker(
              point: p.position, width: 120, height: 140,
              child: GestureDetector(onTap: () => setState(() => _selectedPoint = p), child: _goldCoin(p)))).toList()),
            if (_myPos != null) MarkerLayer(markers: [
              Marker(point: LatLng(_myPos!.latitude, _myPos!.longitude), width: 40, height: 40,
                child: Container(decoration: BoxDecoration(color: const Color(0xFF2AABEE), shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [BoxShadow(color: const Color(0xFF2AABEE).withOpacity(0.6), blurRadius: 12, spreadRadius: 4)]))),
            ]),
          ],
        ),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 0), child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.all(11),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              _circleBtn(Icons.arrow_back, () => Navigator.pop(context)),
              const SizedBox(width: 10),
              Expanded(child: Row(children: [
                CircleAvatar(radius: 18, backgroundColor: const Color(0xFF2AABEE),
                  child: Text(widget.streamer.name[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18))),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.streamer.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Colors.black87), overflow: TextOverflow.ellipsis),
                  Text('стример', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ])),
              ])),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveFeedScreen(streamer: widget.streamer))),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                  child: Row(children: [
                    Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    const Text('LIVE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 11)),
                  ]))),
              const SizedBox(width: 6),
              _circleBtn(Icons.history, () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => EarningsHistoryScreen(streamer: widget.streamer))).then((_) => setState(() {}))),
            ]),
            const SizedBox(height: 9),
            Container(height: 1, color: Colors.grey.shade200),
            const SizedBox(height: 9),
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Всего на донатах', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                const SizedBox(height: 2),
                Row(children: [
                  Text('$totalEarned ₽', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.black87)),
                  if (_earnedNow > 0) ...[
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0xFF2AABEE), borderRadius: BorderRadius.circular(20)),
                      child: Text('+$_earnedNow', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
                  ],
                ]),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Кошелёк', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  Text('$walletBalance ₽', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black87)),
                ]),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: walletBalance > 0 ? () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => WithdrawScreen(streamer: widget.streamer)));
                  setState(() {});
                } : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Вывести', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5))),
            ]),
              if (points.isNotEmpty) ...[
                const SizedBox(height: 9),
                GestureDetector(
                  onTap: () {
                    final hot = points.where((p) => p.isSpoiled).toList()
                      ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
                    final warm = points.where((p) => !p.isSpoiled).toList()
                      ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
                    final order = [...hot, ...warm];
                    if (order.isEmpty) return;
                    // Если панель закрыта — начинаем сначала
                    if (_selectedPoint == null) _browseIdx = 0;
                    if (_browseIdx >= order.length) _browseIdx = 0;
                    final target = order[_browseIdx];
                    _mapCtrl.move(target.position, 16);
                    setState(() => _selectedPoint = target);
                    _browseIdx++;
                  },
                  child: Builder(builder: (ctx) {
                    final selected = _selectedPoint;
                    final Color color;
                    final IconData icon;
                    final String text;
                    if (selected != null) {
                      color = selected.isSpoiled ? Colors.red : const Color(0xFFB8860B);
                      icon = selected.isSpoiled ? Icons.local_fire_department : Icons.location_on;
                      text = selected.title;
                    } else if (spoiledTotal > 0) {
                      color = Colors.red;
                      icon = Icons.local_fire_department;
                      text = _spoiledText(spoiledTotal);
                    } else {
                      color = const Color(0xFF2AABEE);
                      icon = Icons.location_on;
                      text = '${points.length} ${pointsWord(points.length)}';
                    }
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: color.withOpacity(0.25), width: 1),
                      ),
                      child: Row(children: [
                        Icon(icon, color: color, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(text,
                          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12.5),
                          overflow: TextOverflow.ellipsis)),
                        const Icon(Icons.touch_app, color: Colors.black54, size: 14),
                        const SizedBox(width: 4),
                        const Text('следующая точка',
                          style: TextStyle(color: Colors.black54,
                            fontSize: 11.5, fontWeight: FontWeight.w500)),
                      ]),
                    );
                  }),
                ),
              ],
          ])))),
        if (_miningPoint != null && _isShiftActive)
          Positioned(left: 20, right: 20, bottom: _selectedPoint != null ? 340 : 110,
            child: Container(padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20)]),
              child: Row(children: [
                Container(width: 44, height: 44,
                  decoration: const BoxDecoration(shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1])),
                  child: const Icon(Icons.attach_money, color: Color(0xFF4A3200))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_miningPoint!.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  Text('+$kBurnRate ₽/сек · на точке ${_miningPoint!.totalAmount} ₽',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ])),
                const Icon(Icons.bolt, color: Color(0xFFFFD700), size: 28),
              ]))),
        Positioned(
          right: 20,
          bottom: _selectedPoint != null ? 100 : (_miningPoint != null && _isShiftActive ? 200 : 100),
          child: GestureDetector(
            onTap: () {
              if (_myPos != null) {
                _mapCtrl.move(LatLng(_myPos!.latitude, _myPos!.longitude), 15);
              } else {
                _snack('Геолокация не активна. Начните смену.', Colors.orange);
              }
            },
            child: Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: const Icon(Icons.my_location, color: Color(0xFF2AABEE), size: 26),
            ),
          ),
        ),

        Positioned(left: 20, right: 20, bottom: _selectedPoint != null ? 20 : 30,
          child: ElevatedButton.icon(
            onPressed: _toggleShift,
            icon: Icon(_isShiftActive ? Icons.stop_circle : Icons.play_circle_filled),
            label: Text(_isShiftActive ? 'Остановить смену' : 'Начать смену',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isShiftActive ? Colors.red.shade400 : const Color(0xFF2AABEE),
              foregroundColor: Colors.white, elevation: 6,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
        if (_selectedPoint != null) Positioned(left: 0, right: 0, bottom: 0, child: _infoPanel(_selectedPoint!)),
      ]),
    );
  }

  Widget _circleBtn(IconData i, VoidCallback tap) => Container(
    decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]),
    child: IconButton(icon: Icon(i, color: Colors.black87), onPressed: tap));

  Widget _goldCoin(DonationPoint p) {
    final isSpoiled = p.isSpoiled;
    final isMining = p == _miningPoint;
    final isHot = p.totalAmount >= 1000;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: isHot ? 72 : 62, height: isHot ? 72 : 62,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isSpoiled
            ? const RadialGradient(colors: [Color(0xFFFFAAAA), Color(0xFFE53935), Color(0xFF8B0000)], stops: [0, 0.6, 1])
            : const RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1]),
          border: Border.all(color: isMining ? const Color(0xFF2AABEE) : (isSpoiled ? Colors.white : const Color(0xFFFFF8DC)), width: isMining ? 4 : 3),
          boxShadow: [
            BoxShadow(
              color: isSpoiled ? Colors.red.withOpacity(0.8) : const Color(0xFFFFD700).withOpacity(isMining ? 1 : (isHot ? 0.8 : 0.5)),
              blurRadius: isMining ? 25 : (isSpoiled ? 20 : (isHot ? 18 : 10)),
              spreadRadius: isMining ? 6 : (isHot ? 4 : 1)),
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3)),
          ]),
        child: Center(child: Text(_fmt(p.totalAmount),
          style: TextStyle(color: isSpoiled ? Colors.white : const Color(0xFF4A3200),
            fontWeight: FontWeight.w900, fontSize: isHot ? 14 : 13)))),
      const SizedBox(height: 2),
      Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isSpoiled ? Colors.red.withOpacity(0.45) : Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(8)),
        child: Text(isSpoiled ? '${p.title} · −$kSpoilRate₽/сек' : p.title,
          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600))),
    ]);
  }

  String _fmt(int a) {
    if (a >= 1000) { final v = a / 1000; return v == v.roundToDouble() ? '${v.toInt()}к' : '${v.toStringAsFixed(1)}к'; }
    return '$a';
  }

  Widget _infoPanel(DonationPoint p) {
    final tts = p.timeToSpoil;
    final spoiled = p.isSpoiled;
    final mainColor = spoiled ? Colors.red : const Color(0xFFB8860B);

    return Container(
      decoration: const BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18))),
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [

        Row(children: [
          Expanded(child: Text(p.title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
          GestureDetector(
            onTap: () => setState(() => _selectedPoint = null),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, color: Colors.grey, size: 18))),
        ]),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: mainColor.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: mainColor.withOpacity(0.3), width: 1)),
          child: Row(children: [
            Icon(spoiled ? Icons.local_fire_department : Icons.monetization_on,
              color: mainColor, size: 18),
            const SizedBox(width: 6),
            if (spoiled)
              Text('сгорает · ',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                  color: Colors.red.withOpacity(0.85))),
            Expanded(child: Row(children: [
              Text('${p.totalAmount} ₽',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: mainColor)),
              const SizedBox(width: 8),
              Flexible(child: Text(
                spoiled ? '· −$kSpoilRate ₽/сек' : '· ждёт ${_fmtDur(tts)}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: spoiled ? Colors.red : const Color(0xFF2AABEE)),
                overflow: TextOverflow.ellipsis)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text('${p.donors.length}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: mainColor)),
              Text(donorsWord(p.donors.length),
                style: TextStyle(fontSize: 8.5, color: mainColor.withOpacity(0.75))),
            ]),
          ])),
      ]),
    );
  }

  String _fmtDur(Duration d) {
    if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин';
    if (d.inMinutes > 0) return '${d.inMinutes} мин';
    return '${d.inSeconds} сек';
  }
  double _dist(DonationPoint p) {
    if (_myPos == null) return 0;
    return const Distance().as(LengthUnit.Meter, LatLng(_myPos!.latitude, _myPos!.longitude), p.position);
  }
  String _spoiledText(int n) {
    final word = (n % 10 == 1 && n % 100 != 11)
        ? 'донат сгорает'
        : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20))
            ? 'доната сгорают'
            : 'донатов сгорают';
    return '$n $word';
  }

  void _snack(String t, Color c) {
    final isError = c == Colors.red || c == Colors.orange;
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
                top: MediaQuery.of(ctx).padding.top + 210, left: 30, right: 30,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isError ? c : c.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Text(t,
                style: TextStyle(color: Colors.white, fontSize: isError ? 13 : 12, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(Duration(seconds: isError ? 2 : 1), () {
      if (entry.mounted) entry.remove();
    });
  }
}

class EarningsHistoryScreen extends StatelessWidget {
  final Streamer streamer;
  const EarningsHistoryScreen({super.key, required this.streamer});
  @override
  Widget build(BuildContext context) {
    final history = streamerHistory[streamer.name] ?? [];
    final total = history.where((r) => !r.isWithdrawal).fold(0, (s, r) => s + r.amount);
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
        title: const Text('История заработка', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: Column(children: [
        Container(width: double.infinity, margin: const EdgeInsets.all(12), padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Всего заработано', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 2),
            Text('$total ₽', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.black87)),
          ])),
        Expanded(child: history.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.receipt_long, size: 60, color: Colors.grey),
              SizedBox(height: 16),
              Text('Пока нет операций', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: history.length,
              itemBuilder: (ctx, i) {
                final r = history[i];
                return Padding(padding: const EdgeInsets.only(bottom: 8),
                  child: Material(color: Colors.white, borderRadius: BorderRadius.circular(14),
                    child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                      Container(width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: (r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE)).withOpacity(0.12), shape: BoxShape.circle),
                        child: Icon(r.isWithdrawal ? Icons.arrow_upward : Icons.arrow_downward,
                          color: r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE), size: 22)),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.isWithdrawal ? 'Вывод средств' : 'Добыча: ${r.title}',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(_ago(r.time), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ])),
                      Text('${r.isWithdrawal ? '-' : '+'}${r.amount} ₽',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                          color: r.isWithdrawal ? Colors.red : const Color(0xFF2AABEE))),
                    ]))));
              })),
      ]),
    );
  }
  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'только что';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    if (d.inHours < 24) return '${d.inHours} ч назад';
    return '${t.day}.${t.month.toString().padLeft(2, '0')} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
}

class WithdrawScreen extends StatefulWidget {
  final Streamer streamer;
  const WithdrawScreen({super.key, required this.streamer});
  @override
  State<WithdrawScreen> createState() => _WDState();
}

class _WDState extends State<WithdrawScreen> {
  final _amount = TextEditingController();
  String _method = 'Карта';
  int get balance => streamerWallet[widget.streamer.name] ?? 0;

  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
        title: const Text('Вывод средств', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: double.infinity, padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: const Color(0xFFFFD700).withOpacity(0.5), blurRadius: 16, offset: const Offset(0, 6))]),
            child: Column(children: [
              const Icon(Icons.account_balance_wallet, size: 40, color: Color(0xFF4A3200)),
              const SizedBox(height: 8),
              const Text('Доступно к выводу', style: TextStyle(fontSize: 13, color: Color(0xFF4A3200))),
              Text('$balance ₽', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Color(0xFF4A3200))),
            ])),
          const SizedBox(height: 24),
          const Text('Сумма вывода', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _amount, keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(hintText: '0', suffixText: '₽', filled: true, fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
          const SizedBox(height: 12),
          Row(children: [
            _quickBtn('Всё', balance), const SizedBox(width: 8),
            _quickBtn('${balance ~/ 2}', balance ~/ 2), const SizedBox(width: 8),
            _quickBtn('500', 500),
          ]),
          const SizedBox(height: 24),
          const Text('Способ вывода', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 10),
          _methodTile('Карта', 'Visa / MasterCard / МИР', Icons.credit_card),
          const SizedBox(height: 8),
          _methodTile('СБП', 'По номеру телефона', Icons.phone_iphone),
          const SizedBox(height: 8),
          _methodTile('USDT', 'TRC-20', Icons.currency_bitcoin),
          const SizedBox(height: 32),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: _withdraw,
            icon: const Icon(Icons.arrow_upward), label: const Text('Вывести', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white,
              elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
        ]),
      )),
    );
  }

  Widget _quickBtn(String label, int val) {
    return Expanded(child: Material(color: Colors.white, borderRadius: BorderRadius.circular(12),
      child: InkWell(borderRadius: BorderRadius.circular(12),
        onTap: val > 0 ? () => setState(() => _amount.text = '$val') : null,
        child: Container(padding: const EdgeInsets.symmetric(vertical: 12), alignment: Alignment.center,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))))));
  }

  Widget _methodTile(String name, String subtitle, IconData icon) {
    final selected = _method == name;
    return Material(color: Colors.white, borderRadius: BorderRadius.circular(14),
      child: InkWell(borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _method = name),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? const Color(0xFF2AABEE) : Colors.transparent, width: 2)),
          child: Row(children: [
            Container(width: 44, height: 44,
              decoration: BoxDecoration(color: const Color(0xFF2AABEE).withOpacity(0.12), shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF2AABEE), size: 22)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ])),
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: selected ? const Color(0xFF2AABEE) : Colors.grey, size: 22),
          ]))));
  }

  void _withdraw() {
    final amt = int.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) { _snack('Введите сумму больше нуля', Colors.red); return; }
    if (amt < 100) { _snack('Минимум 100 ₽', Colors.red); return; }
    if (amt > balance) { _snack('Недостаточно средств. Доступно: $balance ₽', Colors.red); return; }
    setState(() {
      streamerWallet[widget.streamer.name] = balance - amt;
      streamerHistory.putIfAbsent(widget.streamer.name, () => []);
      streamerHistory[widget.streamer.name]!.insert(0,
        EarningRecord(title: 'Вывод на $_method', amount: amt, time: DateTime.now(), isWithdrawal: true));
      _amount.clear();
    });
    _snack('Заявка на вывод $amt ₽ принята!', const Color(0xFF2AABEE));
  }

  void _snack(String t, Color c) {
    final isError = c == Colors.red || c == Colors.orange;
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + 70,
        left: 30, right: 30,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isError ? c : c.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Text(t,
                style: TextStyle(color: Colors.white, fontSize: isError ? 13 : 12, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(Duration(seconds: isError ? 2 : 1), () {
      if (entry.mounted) entry.remove();
    });
  }
}

class StreamerListScreen extends StatelessWidget {
  const StreamerListScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white, elevation: 0,
        title: const Text('Выберите стримера', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 19))),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: allStreamers.length,
        itemBuilder: (context, i) {
          final s = allStreamers[i];
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Material(color: Colors.white, borderRadius: BorderRadius.circular(16),
              child: InkWell(borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DonaterMapScreen(streamer: s))),
                child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                  CircleAvatar(radius: 28, backgroundColor: const Color(0xFF2AABEE),
                    child: Text(s.name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22))),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(s.channel, style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ])),
                  Container(padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade200, width: 1.5),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))]),
                    child: QrImageView(data: s.qrData, version: QrVersions.auto, size: 76, backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF2AABEE)),
                      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black87))),
                ])))),
          );
        }),
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
  int userBalance = 5000;
  bool _placing = false;
  DonationPoint? _sel;
  final _amount = TextEditingController();
  final _msg = TextEditingController();

  List<DonationPoint> get points {
    streamerPoints.putIfAbsent(widget.streamer.name, () => []);
    return streamerPoints[widget.streamer.name]!;
  }

  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Stack(children: [
      FlutterMap(
        options: MapOptions(
          initialCenter: const LatLng(56.0184, 92.8672), initialZoom: 13,
          onTap: (pos, latlng) {
            if (_placing) { _newPointDialog(latlng); } else { setState(() => _sel = null); }
          }),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.streamer_map_donate'),
          MarkerLayer(markers: points.map((p) => Marker(
            point: p.position, width: 100, height: 110,
            child: GestureDetector(
              onTap: _placing ? null : () => setState(() { _sel = p; _amount.clear(); }),
              child: _goldCoin(p)))).toList()),
        ],
      ),
      SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]),
          child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.black87),
            onPressed: () { if (_placing) { setState(() => _placing = false); } else { Navigator.pop(context); } })),
        const SizedBox(width: 10),
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]),
          child: Row(children: [
            CircleAvatar(radius: 18, backgroundColor: const Color(0xFF2AABEE),
              child: Text(widget.streamer.name[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.streamer.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14), overflow: TextOverflow.ellipsis)),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFFFFD700).withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
              child: Row(children: [
                const Icon(Icons.account_balance_wallet, size: 14, color: Color(0xFFB8860B)),
                const SizedBox(width: 4),
                Text('$userBalance ₽', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFB8860B))),
              ])),
          ]))),
      ]))),
      if (_placing) Positioned(top: 100, left: 20, right: 20, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(14)),
        child: const Row(children: [
          Icon(Icons.touch_app, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text('Тапните по карте, чтобы поставить точку', style: TextStyle(color: Colors.white, fontSize: 13))),
        ]))),
      if (_sel == null && !_placing) Positioned(bottom: 30, right: 20, child: FloatingActionButton.extended(
        onPressed: () => setState(() => _placing = true),
        backgroundColor: const Color(0xFF2AABEE), foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt), label: const Text('Создать точку'))),
      if (_sel != null) Positioned(left: 0, right: 0, bottom: 0, child: _donateSheet(_sel!)),
    ]));
  }

  Widget _goldCoin(DonationPoint p) {
    final isHot = p.totalAmount >= 1000;
    final isSpoiled = p.isSpoiled;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: isHot ? 72 : 62, height: isHot ? 72 : 62,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isSpoiled
            ? const RadialGradient(colors: [Color(0xFFFFAAAA), Color(0xFFE53935), Color(0xFF8B0000)], stops: [0, 0.6, 1])
            : const RadialGradient(colors: [Color(0xFFFFF3A0), Color(0xFFFFD700), Color(0xFFB8860B)], stops: [0, 0.6, 1]),
          border: Border.all(color: isSpoiled ? Colors.white : const Color(0xFFFFF8DC), width: 3),
          boxShadow: [
            BoxShadow(color: isSpoiled ? Colors.red.withOpacity(0.8) : const Color(0xFFFFD700).withOpacity(isHot ? 0.8 : 0.5),
              blurRadius: isSpoiled ? 20 : (isHot ? 18 : 10), spreadRadius: isHot ? 4 : 1),
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3)),
          ]),
        child: Center(child: Text(_fmt(p.totalAmount),
          style: TextStyle(color: isSpoiled ? Colors.white : const Color(0xFF4A3200),
            fontWeight: FontWeight.w900, fontSize: isHot ? 14 : 13)))),
      const SizedBox(height: 2),
      Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isSpoiled ? Colors.red.withOpacity(0.45) : Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(8)),
        child: Text(p.title, style: const TextStyle(color: Colors.white, fontSize: 10))),
    ]);
  }

  String _fmt(int a) {
    if (a >= 1000) { final v = a / 1000; return v == v.roundToDouble() ? '${v.toInt()}к' : '${v.toStringAsFixed(1)}к'; }
    return '$a';
  }

  Widget _donateSheet(DonationPoint p) {
    return Container(
      decoration: const BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24))),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text(p.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => setState(() => _sel = null)),
        ]),
        Container(padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [const Color(0xFFFFD700).withOpacity(0.15), const Color(0xFFFFD700).withOpacity(0.05)]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4))),
          child: Row(children: [
            const Icon(Icons.monetization_on, color: Color(0xFFB8860B), size: 36),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Уже собрано', style: TextStyle(fontSize: 12, color: Colors.grey)),
              Text('${p.totalAmount} ₽', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFFB8860B))),
            ]),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('Донатеров', style: TextStyle(fontSize: 12, color: Colors.grey)),
              Text('${p.donors.length}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ]),
          ])),
        const SizedBox(height: 16),
        const Text('Сколько скинуть?', style: TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 10),
        Row(children: [100, 300, 500, 1000].map((a) => Expanded(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(color: const Color(0xFFF0F2F5), borderRadius: BorderRadius.circular(12),
            child: InkWell(borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _amount.text = '$a'),
              child: Container(padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center, child: Text('$a', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)))),
          )))).toList()),
        const SizedBox(height: 12),
        TextField(controller: _amount, keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: 'Своя сумма', suffixText: '₽',
            prefixIcon: const Icon(Icons.edit, color: Color(0xFF2AABEE)),
            filled: true, fillColor: const Color(0xFFF0F2F5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
        const SizedBox(height: 12),
        TextField(controller: _msg, maxLength: 100,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: 'Сообщение стримеру (необязательно)',
            prefixIcon: const Icon(Icons.chat_bubble_outline, color: Color(0xFF2AABEE)),
            filled: true, fillColor: const Color(0xFFF0F2F5),
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => _send(p),
          icon: const Icon(Icons.send), label: const Text('Скинуть донат', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD700), foregroundColor: const Color(0xFF4A3200), elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
      ]),
    );
  }

  void _send(DonationPoint p) {
    final a = int.tryParse(_amount.text.trim());
    if (a == null || a <= 0) { _snack('Введите сумму больше нуля', Colors.red); return; }
    if (a < widget.streamer.minDonation) { _snack('Минимум для этого стримера: ${widget.streamer.minDonation} ₽', Colors.red); return; }
    if (a > userBalance) { _snack('Недостаточно средств. Баланс: $userBalance ₽', Colors.red); return; }
    setState(() {
      userBalance -= a;
      p.totalAmount += a;
      p.lastTopUp = DateTime.now();
      p.donors.add('Вы');
      streamerFeed.putIfAbsent(widget.streamer.name, () => []);
      streamerFeed[widget.streamer.name]!.insert(0,
        LiveDonation(donorName: 'Вы', pointTitle: p.title, amount: a, time: DateTime.now(), message: filterBadWords(_msg.text.trim()), position: p.position));
      _sel = null;
      _amount.clear();
      _msg.clear();
    });
    _snack('Донат $a ₽ отправлен!', const Color(0xFF2AABEE));
  }

  void _newPointDialog(LatLng pos) async {
    // Создание точки стоит 1000 ₽ — они сразу идут на точку
    const int kCreateCost = 1000;
    if (userBalance < kCreateCost) {
      _snack('Создание доната стоит $kCreateCost ₽. У вас: $userBalance ₽', Colors.red);
      setState(() => _placing = false);
      return;
    }

    _snack('Определяю место...', const Color(0xFF2AABEE));
    final name = await getLocationName(pos);
    if (!mounted) return;

    setState(() {
      userBalance -= kCreateCost;
      points.add(DonationPoint(
        position: pos,
        title: name,
        totalAmount: kCreateCost,
        lastTopUp: DateTime.now(),
        donors: ['Вы'],
      ));
      streamerFeed.putIfAbsent(widget.streamer.name, () => []);
      streamerFeed[widget.streamer.name]!.insert(0,
        LiveDonation(donorName: 'Вы', pointTitle: name, amount: kCreateCost, time: DateTime.now(), message: 'Создал новый донат', position: pos));
      _placing = false;
    });
    _snack('Донат «$name» создан · −$kCreateCost ₽', const Color(0xFF2AABEE));
  }


  void _snack(String t, Color c) {
    final isError = c == Colors.red || c == Colors.orange;
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
                top: MediaQuery.of(ctx).padding.top + 70, left: 30, right: 30,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isError ? c : c.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Text(t,
                style: TextStyle(color: Colors.white, fontSize: isError ? 13 : 12, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(Duration(seconds: isError ? 2 : 1), () {
      if (entry.mounted) entry.remove();
    });
  }

}

