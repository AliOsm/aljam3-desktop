<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

<h1 dir="rtl">أدوات قياس الأداء</h1>

<p dir="rtl">شغّل الأدوات على بيانات تجريبية مؤقتة داخل <code dir="ltr">.cache/benchmark</code>، وتجنّب استخدامها على مكتبتك الشخصية.</p>

```sh
mise run benchmark-data
mise run benchmark -- --prepare --pages 100000 --path .cache/benchmark/library.sqlite3
mise exec -- bundle exec ruby bench/limited.rb .cache/benchmark/library.sqlite3 .cache/benchmark/search.json
mise run benchmark-pdf -- 3435 8291 104 471
mise run verify-scroll
```

<p dir="rtl">تكرّر بيانات الاختبار عينات من النصوص المستخرجة آليًا، مع لاحقات رقمية فريدة. تقيس سلوك الاستعلامات واستهلاك الموارد؛ ولا تقيس جودة النتائج للقارئ أو سرعة البحث الفعلية. قد يستغرق إنشاء عينات كبيرة ساعات ويستهلك مساحة كبيرة.</p>

<p dir="rtl">يرتّب البحث المحلي أول 10,000 صفحة مطابقة ويوسّع النطاق عند الطلب. يقيس <code dir="ltr">limited.rb</code> هذا البحث، وتفحص السكربتات الأخرى الفهرسة والمقتطفات والبادئات وتوليد بيانات الاختبار. إضافة التخزين المؤقت للكلمات مخصّصة لتسريع توليد بيانات الاختبار فقط.</p>

<p dir="rtl">احفظ التقارير داخل <code dir="ltr">.cache/benchmark</code>. يحذف الأمر <code dir="ltr">mise run clean</code> البيانات التجريبية والتقارير.</p>
