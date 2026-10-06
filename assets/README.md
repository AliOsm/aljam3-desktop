# مصادر الرسومات والخطوط

- الشعار وأيقونات التشكيل: [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). ملفات SVG الأصلية محفوظة، وتُستخدم نسخ PNG في الواجهة. أيقونة التطبيق هي الشعار على خلفية بيضاء.
- الخطوط: [faqieh-web-app](https://github.com/ieasybooks/faqieh-web-app/tree/cc1c9e0e22ee729f39bab45c6af34abd1f204d8d). حُوّلت ملفات WOFF2 إلى TTF دون تغيير أشكال الحروف أو بيانات الترخيص.
- خطّا Noto Naskh Arabic UI وKitab: ترخيص SIL Open Font محفوظ في `fonts/OFL.txt` و`fonts/OFL-Kitab.txt`.
- خط Thmanyah Serif Display Medium، الإصدار 1.003: [الملف الرسمي](https://framerusercontent.com/assets/ahIxG21c1088n0jA0bPQBjKu6M.woff2)، وبصمة SHA-256 هي `ef836058036ef2760e12af676b7fe0377f7401aed4fa94c6df1247ad17cd54f2`. إذن إعادة التوزيع لم يُحسم بعد؛ بيانات الترخيص المضمّنة محفوظة.
- الأيقونات القياسية: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons)، بترخيص ISC المحفوظ في `icons/LICENSE`.

تتبع ألوان الوضعين الفاتح والداكن ألوان الموقع في `lib/aljam3/ui/theme.rb`. تُنشأ صور PNG من ملفات SVG باستخدام CairoSVG؛ لا يحتاج تشغيل التطبيق إلى أدوات التحويل.
