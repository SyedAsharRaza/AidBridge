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
  String get silence => _p('SILENCE', 'خاموش کریں');
  String get nextAlert => _p('GOT IT — NEXT ALERT', 'سمجھ گیا — اگلا الرٹ');
  String get nameRequired => _p('Enter a call sign first — it is how rescuers will see you',
      'پہلے اپنا نام لکھیں — ریسکیو ٹیم آپ کو اسی نام سے دیکھے گی');
  String get saveFailed => _p('Could not save on this phone — try once more',
      'اس فون پر محفوظ نہیں ہو سکا — دوبارہ کوشش کریں');
  String get sosNotReady => _p('Mesh is still starting — try again in a moment',
      'میش ابھی شروع ہو رہا ہے — ایک لمحے بعد دوبارہ کوشش کریں');
  String get sosBusy => _p('Your SOS is being sent…', 'آپ کا ایس او ایس بھیجا جا رہا ہے…');
  String get sosCooldown => _p('Just sent — wait a few seconds before sending another',
      'ابھی بھیجا گیا ہے — دوبارہ بھیجنے سے پہلے چند لمحے رکیں');
  String get sosAlreadyActive => _p('Your SOS is already active — tap I\'M SAFE first',
      'آپ کا ایس او ایس پہلے سے فعال ہے — پہلے میں محفوظ ہوں دبائیں');
  String get howItWorksCivilianTitle => _p('HOW AIDBRIDGE WORKS FOR YOU', 'ایڈبرج آپ کے لیے کیسے کام کرتا ہے');
  String get howItWorksNgoTitle => _p('HOW AIDBRIDGE WORKS FOR YOU', 'ایڈبرج آپ کے لیے کیسے کام کرتا ہے');
  List<String> get civilianHowPoints => [
    _p('Your phone joins the mesh the moment you open the app — no signup, no internet needed.',
        'ایپ کھولتے ہی آپ کا فون میش کا حصہ بن جاتا ہے — کوئی سائن اپ نہیں، انٹرنیٹ کی ضرورت نہیں۔'),
    _p('Hold the SOS button to send a distress call. It reaches every phone in range instantly, even with zero signal.',
        'ایس او ایس بٹن دبا کر رکھیں۔ یہ سگنل نہ ہونے کے باوجود ارد گرد موجود ہر فون تک فوراً پہنچتا ہے۔'),
    _p('Out of range does not mean lost. Any nearby phone remembers your SOS and carries it to the next person it meets — even hours later.',
        'رینج سے باہر ہونے کا مطلب ختم ہونا نہیں۔ کوئی بھی قریبی فون آپ کا ایس او ایس یاد رکھتا ہے اور اگلے ملنے والے فون تک پہنچاتا ہے — چاہے گھنٹوں بعد ہو۔'),
    _p('The moment ANY phone carrying your SOS touches the internet, it reaches the relief team automatically.',
        'جیسے ہی آپ کا ایس او ایس اٹھائے کوئی بھی فون انٹرنیٹ سے جڑتا ہے، یہ خود بخود امدادی ٹیم تک پہنچ جاتا ہے۔'),
    _p('You are also a carrier. Every phone relays every SOS it hears — you might help save someone without even knowing it.',
        'آپ بھی ایک راستہ ہیں۔ ہر فون ہر ایس او ایس آگے بڑھاتا ہے — آپ کسی کو بچانے میں مدد دے سکتے ہیں بغیر جانے بھی۔'),
    _p('Tap I\'M SAFE the moment you are out of danger — that message travels the same way, so no rescuer chases a ghost.',
        'خطرے سے باہر ہوتے ہی "میں محفوظ ہوں" دبائیں — یہ پیغام بھی اسی طرح سفر کرتا ہے، تاکہ کوئی ریسکیو ٹیم خالی جگہ نہ ڈھونڈے۔'),
  ];
  List<String> get ngoHowPoints => [
    _p('You are the exit point. The moment your phone gets any signal, every distress call it is carrying uploads to the live dashboard automatically.',
        'آپ اخراج کا مقام ہیں۔ آپ کے فون کو سگنل ملتے ہی، اس کے پاس موجود ہر ایس او ایس خود بخود ڈیش بورڈ پر چلا جاتا ہے۔'),
    _p('You do not have to be near the emergency. A phone that has been offline for hours can still hand you incidents fired long before you arrived.',
        'آپ کا واقعے کے قریب ہونا ضروری نہیں۔ گھنٹوں سے آف لائن فون بھی آپ کو وہ واقعات دے سکتا ہے جو آپ کے آنے سے بہت پہلے پیش آئے۔'),
    _p('Every incident on your dashboard shows how many hops it traveled — proof it reached you without a single tower.',
        'ڈیش بورڈ پر ہر واقعہ یہ ظاہر کرتا ہے کہ وہ کتنے فونز سے گزر کر پہنچا — بغیر کسی ٹاور کے پہنچنے کا ثبوت۔'),
    _p('When someone reports safe, it resolves everywhere the alert had spread — so you are never dispatched on a false alarm.',
        'جب کوئی خود کو محفوظ بتاتا ہے، تو یہ پیغام ہر جگہ سے ختم ہو جاتا ہے جہاں الرٹ پہنچا تھا — تاکہ آپ غلط الارم پر نہ بھیجے جائیں۔'),
    _p('Your phone is a relay too. Even while you coordinate relief, it keeps carrying signals for others still in range.',
        'آپ کا فون بھی ایک ذریعہ ہے۔ امداد کو منظم کرتے ہوئے بھی، یہ ارد گرد موجود دوسروں کے پیغامات آگے پہنچاتا رہتا ہے۔'),
  ];
  String get howItWorksContinue => _p('GOT IT — LET\'S GO', 'سمجھ گیا — چلیں');
  String get howItWorksLink => _p('How does this work?', 'یہ کیسے کام کرتا ہے؟');
    String get ngoCommandTitle => _p('AIDBRIDGE COMMAND', 'ایڈبرج کمانڈ');
  String get civilianViewBtn => _p('CIVILIAN VIEW', 'شہری ویو');
  String get tabIncidents => _p('INCIDENTS', 'واقعات');
  String get tabMap => _p('MAP', 'نقشہ');
  String get tabBridge => _p('BRIDGE', 'برج');
  String get bridgeReadyLabel => _p('BRIDGE', 'برج');
  String get bridgeReadyStatus => _p('READY — uplinks on sight', 'تیار — نظر آتے ہی اپ لوڈ ہوگا');
  String get meshLabel => _p('MESH', 'میش');
  String get onlineLabel => _p('ONLINE', 'آن لائن');
  String get offlineLabel => _p('OFFLINE', 'آف لائن');
  String get peersConnected => _p('PEERS CONNECTED', 'جڑے ہوئے فونز');
  String get notebookCarriedLabel => _p('NOTEBOOK CARRIED', 'محفوظ شدہ خطوط');
  String get dedupMemoryLabel => _p('DEDUP MEMORY', 'ڈی ڈپ میموری');
  String get bridgeExplain => _p(
      'Any phone with internet becomes a bridge: SOS letters ride the mesh to it, then teleport to this cloud. Chat never leaves the mesh (privacy partition).',
      'انٹرنیٹ والا کوئی بھی فون برج بن جاتا ہے: ایس او ایس پیغامات میش کے ذریعے اس تک پہنچتے ہیں، پھر کلاؤڈ پر منتقل ہو جاتے ہیں۔ چیٹ کبھی میش سے باہر نہیں جاتی۔');
  String get liveMeshLog => _p('LIVE MESH LOG', 'لائیو میش لاگ');
  String get waitingRadioTraffic => _p('waiting for radio traffic…', 'ریڈیو ٹریفک کا انتظار…');
  String get noIncidents => _p('No incidents in sight.\n(connect victims via mesh or internet)',
      'ابھی کوئی واقعہ نظر نہیں آ رہا۔\n(میش یا انٹرنیٹ کے ذریعے متاثرین سے رابطہ کریں)');
  String get coordinatesCopied => _p('Coordinates copied', 'کوآرڈینیٹس کاپی ہو گئے');
  String get callLabel => _p('CALL', 'کال کریں');
  String get cloudSrc => _p('cloud ☁', 'کلاؤڈ ☁');
  String get localMeshSrc => _p('local mesh 📻', 'مقامی میش 📻');
  String get localSrcShort => _p('📻 local', '📻 مقامی');
  String get cloudSrcShort => _p('☁ cloud', '☁ کلاؤڈ');
  String get osmNeedsInternet => _p('tiles: OpenStreetMap (needs internet)', 'نقشہ: OpenStreetMap (انٹرنیٹ درکار)');

  String activeSummary(int active, int total, {required bool cloudError}) => cloudError
      ? _p('⚠ $active ACTIVE   •   $total total   •   ☁ CLOUD FEED UNAVAILABLE — local mesh only',
          '⚠ $active فعال   •   کل $total   •   ☁ کلاؤڈ فیڈ دستیاب نہیں — صرف مقامی میش')
      : _p('⚠ $active ACTIVE   •   $total total   •   ☁ live Firestore feed ⋯ local notebook merged',
          '⚠ $active فعال   •   کل $total   •   ☁ لائیو فیڈ ⋯ مقامی نوٹ بک ضم شدہ');
  String notebookLetters(int n) => _p('$n letters', '$n خطوط');
  String locatedIncidents(int n) => _p('📍 $n located incidents  •  ${osmNeedsInternet}',
      '📍 $n مقام والے واقعات  •  $osmNeedsInternet');
}

String timeAgo(int epochSec, {bool ur = false}) {
  final d = DateTime.now().toUtc().difference(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true));
  if (d.inSeconds < 60) return ur ? 'ابھی ابھی' : 'just now';
  if (d.inMinutes < 60) return ur ? '${d.inMinutes} منٹ پہلے' : '${d.inMinutes}m ago';
  if (d.inHours < 24) return ur ? '${d.inHours} گھنٹے پہلے' : '${d.inHours}h ago';
  return ur ? '${d.inDays} دن پہلے' : '${d.inDays}d ago';
}