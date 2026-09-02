import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLang { en, ur }

final localeProvider = StateNotifierProvider<LocaleStore, AppLang>((ref) => LocaleStore()..load());

class LocaleStore extends StateNotifier<AppLang> {
  LocaleStore() : super(AppLang.en);
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    state = (p.getString('lang') == 'ur') ? AppLang.ur : AppLang.en;
  }
  Future<void> set(AppLang l) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lang', l == AppLang.ur ? 'ur' : 'en');
    state = l;
  }
}

final stringsProvider = Provider<S>((ref) => S(ref.watch(localeProvider)));

class S {
  final AppLang lang; const S(this.lang);
  String _p(String en, String ur) => lang == AppLang.ur ? ur : en;
  bool get isRtl => lang == AppLang.ur;

  String get appTagline => _p('Offline disaster mesh — no internet needed', 'آف لائن ڈیزاسٹر میش — انٹرنیٹ کی ضرورت نہیں');
  String get callSign => _p('Your callsign', 'آپ کا نام');
  String get phoneOpt => _p('Phone number (optional — if this device has a SIM)', 'فون نمبر (اختیاری — اگر اس ڈیوائس میں سم ہے)');
  String get consent => _p('Your SOS, location and contact will be shared with nearby phones and relief organizations.',
      'آپ کا ایس او ایس، مقام اور رابطہ قریبی فونز اور امدادی اداروں کے ساتھ شیئر ہوگا۔');
  String get startApp => _p('ENTER AIDBRIDGE', 'ایڈبرج میں داخل ہوں');
  String get radiosNote => _p('Keep Bluetooth & Location ON. Keep the app alive while relaying.', 'بلوٹوتھ اور لوکیشن آن رکھیں۔ ریلے کے دوران ایپ چلتی رکھیں۔');
  String get tabSos => _p('SOS', 'ایس او ایس');
  String get tabAlerts => _p('ALERTS', 'الرٹس');
  String get tabSettings => _p('SETTINGS', 'سیٹنگز');
  String get holdToFire => _p('HOLD TO SEND SOS', 'ایس او ایس بھیجنے کے لیے دبا کر رکھیں');
  String get offline => _p('OFFLINE MESH — will relay when peers connect', 'آف لائن — فونز ملتے ہی ریلے ہوگا');
  String get broadcasting => _p('BROADCASTING • SEEN BY', 'نشر ہو رہا ہے • دیکھا گیا');
  String get imSafe => _p("✓ I'M SAFE — resolve my SOS", '✓ میں محفوظ ہوں — ایس او ایس ختم کریں');
  String get seenByN => _p('peers', 'فونز');
  String get viaPhones => _p('via', 'کے ذریعے');
  String get active => _p('ACTIVE', 'فعال');
  String get resolved => _p('SAFE', 'محفوظ');
  String get expired => _p('EXPIRED', 'ختم شدہ');
  String get catMedical => _p('Medical', 'طبی');
  String get catWater => _p('Water/Food', 'پانی/خوراک');
  String get catRescue => _p('Rescue', 'ریسکیو');
  String get catCustom => _p('Other', 'دیگر');
  String get noteOpt => _p('Note (optional)', 'نوٹ (اختیاری)');
  String get incomingSos => _p('INCOMING SOS', 'موصولہ ایس او ایس');
  String get stopSiren => _p('GOT IT — STOP SIREN', 'سمجھ گیا — سائرن بند کریں');
  String get sirenTest => _p('Siren test', 'سائرن ٹیسٹ');
  String get meshStatus => _p('Mesh status', 'میش کی صورتحال');
  String get role => _p('Role', 'کردار');
  String get civilian => _p('Civilian', 'شہری');
  String get ngo => _p('NGO / Relief', 'این جی او');
  String get save => _p('SAVE', 'محفوظ کریں');
  String get language => _p('Language', 'زبان');
  String get noAlerts => _p('No distress signals in the notebook yet.', 'ابھی کوئی ایس او ایس نہیں ملا۔');
  String get chooseRole => _p('I am joining as', 'میں شامل ہو رہا ہوں بطور');
  String get civilianHint => _p('Send SOS and relay others', 'ایس او ایس بھیجیں اور دوسروں کا پیغام آگے پہنچائیں');
  String get ngoHint => _p('Monitor incidents, coordinate relief', 'واقعات دیکھیں، امداد کو منظم کریں');
  String get restartMesh => _p('RESTART MESH', 'میش دوبارہ شروع کریں');
  String get restartingMesh => _p('Restarting mesh…', 'میش دوبارہ شروع ہو رہا ہے…');
  String get fixIt => _p('FIX', 'ٹھیک کریں');
  String get radiosOffTitle => _p('RADIOS OFF', 'ریڈیو بند ہیں');
  String get clearNotebook => _p('CLEAR NOTEBOOK', 'نوٹ بک خالی کریں');
  String get clearNotebookQ => _p('Erase every carried letter on THIS phone? Nearby phones keep their own copies.',
      'اس فون پر محفوظ تمام پیغامات مٹا دییں؟ قریبی فون اپنی نقل رکھیں گے۔');
  String get cancel => _p('CANCEL', 'منسوخ');
  String get erase => _p('ERASE', 'مٹا دیں');
  String get notebookCleared => _p('Notebook cleared', 'نوٹ بک خالی کر دی گئی');
}

String timeAgo(int epochSec, {bool ur = false}) {
  final d = DateTime.now().toUtc().difference(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true));
  if (d.inSeconds < 60) return ur ? 'ابھی ابھی' : 'just now';
  if (d.inMinutes < 60) return ur ? '${d.inMinutes} منٹ پہلے' : '${d.inMinutes}m ago';
  if (d.inHours < 24) return ur ? '${d.inHours} گھنٹے پہلے' : '${d.inHours}h ago';
  return ur ? '${d.inDays} دن پہلے' : '${d.inDays}d ago';
}