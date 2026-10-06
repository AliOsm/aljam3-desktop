<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

<h1 dir="rtl">تعديلات PDFium</h1>

<p dir="rtl">يثبّت <code dir="ltr">bin/build-pdfium</code> نسخًا محددة من PDFium وسكربتات البناء وأدوات depot. تشمل بصمة الإصدار سكربت البناء وهذه التعديلات؛ لذلك يُعاد البناء عند تغييرها.</p>

<ul dir="rtl">
  <li><code dir="ltr">handle-stream-read-errors.patch</code>: يعيد خطأ عند فشل قراءة HTTP أو إلغائها، ليعالجها Ruby دون انهيار المحرّك.</li>
  <li><code dir="ltr">skip-page-branches.patch</code>: يتجاوز فروع شجرة الصفحات غير المطلوبة عند الانتقال البعيد، ويبدأ الاجتياز من جديد عند الحاجة للعودة إلى صفحات سابقة.</li>
  <li><code dir="ltr">zz-page-index-prefetch.patch</code>: يتيح مواقع قواميس الصفحات لجلب الفهارس المسطّحة بالتوازي ضمن حدود محددة. يظل PDFium مسؤولًا عن التحقق من كل صفحة واختيارها.</li>
</ul>

```sh
mise exec -- bundle exec ruby bin/verify-ui pdf
mise run verify-scroll
mise run benchmark-pdf -- 3435 8291 104 471
```

<p dir="rtl">يفحص <code dir="ltr">ruby bin/verify-package --pdf-only</code> حزمة مبنية مسبقًا. تشمل الاختبارات فشل القراءة والإلغاء وصور الصفحات والتنقل والتكبير والتمرير مع الإنترنت ودونه. تستخدم القراءة عبر الإنترنت نطاقات البايتات، بينما يحفظ التنزيل الصريح ملفات PDF كاملة.</p>
