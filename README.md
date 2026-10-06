<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

<h1 dir="rtl">الجامع لسطح المكتب</h1>

<p dir="rtl">تطبيق عربي لمكتبة <a href="https://aljam3.com">الجامع</a>، مبني باستخدام Ruby و<a href="https://github.com/scarpe-team/scarpe" dir="ltr">Scarpe</a>. تصفّح الكتب وابحث في عناوينها ونصوصها، واقرأ ملفات PDF مع النص، ونزّل الكتب أو تصنيفًا كاملًا للقراءة والبحث دون إنترنت.</p>

<p dir="rtl">يدعم ماك بمعالجات Apple silicon على macOS 13 فأحدث، وويندوز 10 و11 بمعمارية x64، وويندوز 11 ARM بالمحاكاة.</p>

<h2 dir="rtl">التنزيل والتثبيت</h2>

<p dir="rtl">تتوفر الحزم في <a href="https://github.com/ieasybooks/aljam3-desktop/releases">صفحة الإصدارات</a>.</p>

<ul dir="rtl">
  <li><strong>ماك:</strong> افتح ملف DMG، واسحب التطبيق إلى مجلد التطبيقات، ثم افتحه من هناك. التطبيق غير موثّق لدى Apple؛ قد تحتاج إلى اختيار «فتح على أي حال» من «إعدادات النظام ← الخصوصية والأمان».</li>
  <li><strong>ويندوز:</strong> شغّل ملف التثبيت EXE. قد يظهر تنبيه SmartScreen لأن التطبيق غير موقّع بشهادة مطوّر.</li>
</ul>

<p dir="rtl">يتحقق التطبيق من التحديثات يوميًا وينزّلها في الخلفية بعد التحقق من توقيعها الرقمي. يمكنك أيضًا استخدام أيقونة التحديث، ثم اختيار «إعادة التشغيل والتحديث». تبقى الكتب والإعدادات ومواضع القراءة محفوظة.</p>

<h2 dir="rtl">التشغيل من المصدر</h2>

<p dir="rtl">ثبّت <a href="https://mise.jdx.dev" dir="ltr">mise</a> وGit وcurl وPython وأدوات C/C++. يحتاج ماك إلى Xcode Command Line Tools، وويندوز إلى أدوات Visual Studio C++ وGit Bash، ولينكس إلى pkg-config.</p>

```sh
mise trust
mise install
mise run setup
mise run start
```

<p dir="rtl">يثبّت الإعداد نسخًا محددة من الاعتماديات، ويبني محرّك الواجهة وPDFium؛ لذلك يستغرق التشغيل الأول وقتًا أطول. يتطلب فتح التطبيق على لينكس بيئة سطح مكتب رسومية.</p>

<h2 dir="rtl">التطوير والإصدارات</h2>

```sh
mise run test          # اختبارات التطبيق
mise run test-native   # اختبارات محرّك الواجهة
mise run verify-ui     # اختبارات القارئ والواجهة
mise run verify-scroll # اختبارات التمرير والتكبير بالإيماءات
mise run package       # بناء التطبيق على ماك أو ويندوز
mise run installer     # إنشاء مثبّت ويندوز، ويتطلب Inno Setup 6
mise run dmg           # إنشاء حزمة DMG للتطبيق المبني
mise run clean         # حذف الحزم والتقارير والبيانات المؤقتة
```

<p dir="rtl">لإعداد إصدار، حدّث <code dir="ltr">lib/aljam3/version.rb</code> ثم شغّل <strong>Build packages</strong> يدويًا في GitHub Actions. اختر <code dir="ltr">draft</code> في حقل <code dir="ltr">release</code> لإعداد مسودة بعد اجتياز اختبارات المنصات، أو <code dir="ltr">publish</code> للنشر مباشرة. تنتهي صلاحية ملفات Actions المؤقتة بعد يوم؛ احذف تشغيلات الاختبار بعد مراجعتها.</p>

<p dir="rtl">تُوقّع بيانات التحديث باستخدام سرّ المستودع <code dir="ltr">UPDATE_PRIVATE_KEY</code>. احتفظ بنسخة احتياطية مستقلة من المفتاح الخاص؛ المفتاح العام موجود في <code dir="ltr">packaging/update-public.pem</code>. يستخدم ماك <a href="https://sparkle-project.org" dir="ltr">Sparkle</a> للتحديث، ويستخدم ويندوز المثبّت مع نسخة استرداد من التطبيق السابق.</p>

<p dir="rtl">أدوات قياس الأداء في <a href="bench/README.md" dir="ltr">bench/</a>، وتعديلات PDFium في <a href="packaging/pdfium/README.md" dir="ltr">packaging/pdfium/</a>.</p>

<h2 dir="rtl">البيانات والعمل دون إنترنت</h2>

<p dir="rtl">تُحفظ الكتب والإعدادات ومواضع القراءة خارج مجلد التطبيق:</p>

<ul dir="rtl">
  <li>ماك: <code dir="ltr">~/Library/Application Support/Aljam3</code></li>
  <li>ويندوز: <code dir="ltr">%LOCALAPPDATA%/Aljam3</code></li>
  <li>لينكس: <code dir="ltr">${XDG_DATA_HOME:-~/.local/share}/aljam3</code></li>
</ul>

<p dir="rtl">يمكن تغيير الموقع باستخدام <code dir="ltr">ALJAM3_DATA_DIR</code>. تتطلب القراءة والبحث دون إنترنت اكتمال التنزيل. يرتّب البحث المحلي أول 10,000 صفحة مطابقة، ويوسّع النطاق عند اختيار «البحث في المزيد»؛ لذلك قد تختلف النتائج عن البحث عبر الإنترنت.</p>

<p dir="rtl">مصادر الرسومات والخطوط وتراخيصها موضّحة في <a href="assets/README.md" dir="ltr">assets/</a>. يحتفظ الإعداد بتراخيص <a href="https://pdfium.googlesource.com/pdfium/" dir="ltr">PDFium</a> و<a href="https://github.com/yshalsager/sqlite-tokenizer-ar" dir="ltr">sqlite-tokenizer-ar</a> داخل <code dir="ltr">vendor/</code>.</p>
