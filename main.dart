import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:vibration/vibration.dart';

// ===== НАСТРОЙКИ (меняй под себя) =====
const maxProtectHours = 240; // верхний предел ввода (часов), только от опечаток
const rotDuration = Duration(hours: 10, minutes: 20); // от начала гниения до разрушения
const trigger1 = 'база атакована'; // тревога 1 (в нижнем регистре)
const trigger2 = 'ваш персонаж подвергся нападению'; // тревога 2

final notif = FlutterLocalNotificationsPlugin();
final alarm = ValueNotifier<int>(0); // 0 — тишина, 1 — база, 2 — персонаж
late SharedPreferences prefs;

// ===== ТРЕВОГА =====
void startAlarm(int level) {
  if (alarm.value >= level) return;
  alarm.value = level;
  FlutterRingtonePlayer().playAlarm(looping: true, volume: 1.0, asAlarm: true);
  if (level == 2) {
    Vibration.vibrate(pattern: [0, 1000, 300], repeat: 0); // непрерывно
  } else {
    Vibration.vibrate(duration: 800); // коротко
  }
}

void stopAlarm() {
  FlutterRingtonePlayer().stop();
  Vibration.cancel();
  notif.cancel(101);
  notif.cancel(102);
  alarm.value = 0;
}

Future<void> fire(int level) async {
  startAlarm(level);
  await notif.show(
    100 + level,
    level == 2 ? '🚨 ПЕРСОНАЖ ПОД АТАКОЙ' : '⚠️ БАЗА АТАКОВАНА',
    'Открой приложение и свайпни',
    const NotificationDetails(
      android: AndroidNotificationDetails('alarm', 'Тревога',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          playSound: false,
          enableVibration: false,
          ongoing: true),
    ),
    payload: 'alarm$level',
  );
}

void _fromPayload(String? p) {
  if (p != null && p.startsWith('alarm')) startAlarm(int.parse(p.substring(5)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  prefs = await SharedPreferences.getInstance();
  await notif.initialize(
    const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: (r) => _fromPayload(r.payload),
  );
  final a = notif.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await a?.requestNotificationsPermission();
  await a?.requestExactAlarmsPermission();
  final d = await notif.getNotificationAppLaunchDetails();
  if (d?.didNotificationLaunchApp ?? false) {
    _fromPayload(d!.notificationResponse?.payload);
  }
  runApp(const OxideApp());
}

class OxideApp extends StatelessWidget {
  const OxideApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const Home(),
        // тревога рисуется поверх всего приложения
        builder: (context, child) => ValueListenableBuilder<int>(
          valueListenable: alarm,
          builder: (_, a, __) => Stack(children: [
            child!,
            if (a != 0) Positioned.fill(child: AlarmScreen(level: a)),
          ]),
        ),
      );
}

class AlarmScreen extends StatelessWidget {
  final int level;
  const AlarmScreen({super.key, required this.level});
  @override
  Widget build(BuildContext context) {
    final crit = level == 2;
    const white = TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold);
    return Scaffold(
      backgroundColor: crit ? const Color(0xFFB00000) : const Color(0xFFE65100),
      body: Dismissible(
        key: ValueKey('alarm$level'),
        onDismissed: (_) => stopAlarm(), // выключение только свайпом
        child: SizedBox.expand(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(crit ? Icons.warning_amber_rounded : Icons.shield, size: 120, color: Colors.white),
            const SizedBox(height: 24),
            Text(crit ? 'ПЕРСОНАЖ ПОД АТАКОЙ!' : 'БАЗА АТАКОВАНА!', style: white),
            const SizedBox(height: 48),
            const Text('←  свайпни, чтобы выключить  →',
                style: TextStyle(color: Colors.white70, fontSize: 18)),
          ]),
        ),
      ),
    );
  }
}

// ===== ГЛАВНЫЙ ЭКРАН С НИЖНЕЙ ПАНЕЛЬЮ =====
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: IndexedStack(index: tab, children: const [GuardTab(), TimersTab()])),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.shield), label: 'Щит'),
            NavigationDestination(icon: Icon(Icons.hourglass_bottom), label: 'Таймеры'),
          ],
        ),
      );
}

// ===== ВКЛАДКА «ЩИТ» =====
class GuardTab extends StatefulWidget {
  const GuardTab({super.key});
  @override
  State<GuardTab> createState() => _GuardTabState();
}

class _GuardTabState extends State<GuardTab> {
  bool armed = false;
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    if (prefs.getBool('armed') ?? false) _arm(ask: false);
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> _arm({bool ask = true}) async {
    if (!await NotificationListenerService.isPermissionGranted()) {
      if (ask) await NotificationListenerService.requestPermission();
      return;
    }
    await sub?.cancel();
    sub = NotificationListenerService.notificationsStream.listen((e) {
      final t = '${e.title} ${e.content}'.toLowerCase();
      if (t.contains(trigger2)) {
        fire(2);
      } else if (t.contains(trigger1)) {
        fire(1);
      }
    });
    if (ask) await Permission.ignoreBatteryOptimizations.request();
    prefs.setBool('armed', true);
    if (mounted) setState(() => armed = true);
  }

  Future<void> _disarm() async {
    await sub?.cancel();
    prefs.setBool('armed', false);
    setState(() => armed = false);
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          GestureDetector(
            onTap: armed ? _disarm : _arm,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: armed ? Colors.green[700] : Colors.grey[800],
                boxShadow: [BoxShadow(color: armed ? Colors.greenAccent.withOpacity(.4) : Colors.black54, blurRadius: 30)],
              ),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: Text(armed ? 'ПОД ОХРАНОЙ\n(нажми, чтобы снять)' : 'Поставить на охрану',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 32),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton(onPressed: () => fire(1), child: const Text('Тест 1')),
            TextButton(onPressed: () => fire(2), child: const Text('Тест 2')),
          ]),
        ]),
      );
}

// ===== ВКЛАДКА «ТАЙМЕРЫ ГНИЕНИЯ» =====
String _fmt(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.inHours}ч ${two(d.inMinutes % 60)}м ${two(d.inSeconds % 60)}с';
}

class TimersTab extends StatefulWidget {
  const TimersTab({super.key});
  @override
  State<TimersTab> createState() => _TimersTabState();
}

class _TimersTabState extends State<TimersTab> {
  List<Map<String, dynamic>> houses = [];
  Timer? ticker;

  @override
  void initState() {
    super.initState();
    houses = (jsonDecode(prefs.getString('houses') ?? '[]') as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  void _save() => prefs.setString('houses', jsonEncode(houses));
  DateTime _start(Map h) => DateTime.fromMillisecondsSinceEpoch(h['s'] as int);
  Duration _protect(Map h) => Duration(minutes: (h['p'] as int?) ?? 12 * 60);
  String _hoursText(int m) => m % 60 == 0 ? '${m ~/ 60}' : (m / 60).toStringAsFixed(1);

  Future<void> _schedule(Map h) async {
    final id = h['id'] as int;
    final rotAt = _start(h).add(_protect(h));
    await notif.cancel(id);
    if (!rotAt.isAfter(DateTime.now())) return;
    await notif.zonedSchedule(
      id,
      '🏠 ${h['n']}',
      'Внимание, дом начал гнить. Осталось ${rotDuration.inHours} ч ${rotDuration.inMinutes % 60} мин',
      tz.TZDateTime.from(rotAt, tz.UTC),
      const NotificationDetails(
          android: AndroidNotificationDetails('rot', 'Гниение',
              importance: Importance.high, priority: Priority.high)),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // Диалог: название дома + на сколько часов закинул ресурсы
  Future<Map<String, dynamic>?> _ask({String name = '', String hours = ''}) {
    final nameC = TextEditingController(text: name);
    final hoursC = TextEditingController(text: hours);
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Сколько часов закинул?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: 'Название дома')),
          TextField(
            controller: hoursC,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Часов пропитки (например 5 или 24)', hintText: '5'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              final v = double.tryParse(hoursC.text.replaceAll(',', '.').trim());
              if (v == null || v <= 0) return;
              Navigator.pop(ctx, {
                'n': nameC.text.trim().isEmpty ? 'Дом' : nameC.text.trim(),
                'p': (v.clamp(0.1, maxProtectHours.toDouble()) * 60).round(),
              });
            },
            child: const Text('Запустить'),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final r = await _ask();
    if (r == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final h = <String, dynamic>{'id': now % 1000000000, 'n': r['n'], 'p': r['p'], 's': now};
    houses.add(h);
    _save();
    await _schedule(h);
    setState(() {});
  }

  Widget _card(Map<String, dynamic> h, DateTime now) {
    final rotAt = _start(h).add(_protect(h));
    final deadAt = rotAt.add(rotDuration);
    final rotting = !now.isBefore(rotAt);
    final dead = !now.isBefore(deadAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(h['n'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            IconButton(
              tooltip: 'Снова закинул ресурсы',
              icon: const Icon(Icons.restart_alt),
              onPressed: () async {
                final r = await _ask(
                    name: h['n'] as String, hours: _hoursText(_protect(h).inMinutes));
                if (r == null) return;
                h['n'] = r['n'];
                h['p'] = r['p'];
                h['s'] = DateTime.now().millisecondsSinceEpoch;
                _save();
                await _schedule(h);
                setState(() {});
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                notif.cancel(h['id'] as int);
                houses.remove(h);
                _save();
                setState(() {});
              },
            ),
          ]),
          Text('Закинуто на ${_hoursText(_protect(h).inMinutes)} ч',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          Text(rotting ? 'До начала гниения: уже гниёт 🟠' : 'До начала гниения: ${_fmt(rotAt.difference(now))}'),
          Text(dead ? 'Дом разрушен 💀' : 'До полного разрушения: ${_fmt(deadAt.difference(now))}',
              style: TextStyle(color: rotting ? Colors.redAccent : null)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: houses.isEmpty
          ? const Center(child: Text('Нажми «+», когда закинешь ресурсы в дом'))
          : ListView(padding: const EdgeInsets.all(12), children: [for (final h in houses) _card(h, now)]),
    );
  }
}
