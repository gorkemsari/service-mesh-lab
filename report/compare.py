"""Diller arası kıyas raporu (generate.py tarafından, sonuçlarda birden fazla dil varsa çağrılır).

Aynı testler aynı mesh'lerde her dilin chainsvc uygulamasıyla koşulur. Bu rapor iki soruyu cevaplar:
  1. Uygulama dili mutlak değerleri (gecikme, CPU, bellek, başlangıç süresi) nasıl değiştiriyor?
  2. Mesh'in etkisi (aynı dilde mesh'li değer - mesh'siz değer) dile göre değişiyor mu?
Çıktı: <out>/karsilastirma.html ve <out>/karsilastirma.md
"""
from generate import CSS, MESH_NAMES, MESH_ORDER, STATUS_ICON, STATUS_TR, esc, fmt, lang_name, num

# (başlık, test, metrik, birim) — metrik None ise türetilir (bkz. value())
ITEMS = [
    ("Orta yükte uçtan uca p99", "P01", "stage1.p99_ms", "ms"),
    ("SLO kırılma noktası (aşamalar arası tahmin)", "P01", "derived.knee_slo_est_rps", "RPS"),
    ("Sabit yükte (250 RPS) uçtan uca p50", "P05", "load.p50_ms", "ms"),
    ("Sabit yükte (250 RPS) uçtan uca p99", "P05", "load.p99_ms", "ms"),
    ("Uygulama CPU, 250 RPS (tüm shop pod'ları)", "P05", "load.app.cpu_cores", "çekirdek"),
    ("Uygulama belleği, pod başına (yük altında)", "P05", "app_mem_per_pod", "MiB"),
    ("Veri düzlemi CPU, 250 RPS", "P05", "dataplane.cpu_cores", "çekirdek"),
    ("Uygulama pod'u başına veri düzlemi belleği", "P05", "dataplane.mem_per_pod_mib", "MiB"),
    ("Ani yük sırasında p99", "P03", "spike.p99_ms", "ms"),
    ("Uzun yükte p99", "P02", "p99_ms", "ms"),
    ("Pod hazır olma süresi (medyan)", "P06", "ready_p50_s", "sn"),
    ("Pod kaybında başarısız istek", "R03", "failed_requests", "istek"),
]
HIGHER_IS_BETTER = {"derived.knee_slo_est_rps"}


def value(ctx, test, key, mesh):
    mt = ctx["data"].get((test, mesh), {}).get("metrics", {})
    if key == "app_mem_per_pod":
        mem, n = mt.get("load.app.mem_mib"), mt.get("load.app.containers")
        return mem / n if num(mem) and num(n) and n else None
    return mt.get(key)


def effect(ctx, test, key, mesh):
    """Mesh etkisi: aynı dilde mesh'li - mesh'siz (mutlak fark, yüzde)."""
    v, base = value(ctx, test, key, mesh), value(ctx, test, key, "none")
    if mesh == "none" or not (num(v) and num(base)):
        return None, None
    return v - base, ((v - base) / base * 100) if base else None


def fmt_effect(d, pct, unit):
    if d is None:
        return "—"
    s = ("+" if d >= 0 else "") + fmt(d, unit)
    return f"{s} ({'+' if pct >= 0 else ''}{pct:.0f}%)" if pct is not None else s


def tables(ctxs):
    """[(başlık, test, birim, satırlar)]; satır: (mesh, [(değer, etki_metni) her dil için])"""
    langs = list(ctxs)
    meshes = [m for m in MESH_ORDER if any(m in c["meshes"] for c in ctxs.values())]
    out = []
    for label, test, key, unit in ITEMS:
        rows = []
        for m in meshes:
            cells = []
            for lang in langs:
                c = ctxs[lang]
                d, pct = effect(c, test, key, m)
                cells.append((value(c, test, key, m), fmt_effect(d, pct, unit)))
            if any(num(v) for v, _ in cells):
                rows.append((m, cells))
        if rows:
            out.append((label, test, key, unit, rows))
    return langs, meshes, out


def status_matrix(ctxs, meshes):
    tests = sorted({t for c in ctxs.values() for (t, _m) in c["data"]})
    rows = []
    for t in tests:
        cells = []
        for m in meshes:
            cells.append([(lang, c["data"].get((t, m), {}).get("status")) for lang, c in ctxs.items()])
        rows.append((t, cells))
    return rows


NOTES = [
    "Her dil kendi oturumunda, aynı ortam, aynı mesh kurulumu (her mesh x dil için sıfırdan kurulmuş cluster), aynı test sırası ve aynı yükle ölçülür.",
    "Mesh etkisi = aynı dilde mesh'li değer − mesh'siz değer. Mesh'in kendi maliyeti dile bağlı değilse bu fark diller arasında benzer çıkar; "
    "dile bağlı fark çoğunlukla bağlantı yönetimi, HTTP/2 akış sınırları ve uygulama gecikmesinin yapısından gelir.",
    "Servislerin işlem süresi yapaydır (1–5 ms); diller arası mutlak gecikme farkı gerçek iş yükünü değil çalışma zamanı + istemci/sunucu yığınını yansıtır.",
    "Tablolardaki değerler tekrarların medyanıdır; ayrıntı ve yayılım her dilin kendi raporundadır (<dil>/rapor.html).",
]


def render_html(ctxs):
    langs, meshes, tbls = tables(ctxs)
    any_ctx = next(iter(ctxs.values()))
    e = []
    w = e.append
    w(f'<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      f'<title>Diller Arası Kıyas</title><style>{CSS}</style></head><body><main>')
    w('<p class="mut small">service-mesh-lab</p><h1>Diller Arası Kıyas</h1>')
    w(f'<p class="mut">Diller: {esc(", ".join(f"{lang_name(x)} ({ctxs[x]["versions"].get("app_runtime", "")})" for x in langs))} · '
      f'Oluşturma: {any_ctx["now"]:%d.%m.%Y %H:%M} · Oturum(lar): {esc(", ".join(sorted({s for c in ctxs.values() for s in c["sessions"]})) or "—")}</p>')
    w('<p>Dil başına tam raporlar: ' + " · ".join(f'<a href="{x}/rapor.html">{esc(lang_name(x))}</a>' for x in langs) + "</p>")
    w('<h2>1. Temel göstergeler</h2><p class="mut small">Her dil için değer ve parantez içinde mesh etkisi (aynı dilde mesh\'siz referansa göre).</p>')
    for label, test, key, unit, rows in tbls:
        better_high = key in HIGHER_IS_BETTER
        w(f'<h3>{esc(label)} <span class="mut small">{test} · {esc(key)}</span></h3><div class="wrap"><table><tr><th>Mesh</th>')
        for x in langs:
            w(f'<th class="n">{esc(lang_name(x))}</th><th class="n">{esc(lang_name(x))}: mesh etkisi</th>')
        w("</tr>")
        for m, cells in rows:
            nums = [v for v, _ in cells if num(v)]
            best = (max(nums) if better_high else min(nums)) if len(nums) > 1 else None
            w(f"<tr><td>{esc(MESH_NAMES[m])}</td>")
            for v, eff in cells:
                b = ' style="font-weight:700"' if best is not None and v == best else ""
                w(f'<td class="n"{b}>{esc(fmt(v, unit))}</td><td class="n mut">{esc(eff)}</td>')
            w("</tr>")
        w("</table></div>")
    w('<p class="mut small">Kalın: o mesh için diller arasında daha iyi değer.</p>')
    w('<h2>2. Test sonuç matrisi</h2><div class="wrap"><table><tr><th>Test</th>'
      + "".join(f'<th class="n">{esc(MESH_NAMES[m])}</th>' for m in meshes) + "</tr>")
    for t, cells in status_matrix(ctxs, meshes):
        tds = []
        for per_lang in cells:
            tds.append('<td class="n">' + " ".join(
                f'<span title="{esc(lang_name(x))}: {esc(STATUS_TR[s])}">{esc(lang_name(x))} {STATUS_ICON[s]}</span>' for x, s in per_lang) + "</td>")
        w(f"<tr><td>{t}</td>{''.join(tds)}</tr>")
    w("</table></div>")
    w('<h2>3. Yöntem</h2><ul class="f">' + "".join(f"<li>{esc(n)}</li>" for n in NOTES) + "</ul>")
    w("</main></body></html>")
    return "\n".join(e)


def render_md(ctxs):
    langs, meshes, tbls = tables(ctxs)
    L = ["# Diller Arası Kıyas\n",
         "Diller: " + ", ".join(f"{lang_name(x)} ({ctxs[x]['versions'].get('app_runtime', '')})" for x in langs) + "\n",
         "Dil başına tam raporlar: " + " · ".join(f"[{lang_name(x)}]({x}/rapor.md)" for x in langs) + "\n",
         "## 1. Temel göstergeler\n", "Her dil için değer ve parantez içinde mesh etkisi (aynı dilde mesh'siz referansa göre).\n"]
    for label, test, key, unit, rows in tbls:
        L.append(f"### {label} ({test} · `{key}`)\n")
        L.append("| Mesh | " + " | ".join(f"{lang_name(x)} | {lang_name(x)}: mesh etkisi" for x in langs) + " |")
        L.append("|---|" + "---:|---:|" * len(langs))
        for m, cells in rows:
            L.append(f"| {MESH_NAMES[m]} | " + " | ".join(f"{fmt(v, unit)} | {eff}" for v, eff in cells) + " |")
        L.append("")
    L.append("## 2. Test sonuç matrisi\n")
    L.append("| Test | " + " | ".join(MESH_NAMES[m] for m in meshes) + " |")
    L.append("|---|" + "---|" * len(meshes))
    for t, cells in status_matrix(ctxs, meshes):
        L.append(f"| {t} | " + " | ".join(" ".join(f"{lang_name(x)} {STATUS_ICON[s]}" for x, s in pl) for pl in cells) + " |")
    L.append("\n## 3. Yöntem\n")
    L += [f"- {n}" for n in NOTES]
    return "\n".join(L) + "\n"


def write(ctxs, out):
    (out / "karsilastirma.html").write_text(render_html(ctxs))
    (out / "karsilastirma.md").write_text(render_md(ctxs))
