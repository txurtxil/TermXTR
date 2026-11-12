// v2.26.0 — Informes PDF de auditoria: Monitor por host + topologia (mapa Visio).
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../storage/app_paths.dart';
import 'connmap_service.dart';
import 'monitor_models.dart';

// ---------------------------------------------------------------------------
// DTO para el informe de topologia (los _Node del mapa son privados).
// ---------------------------------------------------------------------------
class TopoNodeDto {
  final String id;
  final String name;
  final bool up;
  final bool external;
  final double fx; // 0..1 relativo al lienzo; <0 = sin posicion guardada
  final double fy;
  TopoNodeDto({
    required this.id,
    required this.name,
    this.up = false,
    this.external = false,
    this.fx = -1,
    this.fy = -1,
  });
}

// ---------------------------------------------------------------------------
// Paleta "ingeniero premium de sistemas"
// ---------------------------------------------------------------------------
final _dark = PdfColor.fromHex('#0F2A43');
final _darkSoft = PdfColor.fromHex('#33506B');
final _accent = PdfColor.fromHex('#1F6FEB');
final _ink = PdfColor.fromHex('#1A2433');
final _inkSoft = PdfColor.fromHex('#3D4A5C');
final _line = PdfColor.fromHex('#C9D2DC');
final _zebra = PdfColor.fromHex('#F3F6FA');
final _ok = PdfColor.fromHex('#2E9E62');
final _warn = PdfColor.fromHex('#D97706');
final _err = PdfColor.fromHex('#D64545');
final _muted = PdfColor.fromHex('#7A8699');

PdfColor _fade(PdfColor c, double a) => PdfColor(c.red, c.green, c.blue, a);

PdfColor _serviceColor(String service) {
  final s = service.toLowerCase();
  if (s.contains('oracle')) return PdfColor.fromHex('#C0392B');
  if (s.contains('tomcat')) return PdfColor.fromHex('#E67E22');
  if (s.contains('ssh')) return PdfColor.fromHex('#2E86C1');
  if (s.contains('http')) return PdfColor.fromHex('#27AE60');
  if (s.contains('rsyslog')) return PdfColor.fromHex('#8E44AD');
  if (s.contains('nagios')) return PdfColor.fromHex('#16A085');
  if (s.contains('mysql') ||
      s.contains('postgres') ||
      s.contains('sql server') ||
      s.contains('mongo')) {
    return PdfColor.fromHex('#2471A3');
  }
  return PdfColor.fromHex('#7F8C8D');
}

String _now() => DateTime.now().toString().substring(0, 16);

pw.Widget _band(String title, String subtitle, String when) => pw.Container(
      width: double.infinity,
      color: _dark,
      padding: pw.EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('T E R M X T R',
              style: pw.TextStyle(
                  color: PdfColor.fromHex('#8FB4E3'),
                  fontSize: 7,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 3)),
          pw.SizedBox(height: 3),
          pw.Text(title,
              style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text('$subtitle  ·  $when',
              style: pw.TextStyle(
                  color: PdfColor.fromHex('#B9C6D8'), fontSize: 9)),
        ],
      ),
    );

pw.Widget _section(String t) => pw.Padding(
      padding: pw.EdgeInsets.only(top: 12, bottom: 5),
      child: pw.Row(children: [
        pw.Container(width: 4, height: 12, color: _accent),
        pw.SizedBox(width: 6),
        pw.Text(t,
            style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: _dark)),
      ]),
    );

pw.Widget _cell(String t,
        {PdfColor? color, bool bold = false, double size = 8.5}) =>
    pw.Padding(
      padding: pw.EdgeInsets.all(4),
      child: pw.Text(t,
          style: pw.TextStyle(
              fontSize: size,
              color: color ?? _inkSoft,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
    );

pw.Widget _table(List<String> headers, List<List<pw.Widget>> rows) {
  return pw.Table(
    border: pw.TableBorder.all(color: _line, width: 0.5),
    children: [
      pw.TableRow(
        decoration: pw.BoxDecoration(color: _dark),
        children: [
          for (final h in headers)
            pw.Padding(
              padding: pw.EdgeInsets.all(4),
              child: pw.Text(h,
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold)),
            ),
        ],
      ),
      for (var i = 0; i < rows.length; i++)
        pw.TableRow(
          decoration:
              i.isOdd ? pw.BoxDecoration(color: _zebra) : null,
          children: rows[i],
        ),
    ],
  );
}

pw.Widget _kv(List<(String, String)> items) => pw.Table(
      border: pw.TableBorder.all(color: _line, width: 0.5),
      children: [
        for (final e in items)
          pw.TableRow(children: [
            pw.Container(
              width: 130,
              color: _zebra,
              padding: pw.EdgeInsets.all(4),
              child: pw.Text(e.$1,
                  style: pw.TextStyle(
                      fontSize: 8.5,
                      color: _dark,
                      fontWeight: pw.FontWeight.bold)),
            ),
            pw.Expanded(
                child: pw.Padding(
                    padding: pw.EdgeInsets.all(4),
                    child: pw.Text(e.$2,
                        style:
                            pw.TextStyle(fontSize: 8.5, color: _ink)))),
          ]),
      ],
    );

PdfColor _pctColor(double pct) =>
    pct >= 90 ? _err : (pct >= 75 ? _warn : _ok);

pw.Widget Function(pw.Context) _footer(String appVersion) => (ctx) => pw.Padding(
      padding: pw.EdgeInsets.only(top: 8),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Generado por TermXTR v$appVersion · ${_now()}',
              style: pw.TextStyle(fontSize: 7.5, color: _muted)),
          pw.Text('Página ${ctx.pageNumber} / ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 7.5, color: _muted)),
        ],
      ),
    );

// ---------------------------------------------------------------------------
// Informe de host (Monitor por host)
// ---------------------------------------------------------------------------
Future<Uint8List> buildHostReport({
  required String hostName,
  required MonitorSnapshot snap,
  required String appVersion,
}) async {
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      footer: _footer(appVersion),
      build: (ctx) => [
        _band('Informe de host - auditoria', hostName,
            snap.ts.toString().substring(0, 16)),
        if (snap.load != null) ...[
          _section('Carga'),
          _kv([
            ('Load 1 min', snap.load!.l1.toStringAsFixed(2)),
            ('Load 5 min', snap.load!.l5.toStringAsFixed(2)),
            ('Load 15 min', snap.load!.l15.toStringAsFixed(2)),
            ('Memoria', '${snap.load!.memPct.toStringAsFixed(0)}% usada'),
          ]),
        ],
        _section('Discos'),
        _table(
          ['Punto de montaje', 'Tamano', 'Libre', 'Uso'],
          [
            for (final f in snap.fs)
              [
                _cell(f.mount, bold: true, color: _ink),
                _cell(f.size),
                _cell(f.free),
                _cell('${f.pct.toStringAsFixed(0)}%',
                    bold: true, color: _pctColor(f.pct)),
              ],
          ],
        ),
        if (snap.dirs.isNotEmpty) ...[
          _section('Carpetas monitorizadas'),
          _table(
            ['Ruta', 'Tamano', 'Nota'],
            [
              for (final d in snap.dirs)
                [
                  _cell(d.path, bold: true, color: _ink),
                  _cell(MonitorSnapshot.humanBytes(d.bytes)),
                  _cell(d.slow ? 'du con timeout' : '',
                      color: d.slow ? _warn : _inkSoft),
                ],
            ],
          ),
        ],
        if (snap.top.isNotEmpty) ...[
          _section('Top procesos'),
          _table(
            ['Proceso', 'CPU %', 'MEM %'],
            [
              for (final t in snap.top)
                [
                  _cell(t.name, bold: true, color: _ink),
                  _cell(t.cpu.toStringAsFixed(1)),
                  _cell(t.mem.toStringAsFixed(1)),
                ],
            ],
          ),
        ],
        if (snap.temps.isNotEmpty) ...[
          _section('Temperaturas'),
          _table(
            ['Sensor', 'Temperatura'],
            [
              for (final t in snap.temps.take(12))
                [
                  _cell(t.name, bold: true, color: _ink),
                  _cell('${t.celsius.toStringAsFixed(0)} °C',
                      bold: true,
                      color: t.celsius >= 80
                          ? _err
                          : (t.celsius >= 60 ? _warn : _ok)),
                ],
            ],
          ),
        ],
        if (snap.net.isNotEmpty || snap.netEstablished > 0) ...[
          _section('Red'),
          if (snap.net.isNotEmpty)
            _table(
              ['Interfaz', 'RX', 'TX'],
              [
                for (final n in snap.net)
                  [
                    _cell(n.name, bold: true, color: _ink),
                    _cell('RX ${MonitorSnapshot.humanBytes(n.rxBytes)}'),
                    _cell('TX ${MonitorSnapshot.humanBytes(n.txBytes)}'),
                  ],
              ],
            ),
          if (snap.netEstablished > 0)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                  'Conexiones TCP establecidas: ${snap.netEstablished}',
                  style: pw.TextStyle(fontSize: 8.5, color: _inkSoft)),
            ),
        ],
        if (snap.unitStates.isNotEmpty || snap.servicesRunning > 0) ...[
          _section('Servicios (systemd)'),
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Text(
              '${snap.servicesRunning} en ejecucion'
              '${snap.failedUnits > 0 ? ' · ${snap.failedUnits} fallidos: ${snap.failedNames.join(', ')}' : ' · sin fallos'}',
              style: pw.TextStyle(
                  fontSize: 8.5,
                  color: snap.failedUnits > 0 ? _err : _ok,
                  fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (snap.unitStates.isNotEmpty)
            _table(
              ['Unidad', 'Estado'],
              [
                for (final e in snap.unitStates.entries)
                  [
                    _cell(e.key, bold: true, color: _ink),
                    _cell(
                      e.value,
                      bold: true,
                      color: e.value.contains('failed')
                          ? _err
                          : (e.value.contains('dead') ||
                                  e.value.contains('inactive')
                              ? _warn
                              : _ok),
                    ),
                  ],
              ],
            ),
        ],
        if (snap.oracle.present) ...[
          _section('Oracle'),
          _kv([
            ('Instancia', snap.oracle.up ? 'UP' : 'DOWN'),
            ('Listener',
                snap.oracle.listenerUp == true ? 'UP' : 'no verificable'),
            if (snap.oracle.tablespaces.isNotEmpty)
              ('Tablespaces', '${snap.oracle.tablespaces.length} registrados'),
          ]),
          if (snap.oracle.tablespaces.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            _table(
              ['Tablespace', '% usado'],
              [
                for (final e in snap.oracle.tablespaces.entries)
                  [
                    _cell(e.key, bold: true, color: _ink),
                    _cell('${e.value.toStringAsFixed(1)}%',
                        bold: true, color: _pctColor(e.value)),
                  ],
              ],
            ),
          ],
        ],
        pw.SizedBox(height: 10),
        pw.Text(
          'Documento generado de forma automatica a partir de una consulta de solo lectura (Monitor). Valores capturados en el instante indicado en la cabecera.',
          style: pw.TextStyle(fontSize: 7.5, color: _muted),
        ),
      ],
    ),
  );
  return doc.save();
}

// ---------------------------------------------------------------------------
// Informe de topologia (mapa estilo Visio)
// ---------------------------------------------------------------------------
Future<Uint8List> buildTopologyReport({
  required List<TopoNodeDto> nodes,
  required List<ConnEdge> edges,
  required String appVersion,
}) async {
  final doc = pw.Document();

  // --- layout: respeta posiciones guardadas (fx/fy); fallback determinista ---
  final page = PdfPageFormat.a4.landscape;
  const margin = 30.0;
  final W = page.width - margin * 2;
  final H = page.height - 170; // cabecera + leyenda + margen inferior
  final pos = <String, PdfPoint>{};
  final posByName = <String, PdfPoint>{};

  final ext = nodes.where((n) => n.external).toList();
  final rest = nodes.where((n) => !n.external).toList();
  for (final n in ext) {
    pos[n.id] = PdfPoint(W * 0.10, H * 0.5);
  }
  for (final n in rest.where((n) => n.fx >= 0)) {
    pos[n.id] = PdfPoint(n.fx * W, n.fy * H);
  }
  final noPos = rest.where((n) => n.fx < 0).toList();
  final gn = noPos.length;
  for (var i = 0; i < gn; i++) {
    final y = gn == 1 ? H * 0.5 : H * (0.12 + 0.76 * i / (gn - 1));
    pos[noPos[i].id] = PdfPoint(W * 0.74, y);
  }
  for (final n in nodes) {
    final p = pos[n.id];
    if (p != null) posByName[n.name] = p;
  }

  // --- segmentos de arista ---
  final segs = <_Seg>[];
  for (final e in edges) {
    final a = posByName[e.fromName];
    final b = posByName[e.toName];
    if (a == null || b == null) continue;
    segs.add(_Seg(a, b, _serviceColor(e.service), e.count));
  }

  // --- servicios por nodo (LEDs) ---
  final servicesOf = <String, Set<String>>{};
  for (final e in edges) {
    servicesOf.putIfAbsent(e.fromName, () => {}).add(e.service);
    servicesOf.putIfAbsent(e.toName, () => {}).add(e.service);
  }
  final legendServices = <String>{};
  for (final e in edges) {
    legendServices.add(e.service);
  }

  const boxW = 118.0;
  const boxH = 34.0;

  pw.Widget nodeBox(TopoNodeDto n) {
    final p = posByName[n.name]!;
    final svcs = (servicesOf[n.name] ?? {}).toList()
      ..sort();
    return pw.Positioned(
      left: p.x - boxW / 2,
      top: p.y - boxH / 2,
      child: pw.Container(
        width: boxW,
        height: boxH,
        decoration: pw.BoxDecoration(
          color: n.external ? _zebra : PdfColors.white,
          borderRadius: pw.BorderRadius.circular(6),
          border: pw.Border.all(
              color: n.up ? _ok : _line, width: n.up ? 1.6 : 1),
          boxShadow: [
            pw.BoxShadow(color: PdfColor.fromHex('#D7DEE8'), blurRadius: 3)
          ],
        ),
        padding: pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text(n.name,
                maxLines: 1,
                style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                    color: n.external ? _muted : _dark)),
            pw.SizedBox(height: 3),
            pw.Row(
              children: [
                for (final s in svcs.take(6))
                  pw.Padding(
                    padding: pw.EdgeInsets.only(right: 3),
                    child: pw.Container(
                      width: 6,
                      height: 6,
                      decoration: pw.BoxDecoration(
                        shape: pw.BoxShape.circle,
                        color: _serviceColor(s),
                      ),
                    ),
                  ),
                if (svcs.isEmpty)
                  pw.Container(
                    width: 6,
                    height: 6,
                    decoration: pw.BoxDecoration(
                      shape: pw.BoxShape.circle,
                      color: _line,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget edgeLabels() {
    final children = <pw.Widget>[];
    for (final e in edges) {
      final a = posByName[e.fromName];
      final b = posByName[e.toName];
      if (a == null || b == null) continue;
      final mx = (a.x + b.x) / 2;
      final my = (a.y + b.y) / 2;
      children.add(pw.Positioned(
        left: mx - 34,
        top: my - 5,
        child: pw.Container(
          color: _fade(PdfColors.white, 0.85),
          padding:
              pw.EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: pw.Text('${e.service}${e.count > 1 ? ' x${e.count}' : ''}',
              style: pw.TextStyle(
                  fontSize: 6.5, color: _serviceColor(e.service))),
        ),
      ));
    }
    return pw.Stack(children: children);
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: page,
      footer: _footer(appVersion),
      build: (ctx) => [
        _band('Informe de topología — auditoría',
            '${nodes.length} nodos · ${edges.length} aristas', _now()),
        pw.SizedBox(height: 8),
        pw.Container(
          width: W,
          height: H,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _line, width: 0.7),
            color: PdfColors.white,
          ),
          child: pw.Stack(
            children: [
              pw.CustomPaint(
                size: PdfPoint(W, H),
                painter: (canvas, size) {
                  for (final s in segs) {
                    canvas
                      ..setStrokeColor(_fade(s.color, 0.75))
                      ..setLineWidth(1 + (s.count > 2 ? 0.8 : 0))
                      ..moveTo(s.a.x, size.y - s.a.y)
                      ..lineTo(s.b.x, size.y - s.b.y)
                      ..strokePath();
                  }
                },
              ),
              edgeLabels(),
              for (final n in nodes)
                if (posByName.containsKey(n.name)) nodeBox(n),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
        pw.Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            for (final s in (legendServices.toList()..sort()))
              pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                pw.Container(
                  width: 7,
                  height: 7,
                  decoration: pw.BoxDecoration(
                    shape: pw.BoxShape.circle,
                    color: _serviceColor(s),
                  ),
                ),
                pw.SizedBox(width: 4),
                pw.Text(s,
                    style:
                        pw.TextStyle(fontSize: 8, color: _inkSoft)),
              ]),
          ],
        ),
        _section('Detalle de conexiones'),
        _table(
          ['Origen', 'Destino', 'Servicio', 'Puerto', 'Conexiones'],
          [
            for (final e in edges)
              [
                _cell(e.fromName, bold: true, color: _ink),
                _cell(e.toName, bold: true, color: _ink),
                _cell(e.service, color: _serviceColor(e.service)),
                _cell('${e.port}'),
                _cell('${e.count}'),
              ],
          ],
        ),
      ],
    ),
  );
  return doc.save();
}

class _Seg {
  final PdfPoint a;
  final PdfPoint b;
  final PdfColor color;
  final int count;
  _Seg(this.a, this.b, this.color, this.count);
}

// ---------------------------------------------------------------------------
// Utilidad comun: guardar en exports/ y compartir
// ---------------------------------------------------------------------------
String fileSafe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

Future<String> saveAndSharePdf(
    Uint8List bytes, String basename, String shareText) async {
  final dir = Directory('${AppPaths.base}/exports')
    ..createSync(recursive: true);
  final f = File('${dir.path}/$basename.pdf');
  await f.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles([XFile(f.path)], text: shareText);
  return f.path;
}
